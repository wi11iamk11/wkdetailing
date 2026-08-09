"""The warm Claude Agent SDK session.

One ClaudeSDKClient per voice session, created at launch and kept warm. The
first turn pays a prompt-cache toll of several seconds, which is why main.py
fires a warmup query behind the spoken greeting.

Text is streamed, chunked into sentences, and handed to the mouth the instant
each chunk is complete -- including when a content block stops, which is what
makes pre-tool filler like "on it, checking now" play immediately instead of
sitting silent through the whole tool run.
"""

from __future__ import annotations

import json
import re
from datetime import datetime
from typing import AsyncIterator

import config
import state as state_store

try:
    from claude_agent_sdk import (
        AssistantMessage,
        ClaudeAgentOptions,
        ClaudeSDKClient,
        ResultMessage,
        StreamEvent,
        TextBlock,
    )
except Exception as exc:  # pragma: no cover
    ClaudeSDKClient = None
    _IMPORT_ERROR = exc
else:
    _IMPORT_ERROR = None


# ---------------------------------------------------------------------------
# Text shaping
# ---------------------------------------------------------------------------

_FENCE = re.compile(r"```.*?```", re.S)
_OPEN_FENCE = re.compile(r"```.*\Z", re.S)
_INLINE_CODE = re.compile(r"`([^`]*)`")
_BOLD_ITALIC = re.compile(r"(\*\*|__|\*|_)(?=\S)(.+?)(?<=\S)\1", re.S)
_HEADING = re.compile(r"^\s{0,3}#{1,6}\s*", re.M)
_BULLET = re.compile(r"^\s{0,6}(?:[-*+•]|\d{1,2}[.)])\s+", re.M)
_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_SYMBOL_LINE = re.compile(r"^[\s\-=_|:*#`~]+$", re.M)
# Last-resort net: stream_turn's tail-holding is what's supposed to keep a
# STATE_UPDATE line out of speech, but that logic only triggers on a real
# newline before it. If the model ever glues it onto prior text without one,
# this still keeps the raw JSON off the speakers -- everything from the
# token to the end of the chunk is dropped, since nothing legitimate follows
# a STATE_UPDATE per the prompt's contract.
_STATE_LEAK = re.compile(r"STATE_UPDATE:.*", re.S)


def clean_for_speech(text: str) -> str:
    """Strip markdown so the voice never performs punctuation soup.

    The system prompt asks for clean prose; this is the safety net for when a
    stray bullet or backtick slips through anyway.
    """
    if not text:
        return ""
    text = _STATE_LEAK.sub("", text)
    text = _FENCE.sub(" ", text)
    text = _OPEN_FENCE.sub(" ", text)
    text = _LINK.sub(r"\1", text)
    text = _INLINE_CODE.sub(r"\1", text)
    text = _BOLD_ITALIC.sub(r"\2", text)
    text = _HEADING.sub("", text)
    text = _BULLET.sub("", text)
    text = _SYMBOL_LINE.sub(" ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


_ABBREV = {
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie",
    "e.g", "i.e", "fig", "approx", "inc", "ltd", "no", "vol", "al",
}
_SENT_END = re.compile(r"([.!?…]+)([\s\n]+|$)")


def split_sentences(buf: str) -> tuple[list[str], str]:
    """Split off every *complete* sentence, returning (sentences, remainder).

    A boundary only counts when the punctuation is followed by whitespace that
    has already arrived, so "3.14" and a period still mid-stream both wait.
    """
    sentences: list[str] = []
    start = 0
    for m in _SENT_END.finditer(buf):
        if not m.group(2):
            continue  # punctuation at the very end of the buffer: not safe yet
        head = buf[start:m.end(1)]
        prev = re.search(r"([A-Za-z][A-Za-z.]*)$", buf[:m.start(1)])
        if prev:
            token = prev.group(1).rstrip(".").lower()
            if token in _ABBREV:
                continue
            if len(token) == 1 and prev.group(1)[0].isupper():
                continue  # a middle initial, "J. Smith"
        cleaned = head.strip()
        if cleaned:
            sentences.append(cleaned)
        start = m.end(2)
    return sentences, buf[start:]


class SentenceChunker:
    """Turn a token stream into speakable chunks.

    The first chunk ships as soon as one sentence is complete, because that is
    the number the ear measures: time from key release to first audio.
    After that, sentences ship in two-sentence breaths -- a lone short sentence
    on its own sounds flat.
    """

    def __init__(self, first: int = config.FIRST_CHUNK_SENTENCES,
                 breath: int = config.BREATH_SENTENCES):
        self.first = max(1, first)
        self.breath = max(1, breath)
        self._buf = ""
        self._pending: list[str] = []
        self._emitted = 0

    def _target(self) -> int:
        return self.first if self._emitted == 0 else self.breath

    def _drain(self) -> list[str]:
        out = []
        while len(self._pending) >= self._target():
            take = self._pending[: self._target()]
            del self._pending[: self._target()]
            chunk = clean_for_speech(" ".join(take))
            if chunk:
                out.append(chunk)
                self._emitted += 1
        return out

    def feed(self, text: str) -> list[str]:
        if not text:
            return []
        self._buf += text
        sentences, self._buf = split_sentences(self._buf)
        self._pending.extend(sentences)
        return self._drain()

    def flush(self) -> list[str]:
        """Ship everything held, whole sentence or not.

        Called when a content block stops. Without this, filler spoken before a
        tool call sits silent for the whole tool run and then plays glued to
        the answer.
        """
        tail = self._buf.strip()
        self._buf = ""
        if tail:
            self._pending.append(tail)
        out = self._drain()
        if self._pending:
            chunk = clean_for_speech(" ".join(self._pending))
            self._pending = []
            if chunk:
                out.append(chunk)
                self._emitted += 1
        # A content block just ended, so the next one starts a fresh silence --
        # after a tool run, most of all. Ship its opening sentence alone again
        # instead of making the user wait for a pair.
        self._emitted = 0
        return out


# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------


def _build_append_prompt(state: dict, now: datetime | None = None) -> str:
    """The text appended after the claude_code preset.

    When prompts/jarvis-system-prompt.md exists, it carries identity and
    spoken style, with the live <state> substituted in and the streaming
    addendum bolted on after it. Otherwise fall back to the older
    self-contained SPOKEN_DISCIPLINE, unchanged, so voice-line still works
    dropped into a project that isn't this repo.

    {{NOW}} and {{AGENDA}} matter more than they look. The prompt asks JARVIS
    to lead with anything due inside forty-eight hours, which is not a
    question a model can answer at all without being told the date -- and
    asking it to do date arithmetic over raw ISO strings mid-sentence is a
    good way to be told something false with total confidence. The agenda is
    computed here, in Python, and handed over already resolved.
    """
    path = config.JARVIS_PROMPT_PATH
    if path is None:
        return config.SPOKEN_DISCIPLINE
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return config.SPOKEN_DISCIPLINE
    now = now or datetime.now()
    text = text.replace("{{NOW}}", now.strftime("%A %d %B %Y, %I:%M %p").replace(" 0", " "))
    text = text.replace("{{AGENDA}}", state_store.render_agenda(state, now))
    text = text.replace("{{STATE_JSON}}", json.dumps(state, sort_keys=True))
    return text + "\n\n" + config.STREAMING_ADDENDUM


# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------


class Brain:
    def __init__(self, project_dir: str | None = None, model: str = "",
                 permission_mode: str | None = None, on_stderr=None,
                 on_state_update=None, on_state_warning=None):
        self.project_dir = project_dir or config.PROJECT_DIR
        self.model = model or config.MODEL
        self.permission_mode = permission_mode or config.PERMISSION_MODE
        self._on_stderr = on_stderr
        self._on_state_update = on_state_update
        self._on_state_warning = on_state_warning
        self._client = None
        self.last_tool: str | None = None
        self.state: dict = state_store.load()

    def _apply_state_update(self, update: dict) -> None:
        self.state = state_store.merge(self.state, update)
        state_store.save(self.state)
        if self._on_state_update is not None:
            self._on_state_update(update)

    def _resolve_tail(self, tail: str, chunker: "SentenceChunker") -> list[str]:
        """Turn a held-back trailing line into speech, or into a state write.

        Anything that opens with STATE_UPDATE: is never spoken, whether or
        not it parses -- a malformed one is dropped and logged instead of
        read aloud, per the prompt's own contract.
        """
        stripped = tail.strip()
        if not stripped:
            return []
        if state_store.is_update_line(stripped):
            update = state_store.extract_update(stripped)
            if update is not None:
                self._apply_state_update(update)
            elif self._on_state_warning is not None:
                self._on_state_warning(f"malformed STATE_UPDATE, dropped: {stripped[:160]}")
            return []
        return chunker.feed(tail)

    def _options(self):
        kwargs = dict(
            cwd=self.project_dir,
            system_prompt={
                "type": "preset",
                "preset": "claude_code",
                "append": _build_append_prompt(self.state),
            },
            tools={"type": "preset", "preset": "claude_code"},
            permission_mode=self.permission_mode,
            include_partial_messages=True,
            # "project" is required for CLAUDE.md to load, which is what makes
            # the voice session the same assistant as the terminal sessions.
            setting_sources=["user", "project", "local"],
            env={"CLAUDE_AGENT_SDK_CLIENT_APP": "voice-line/1.0"},
        )
        if self.model:
            kwargs["model"] = self.model
        if self._on_stderr is not None:
            kwargs["stderr"] = self._on_stderr
        return ClaudeAgentOptions(**kwargs)

    async def start(self) -> None:
        if ClaudeSDKClient is None:
            raise RuntimeError(f"claude-agent-sdk is not importable: {_IMPORT_ERROR}")
        self._client = ClaudeSDKClient(self._options())
        await self._client.connect()

    async def warmup(self) -> None:
        """Pay the first-turn prompt-cache toll while the greeting is playing."""
        try:
            await self._client.query("Reply with exactly: ready")
            async for _ in self._client.receive_response():
                pass
        except Exception:
            pass

    async def stream_turn(self, text: str) -> AsyncIterator[str]:
        """Yield speakable chunks for one turn.

        A STATE_UPDATE line, if the model writes one, is the last line of the
        whole response (see prompts/jarvis-system-prompt.md) and must never
        reach the chunker or the speakers. Ordinary spoken prose has no
        newlines in it, so once one appears mid-stream everything after it is
        held back in `tail` instead of being fed to the chunker -- it's either
        the start of a state update or just incidental trailing text. It only
        gets resolved (spoken, or applied as state) once something proves it
        wasn't the final line after all: a new content block starting, or the
        turn ending.
        """
        chunker = SentenceChunker()
        saw_stream_text = False
        self.last_tool = None
        tail = ""
        holding = False

        def feed(piece: str) -> list[str]:
            nonlocal tail, holding
            if not piece:
                return []
            if not holding:
                before, nl, after = piece.partition("\n")
                if not nl:
                    return chunker.feed(piece)
                out = chunker.feed(before) if before else []
                holding = True
                tail = after
                return out
            tail += piece
            return []

        def release() -> list[str]:
            nonlocal tail, holding
            if not holding:
                return []
            holding = False
            held, tail = tail, ""
            return self._resolve_tail(held, chunker)

        await self._client.query(text)
        async for msg in self._client.receive_response():
            if StreamEvent is not None and isinstance(msg, StreamEvent):
                event = msg.event or {}
                etype = event.get("type")
                if etype == "content_block_delta":
                    delta = event.get("delta") or {}
                    # text_delta only: thinking_delta and input_json_delta are
                    # not for the ear.
                    if delta.get("type") == "text_delta":
                        piece = delta.get("text") or ""
                        if piece:
                            saw_stream_text = True
                            for chunk in feed(piece):
                                yield chunk
                elif etype == "content_block_start":
                    block = event.get("content_block") or {}
                    if block.get("type") == "tool_use":
                        self.last_tool = block.get("name")
                    # A new block starting proves any held tail wasn't the
                    # final line -- release it as ordinary speech.
                    for chunk in release():
                        yield chunk
                elif etype == "content_block_stop":
                    # The critical flush -- but the held tail stays held,
                    # since this block ending doesn't prove the turn is over.
                    for chunk in chunker.flush():
                        yield chunk

            elif isinstance(msg, AssistantMessage):
                # Fallback for builds where partial messages are unavailable.
                # Guarded so nothing is ever spoken twice.
                if not saw_stream_text:
                    for block in msg.content:
                        if isinstance(block, TextBlock) and block.text:
                            for chunk in feed(block.text):
                                yield chunk
                    for chunk in release():
                        yield chunk
                    for chunk in chunker.flush():
                        yield chunk

            elif isinstance(msg, ResultMessage):
                for chunk in release():
                    yield chunk
                for chunk in chunker.flush():
                    yield chunk
                break

    async def interrupt(self) -> None:
        try:
            if self._client is not None:
                await self._client.interrupt()
        except Exception:
            pass

    async def close(self) -> None:
        try:
            if self._client is not None:
                await self._client.disconnect()
        except Exception:
            pass

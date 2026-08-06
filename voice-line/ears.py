"""Mic capture, endpointing, and transcription.

Two capture modes share one gated microphone:

  HoldRecorder  push to talk: opens on key down, closes on key up + a tail
  VadListener   hands free: webrtcvad endpointing on an always-open stream

Both feed `Transcriber`, which talks to the local whisper.cpp server. Whisper
builds disagree about routes, so we probe for the one that actually answers
instead of assuming the OpenAI-style path exists.
"""

from __future__ import annotations

import asyncio
import collections
import io
import queue
import re
import threading
import time
import wave

import httpx

import config

try:  # keeps the pure logic importable without audio hardware
    import sounddevice as sd
except Exception:  # pragma: no cover - exercised only on machines without portaudio
    sd = None

try:
    import webrtcvad
except Exception:  # pragma: no cover
    webrtcvad = None


# ---------------------------------------------------------------------------
# Transcript cleaning
# ---------------------------------------------------------------------------

# Whisper narrates the room when nobody is talking: [BLANK_AUDIO], [SIGHS],
# (upbeat music), *laughs*. None of it is speech.
_BRACKETED = re.compile(r"\[[^\]]{0,60}\]")
_ASTERISKED = re.compile(r"\*[^*]{0,60}\*")
_PARENTHETICAL_MARKER = re.compile(r"\((?:[A-Z][A-Z ]{1,30}|[a-z ]{1,30}(?:music|noise|silence))\)")

# Classic whisper hallucinations on near-silence. Only filtered in open-mic
# mode, where the transcriber gets fed room tone all day.
_HALLUCINATIONS = {
    "",
    ".",
    "..",
    "...",
    "you",
    "you.",
    "so",
    "so.",
    "okay",
    "okay.",
    "bye",
    "bye.",
    "thank you",
    "thank you.",
    "thanks for watching",
    "thanks for watching!",
    "thanks for watching.",
    "silence",
    "music",
    "[blank_audio]",
    "subs by www.zeoranger.co.uk",
}


def clean_transcript(text: str, open_mic: bool = False) -> str:
    """Strip non-speech markers and collapse whitespace."""
    if not text:
        return ""
    text = _BRACKETED.sub(" ", text)
    text = _ASTERISKED.sub(" ", text)
    text = _PARENTHETICAL_MARKER.sub(" ", text)
    text = re.sub(r"\s+", " ", text).strip()
    if open_mic and text.lower().strip() in _HALLUCINATIONS:
        return ""
    return text


# ---------------------------------------------------------------------------
# Wake word
# ---------------------------------------------------------------------------

_WORD = re.compile(r"[A-Za-z']+")


def _edit_distance(a: str, b: str) -> int:
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _is_wake_token(token: str, wake: str) -> bool:
    token = token.lower().strip("'")
    if token == wake:
        return True
    # The hand-tuned mishearings only apply to the default wake word.
    if wake == "jarvis" and token in config.WAKE_VARIANTS:
        return True
    dist = _edit_distance(token, wake)
    if dist <= 1:
        return True
    # Be a little more forgiving when whisper at least heard the first letter.
    return dist == 2 and len(token) >= 5 and token[0] == wake[0]


def strip_wake_word(text: str, wake: str | None = None, scan_words: int = 3):
    """Look for the wake word near the start of an utterance.

    Returns (matched, remainder). The remainder keeps the original casing and
    punctuation of whatever followed the wake word.
    """
    wake = (wake or config.WAKE_WORD).lower()
    if not text:
        return False, ""
    for idx, m in enumerate(_WORD.finditer(text)):
        if idx >= scan_words:
            break
        if _is_wake_token(m.group(0), wake):
            remainder = text[m.end():]
            remainder = remainder.lstrip(" ,.!?;:-—–")
            return True, remainder.strip()
    return False, text.strip()


# ---------------------------------------------------------------------------
# WAV packing
# ---------------------------------------------------------------------------


def pcm_to_wav(pcm: bytes, samplerate: int = config.MIC_SR) -> bytes:
    """Wrap raw mono int16 PCM in a WAV container, in memory."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(samplerate)
        wf.writeframes(pcm)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Transcription
# ---------------------------------------------------------------------------


def parse_transcript_payload(content_type: str, body: str) -> str:
    """Pull text out of whatever shape the server replied with."""
    stripped = body.strip()
    looks_json = "json" in (content_type or "").lower() or stripped.startswith("{")
    if looks_json:
        try:
            import json

            data = json.loads(stripped)
        except Exception:
            return stripped
        if isinstance(data, dict):
            for key in ("text", "transcription", "result"):
                val = data.get(key)
                if isinstance(val, str):
                    return val.strip()
            segments = data.get("segments")
            if isinstance(segments, list):
                parts = [
                    s.get("text", "")
                    for s in segments
                    if isinstance(s, dict) and isinstance(s.get("text"), str)
                ]
                if parts:
                    return " ".join(p.strip() for p in parts).strip()
        return stripped
    return stripped


class Transcriber:
    """Client for the local whisper.cpp server, bound to the route that works."""

    def __init__(self, base: str | None = None, client: httpx.AsyncClient | None = None):
        self.base = (base or config.WHISPER_BASE).rstrip("/")
        self._client = client or httpx.AsyncClient(timeout=config.WHISPER_TIMEOUT_S)
        self._owns_client = client is None
        self.route: str | None = None

    async def probe(self) -> str:
        """Find the transcription route this build actually exposes.

        Some whisper server builds only serve /inference, not the OpenAI-style
        /v1/audio/transcriptions that client libraries assume. Rather than
        guess, send a fragment of silence at each candidate and keep the first
        one that answers.
        """
        silence = pcm_to_wav(b"\x00\x00" * (config.MIC_SR // 4))
        errors = []
        for route in config.WHISPER_ROUTES:
            url = self.base + route
            try:
                resp = await self._post_audio(url, silence, route)
            except Exception as exc:
                errors.append(f"{route}: {type(exc).__name__}: {exc}")
                continue
            if resp.status_code == 200:
                self.route = route
                return route
            errors.append(f"{route}: HTTP {resp.status_code}")
        raise RuntimeError(
            "No working transcription route on "
            + self.base
            + "\n  "
            + "\n  ".join(errors)
            + "\nIs the whisper server running? Try: curl -F file=@test.wav "
            + self.base
            + "/inference"
        )

    async def _post_audio(self, url: str, wav: bytes, route: str) -> httpx.Response:
        files = {"file": ("speech.wav", wav, "audio/wav")}
        data = {"temperature": "0.0", "response_format": "json"}
        if route.startswith("/v1/"):
            data["model"] = "whisper-1"
        return await self._client.post(url, files=files, data=data)

    async def transcribe(self, pcm: bytes, samplerate: int = config.MIC_SR,
                         open_mic: bool = False) -> str:
        if not pcm:
            return ""
        if self.route is None:
            await self.probe()
        wav = pcm_to_wav(pcm, samplerate)
        resp = await self._post_audio(self.base + self.route, wav, self.route)
        resp.raise_for_status()
        raw = parse_transcript_payload(resp.headers.get("content-type", ""), resp.text)
        return clean_transcript(raw, open_mic=open_mic)

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()


# ---------------------------------------------------------------------------
# Microphone
# ---------------------------------------------------------------------------


class Microphone:
    """A gated 16 kHz mono int16 capture stream.

    The gate is the half-duplex guarantee: while the mouth is speaking, frames
    are dropped at the callback so the system can never hear itself.
    """

    def __init__(self, samplerate: int = config.MIC_SR, blocksize: int = config.MIC_BLOCK,
                 device=None):
        self.samplerate = samplerate
        self.blocksize = blocksize
        self.device = device
        self._q: queue.Queue[bytes] = queue.Queue()
        self._stream = None
        self._gated = False
        self._collecting = False
        self._collected = 0
        self._max_bytes = int(config.MAX_UTTERANCE_S * samplerate * 2)
        self._lock = threading.Lock()

    # -- lifecycle ---------------------------------------------------------
    @property
    def is_open(self) -> bool:
        return self._stream is not None

    def open(self) -> None:
        if self._stream is not None:
            return
        if sd is None:
            raise RuntimeError(
                "sounddevice is not available. Install it with `uv sync`, and check "
                "Windows Settings > Privacy & security > Microphone > let desktop apps "
                "access your microphone."
            )
        self.drain()
        self._stream = sd.RawInputStream(
            samplerate=self.samplerate,
            blocksize=self.blocksize,
            device=self.device,
            dtype="int16",
            channels=1,
            callback=self._callback,
        )
        self._stream.start()

    def close(self) -> None:
        stream, self._stream = self._stream, None
        if stream is not None:
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass

    def _callback(self, indata, frames, time_info, status):  # pragma: no cover - audio thread
        if self._gated:
            return
        if self._collected >= self._max_bytes:
            return
        data = bytes(indata)
        self._collected += len(data)
        self._q.put(data)

    # -- gating ------------------------------------------------------------
    def gate(self, closed: bool) -> None:
        """Close the gate while the assistant speaks; open it again after."""
        self._gated = closed
        if closed:
            self.drain()

    @property
    def gated(self) -> bool:
        return self._gated

    def drain(self) -> None:
        with self._lock:
            self._collected = 0
            while True:
                try:
                    self._q.get_nowait()
                except queue.Empty:
                    break

    def take_all(self) -> bytes:
        chunks = []
        with self._lock:
            while True:
                try:
                    chunks.append(self._q.get_nowait())
                except queue.Empty:
                    break
            self._collected = 0
        return b"".join(chunks)

    def get_frame(self, timeout: float = 0.1) -> bytes | None:
        try:
            data = self._q.get(timeout=timeout)
        except queue.Empty:
            return None
        with self._lock:
            self._collected = max(0, self._collected - len(data))
        return data


class HoldRecorder:
    """Push-to-talk capture: open on key down, close on key up plus a tail."""

    def __init__(self, mic: Microphone, tail_s: float = config.RELEASE_TAIL_S):
        self.mic = mic
        self.tail_s = tail_s
        self.active = False
        self._started_at = 0.0

    def start(self) -> None:
        self.active = True
        self._started_at = time.monotonic()
        self.mic.open()
        self.mic.drain()

    async def stop(self) -> tuple[bytes, float]:
        """Return (pcm, held_seconds). The tail keeps the last word alive."""
        if not self.active:
            return b"", 0.0
        held = time.monotonic() - self._started_at
        await asyncio.sleep(self.tail_s)
        pcm = self.mic.take_all()
        self.mic.close()
        self.active = False
        return pcm, held

    def cancel(self) -> None:
        self.active = False
        self.mic.close()
        self.mic.drain()


class VadListener:
    """Endpointing for the hands-free mode.

    Runs on a plain thread and hands finished utterances back to the event
    loop with call_soon_threadsafe. Nothing here touches add_reader, which the
    Windows ProactorEventLoop does not implement.
    """

    def __init__(self, mic: Microphone, loop: asyncio.AbstractEventLoop,
                 out_queue: asyncio.Queue, level: int = config.VAD_LEVEL):
        if webrtcvad is None:
            raise RuntimeError("webrtcvad is not installed. Run `uv sync`.")
        self.mic = mic
        self.loop = loop
        self.out_queue = out_queue
        self.vad = webrtcvad.Vad(level)
        self.frame_ms = int(1000 * mic.blocksize / mic.samplerate)
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()

    def start(self) -> None:
        self.mic.open()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="vad", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        self.mic.close()

    def _emit(self, pcm: bytes) -> None:
        try:
            self.loop.call_soon_threadsafe(self.out_queue.put_nowait, pcm)
        except RuntimeError:
            pass  # loop already closed during shutdown

    def _run(self) -> None:  # pragma: no cover - needs a live mic
        preroll_frames = max(1, config.PREROLL_MS // self.frame_ms)
        end_frames = max(1, config.END_SILENCE_MS // self.frame_ms)
        min_speech_frames = max(1, config.MIN_SPEECH_MS // self.frame_ms)

        ring = collections.deque(maxlen=preroll_frames)
        triggered = False
        voiced: list[bytes] = []
        voiced_count = 0
        silence_run = 0

        while not self._stop.is_set():
            frame = self.mic.get_frame(timeout=0.1)
            if frame is None:
                continue
            if self.mic.gated:
                # Reset everything so a half-heard utterance does not resume
                # when the gate reopens.
                ring.clear()
                voiced.clear()
                triggered = False
                voiced_count = 0
                silence_run = 0
                continue
            if len(frame) != self.mic.blocksize * 2:
                continue  # webrtcvad only accepts exact 10/20/30 ms frames

            try:
                is_speech = self.vad.is_speech(frame, self.mic.samplerate)
            except Exception:
                continue

            if not triggered:
                ring.append(frame)
                if is_speech:
                    triggered = True
                    voiced = list(ring)
                    voiced_count = 1
                    silence_run = 0
                    ring.clear()
            else:
                voiced.append(frame)
                if is_speech:
                    voiced_count += 1
                    silence_run = 0
                else:
                    silence_run += 1
                    if silence_run >= end_frames:
                        speech_ms = voiced_count * self.frame_ms
                        # Discard anything that is not really speech: a door,
                        # a keyboard, a cough.
                        if voiced_count >= min_speech_frames:
                            self._emit(b"".join(voiced))
                        triggered = False
                        voiced = []
                        voiced_count = 0
                        silence_run = 0
                        del speech_ms

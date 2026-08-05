"""Typed input, as a first-class turn.

A typed line goes into the exact same handler as speech: the reply is spoken
aloud, typing while it talks interrupts playback, and the quit phrases work
typed.

Windows consoles have no termios and no cbreak mode, so this reads
character-level input with msvcrt on a background thread and feeds completed
lines into the asyncio loop with call_soon_threadsafe. It never uses
add_reader: the ProactorEventLoop, which the Claude Agent SDK needs for
subprocess handling, does not implement it.

On top of the raw characters sits a tiny line editor with paste awareness:
ENABLE_VIRTUAL_TERMINAL_INPUT plus a bracketed-paste request means Windows
Terminal wraps pastes in escape markers we can see, so a paste of any shape
becomes ONE message, with gutter glyphs and hard wraps scrubbed out and a
character count echoed instead of a wall of text.
"""

from __future__ import annotations

import asyncio
import os
import re
import sys
import threading
import time

IS_WINDOWS = os.name == "nt"

# Console mode flags
ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200
ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
STD_INPUT_HANDLE = -10
STD_OUTPUT_HANDLE = -11

PASTE_START = "[200~"
PASTE_END = "[201~"
PASTE_ECHO_THRESHOLD = 120  # longer than this echoes as a count

# Gutters that ride along when you copy out of a terminal, a diff, a chat pane
# or a code viewer.
_LINE_NUMBER = re.compile(r"^\s*\d{1,6}\s*(?:[→|│┃:]|\t)\s?")
_GUTTER = re.compile(r"^[\s>|│┃┆┇┊┋▏▎▍▌▋▊▉█·•]+")
_TRAILING_GUTTER = re.compile(r"[\s│┃|]+$")


def scrub_paste(raw: str) -> str:
    """Flatten pasted text into a single clean message.

    Strips line-number gutters and quote glyphs, undoes hard wraps, and joins
    everything into one line, because this is one message no matter how many
    rows it occupied on screen.
    """
    if not raw:
        return ""
    text = raw.replace("\r\n", "\n").replace("\r", "\n")
    out = []
    for line in text.split("\n"):
        line = _LINE_NUMBER.sub("", line)
        line = _GUTTER.sub("", line)
        line = _TRAILING_GUTTER.sub("", line)
        if line:
            out.append(line)
    joined = " ".join(out)
    return re.sub(r"[ \t]+", " ", joined).strip()


class _Editor:
    """Minimal line editor over a raw character stream."""

    def __init__(self, echo=True):
        self.buf: list[str] = []
        self.echo = echo

    def _write(self, s: str) -> None:
        if not self.echo:
            return
        try:
            sys.stdout.write(s)
            sys.stdout.flush()
        except Exception:
            pass

    def insert(self, text: str, echo_text: str | None = None) -> None:
        self.buf.append(text)
        self._write(echo_text if echo_text is not None else text)

    def backspace(self) -> None:
        if not self.buf:
            return
        last = self.buf[-1]
        if len(last) > 1:
            self.buf[-1] = last[:-1]
        else:
            self.buf.pop()
        self._write("\b \b")

    def take(self) -> str:
        line = "".join(self.buf).strip()
        self.buf = []
        return line

    def clear(self) -> None:
        self.buf = []


class ConsoleReader:
    """Reads lines on a thread and pushes them into an asyncio queue."""

    def __init__(self, loop: asyncio.AbstractEventLoop, out_queue: asyncio.Queue,
                 prompt: str = "you> "):
        self.loop = loop
        self.out_queue = out_queue
        self.prompt = prompt
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._saved_in_mode = None
        self._saved_out_mode = None

    # -- lifecycle ---------------------------------------------------------
    def start(self) -> None:
        if IS_WINDOWS:
            self._enable_vt()
        self._thread = threading.Thread(
            target=self._run_windows if IS_WINDOWS else self._run_posix,
            name="console",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if IS_WINDOWS:
            self._restore_vt()
        if self._thread is not None:
            self._thread.join(timeout=1.0)

    def show_prompt(self) -> None:
        try:
            sys.stdout.write(self.prompt)
            sys.stdout.flush()
        except Exception:
            pass

    def _emit(self, line: str) -> None:
        try:
            self.loop.call_soon_threadsafe(self.out_queue.put_nowait, line)
        except RuntimeError:
            pass

    # -- Windows console modes --------------------------------------------
    def _enable_vt(self) -> None:
        try:
            import ctypes

            k = ctypes.windll.kernel32
            for handle_id, flag, attr in (
                (STD_INPUT_HANDLE, ENABLE_VIRTUAL_TERMINAL_INPUT, "_saved_in_mode"),
                (STD_OUTPUT_HANDLE, ENABLE_VIRTUAL_TERMINAL_PROCESSING, "_saved_out_mode"),
            ):
                handle = k.GetStdHandle(handle_id)
                mode = ctypes.c_uint32()
                if k.GetConsoleMode(handle, ctypes.byref(mode)):
                    setattr(self, attr, mode.value)
                    k.SetConsoleMode(handle, mode.value | flag)
            # Ask the terminal to bracket pastes so we can see their edges.
            sys.stdout.write("\x1b[?2004h")
            sys.stdout.flush()
        except Exception:
            pass  # older console: we just lose paste detection, not input

    def _restore_vt(self) -> None:
        try:
            import ctypes

            sys.stdout.write("\x1b[?2004l")
            sys.stdout.flush()
            k = ctypes.windll.kernel32
            for handle_id, saved in (
                (STD_INPUT_HANDLE, self._saved_in_mode),
                (STD_OUTPUT_HANDLE, self._saved_out_mode),
            ):
                if saved is not None:
                    k.SetConsoleMode(k.GetStdHandle(handle_id), saved)
        except Exception:
            pass

    # -- readers -----------------------------------------------------------
    def _run_posix(self) -> None:
        """Fallback for non-Windows machines, so the code stays runnable there."""
        while not self._stop.is_set():
            line = sys.stdin.readline()
            if not line:
                time.sleep(0.1)
                continue
            self._emit(line.strip())

    def _run_windows(self) -> None:  # pragma: no cover - needs a real console
        import msvcrt

        editor = _Editor()
        paste: list[str] = []
        in_paste = False

        def read_escape() -> str:
            """Collect the rest of a VT sequence after ESC."""
            seq = ""
            deadline = time.time() + 0.05
            while time.time() < deadline and len(seq) < 12:
                if not msvcrt.kbhit():
                    time.sleep(0.001)
                    continue
                ch = msvcrt.getwch()
                seq += ch
                if seq[0] != "[":
                    break  # not a CSI sequence, stop collecting
                if ch.isalpha() or ch == "~":
                    break
            return seq

        while not self._stop.is_set():
            if not msvcrt.kbhit():
                time.sleep(0.01)
                continue
            ch = msvcrt.getwch()

            if ch == "\x1b":
                seq = read_escape()
                if seq == PASTE_START:
                    in_paste = True
                    paste = []
                elif seq == PASTE_END:
                    in_paste = False
                    text = scrub_paste("".join(paste))
                    paste = []
                    if text:
                        echo = (
                            f"[pasted {len(text)} chars]"
                            if len(text) > PASTE_ECHO_THRESHOLD
                            else text
                        )
                        editor.insert(text, echo_text=echo)
                continue

            if in_paste:
                paste.append(ch)
                continue

            if ch in ("\x00", "\xe0"):
                if msvcrt.kbhit():
                    msvcrt.getwch()  # swallow arrow / function key
                continue
            if ch == "\x03":  # Ctrl-C
                import _thread

                _thread.interrupt_main()
                continue
            if ch == "\x04":  # Ctrl-D
                self._emit("__EOF__")
                continue
            if ch in ("\r", "\n"):
                sys.stdout.write("\n")
                sys.stdout.flush()
                self._emit(editor.take())
                continue
            if ch in ("\x08", "\x7f"):
                editor.backspace()
                continue
            if ch == "\x15":  # Ctrl-U, clear the line
                sys.stdout.write("\r\x1b[2K")
                sys.stdout.flush()
                editor.clear()
                self.show_prompt()
                continue
            if ch < " " and ch not in ("\t",):
                continue
            editor.insert(ch)

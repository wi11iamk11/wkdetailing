"""Global hold-to-talk key listener.

pynput works out of the box in a normal Windows console process, no special
permission gate. It calls back on its own thread, so every event crosses into
asyncio with call_soon_threadsafe -- never add_reader, which the Windows
ProactorEventLoop does not implement.

The one bug that ruins everything if you skip it: Windows fires key-repeat
on_press events continuously while a key is held down. Without the held flag
below, every repeat reads as a fresh press, and each fresh press kills the
reply that is trying to speak.
"""

from __future__ import annotations

import asyncio
import time

import config

try:
    from pynput import keyboard
except Exception:  # pragma: no cover
    keyboard = None


PRESS = "press"
RELEASE = "release"


def resolve_key(name: str):
    """Turn a key name like 'ctrl_r', 'f8' or 'scroll_lock' into a pynput key."""
    if keyboard is None:
        raise RuntimeError("pynput is not installed. Run `uv sync`.")
    name = (name or "").strip().lower()
    special = getattr(keyboard.Key, name, None)
    if special is not None:
        return special
    if len(name) == 1:
        return keyboard.KeyCode.from_char(name)
    raise ValueError(
        f"Unknown key {name!r}. Try one of: ctrl_r, ctrl_l, alt_r, scroll_lock, "
        f"pause, f8, f9, or a single character."
    )


class PushToTalk:
    """Emits ("press", monotonic) and ("release", held_seconds) into an asyncio queue."""

    def __init__(self, loop: asyncio.AbstractEventLoop, out_queue: asyncio.Queue,
                 key_name: str | None = None, on_error=None):
        self.loop = loop
        self.out_queue = out_queue
        self.key_name = key_name or config.PTT_KEY
        self._on_error = on_error
        self._target = None
        self._listener = None
        self._held = False
        self._pressed_at = 0.0

    def start(self) -> None:
        self._target = resolve_key(self.key_name)
        self._listener = keyboard.Listener(
            on_press=self._on_press, on_release=self._on_release
        )
        self._listener.daemon = True
        self._listener.start()

    def stop(self) -> None:
        if self._listener is not None:
            try:
                self._listener.stop()
            except Exception:
                pass
            self._listener = None

    def _matches(self, key) -> bool:
        if key == self._target:
            return True
        char = getattr(key, "char", None)
        target_char = getattr(self._target, "char", None)
        return char is not None and target_char is not None and char == target_char

    def _post(self, event) -> None:
        try:
            self.loop.call_soon_threadsafe(self.out_queue.put_nowait, event)
        except RuntimeError:
            pass  # loop is shutting down

    def _on_press(self, key):  # pragma: no cover - needs a real keyboard
        try:
            if not self._matches(key):
                return
            if self._held:
                return  # key repeat, not a new press
            self._held = True
            self._pressed_at = time.monotonic()
            self._post((PRESS, self._pressed_at))
        except Exception as exc:
            if self._on_error:
                self._on_error(str(exc))

    def _on_release(self, key):  # pragma: no cover
        try:
            if not self._matches(key) or not self._held:
                return
            self._held = False
            self._post((RELEASE, time.monotonic() - self._pressed_at))
        except Exception as exc:
            if self._on_error:
                self._on_error(str(exc))

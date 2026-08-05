"""Spotify ducking through the Windows Core Audio session API.

pycaw reaches a specific application's own volume slider, which is exactly
what we want: Spotify goes quiet while the assistant talks, and nothing else
on the machine is touched.

Rules:
  - only duck when Spotify is actually playing above 30
  - duck to max(30, current * 0.6)
  - restore on a 1.2 second debounce, so back-to-back sentence chunks do not
    yo-yo the volume
  - never launch Spotify if it is not running

All COM work happens on one dedicated thread, because COM is apartment
threaded and the caller here is an asyncio loop. Everything is best effort:
ducking must never take the voice line down with it.
"""

from __future__ import annotations

import os
import threading
from concurrent.futures import ThreadPoolExecutor

TARGET_PROCESS = "spotify.exe"
DUCK_FLOOR = 30.0  # out of 100
DUCK_FACTOR = 0.6
RESTORE_DEBOUNCE_S = 1.2
_AUDIO_SESSION_ACTIVE = 1


def duck_level(current_pct: float, floor: float = DUCK_FLOOR,
               factor: float = DUCK_FACTOR) -> float | None:
    """The volume to duck to, or None if it is already quiet enough to leave alone."""
    if current_pct <= floor:
        return None
    return max(floor, current_pct * factor)


class SpotifyDucker:
    def __init__(self, enabled: bool = True, on_error=None):
        self.enabled = enabled and os.name == "nt"
        self._on_error = on_error
        self._original: float | None = None
        self._timer: threading.Timer | None = None
        self._lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="duck")
        self._com_ready = False
        if self.enabled:
            self._pool.submit(self._init_com)

    # -- COM plumbing ------------------------------------------------------
    def _init_com(self) -> None:
        try:
            import comtypes

            comtypes.CoInitialize()
            self._com_ready = True
        except Exception as exc:
            self.enabled = False
            self._report(f"ducking disabled: {exc}")

    def _report(self, msg: str) -> None:
        if self._on_error:
            try:
                self._on_error(msg)
            except Exception:
                pass

    def _volumes(self):
        """Every active Spotify audio session's volume interface."""
        from pycaw.pycaw import AudioUtilities, ISimpleAudioVolume

        out = []
        for session in AudioUtilities.GetAllSessions():
            proc = session.Process
            if proc is None:
                continue
            try:
                name = proc.name().lower()
            except Exception:
                continue
            if name != TARGET_PROCESS:
                continue
            if getattr(session, "State", _AUDIO_SESSION_ACTIVE) != _AUDIO_SESSION_ACTIVE:
                continue  # running but not playing
            try:
                out.append(session._ctl.QueryInterface(ISimpleAudioVolume))
            except Exception:
                continue
        return out

    # -- public API --------------------------------------------------------
    def duck(self) -> None:
        if not self.enabled:
            return
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None
        self._pool.submit(self._duck_now)

    def release(self) -> None:
        if not self.enabled:
            return
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
            self._timer = threading.Timer(RESTORE_DEBOUNCE_S, self._restore_now)
            self._timer.daemon = True
            self._timer.start()

    def shutdown(self) -> None:
        with self._lock:
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None
        if self.enabled:
            try:
                self._pool.submit(self._restore_now).result(timeout=2)
            except Exception:
                pass
        self._pool.shutdown(wait=False)

    # -- worker-thread bodies ---------------------------------------------
    def _duck_now(self) -> None:
        try:
            vols = self._volumes()
            if not vols:
                return
            current_pct = vols[0].GetMasterVolume() * 100.0
            target = duck_level(current_pct)
            if target is None:
                return
            if self._original is None:
                self._original = current_pct
            for v in vols:
                v.SetMasterVolume(target / 100.0, None)
        except Exception as exc:
            self._report(f"duck failed: {exc}")

    def _restore_now(self) -> None:
        original = self._original
        if original is None:
            return
        self._original = None

        def _do():
            try:
                for v in self._volumes():
                    v.SetMasterVolume(original / 100.0, None)
            except Exception as exc:
                self._report(f"restore failed: {exc}")

        # The timer fires on its own thread, so hop back to the COM thread.
        if threading.current_thread().name.startswith("duck"):
            _do()
        else:
            try:
                self._pool.submit(_do)
            except Exception:
                pass


class NullDucker:
    """Used when ducking is off or we are not on Windows."""

    enabled = False

    def duck(self) -> None:
        pass

    def release(self) -> None:
        pass

    def shutdown(self) -> None:
        pass

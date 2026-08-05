"""File-based signal bus that a visualizer can watch.

The contract is just files in the project root:

    .voice_state        plain text: idle | listening | thinking | speaking
    .voice_waveform     {"ts": <unix float>, "samples": [64 floats]}
    .voice_loading_pid  exists while a thinking sound is playing

One file is deliberately never written here: `.voice_alert` belongs to any
OTHER process on the machine that wants the visualizer's attention.

Every write is wrapped. The bus must never be able to crash the voice line.
"""

from __future__ import annotations

import array
import json
import os
import time

from config import ROOT, WAVEFORM_HZ, WAVEFORM_POINTS

STATE_PATH = ROOT / ".voice_state"
WAVEFORM_PATH = ROOT / ".voice_waveform"
LOADING_PATH = ROOT / ".voice_loading_pid"

IDLE = "idle"
LISTENING = "listening"
THINKING = "thinking"
SPEAKING = "speaking"

_MIN_INTERVAL = 1.0 / WAVEFORM_HZ if WAVEFORM_HZ > 0 else 0.0
_last_waveform = 0.0


def set_state(state: str) -> None:
    """Write the current state. Atomic where the OS allows it."""
    try:
        tmp = STATE_PATH.with_name(STATE_PATH.name + ".tmp")
        tmp.write_text(state, encoding="utf-8")
        os.replace(tmp, STATE_PATH)
    except Exception:
        # A visualizer holding the file open can block the replace on Windows.
        # Fall back to a direct write; a torn read self-corrects on the next tick.
        try:
            STATE_PATH.write_text(state, encoding="utf-8")
        except Exception:
            pass


def read_state() -> str:
    try:
        return STATE_PATH.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def downsample(block, points: int = WAVEFORM_POINTS) -> list[float]:
    """Reduce a PCM block to `points` magnitudes. Raw int16 magnitudes are fine.

    Accepts raw bytes, a numpy int16 array, or any sequence of ints.
    """
    if isinstance(block, (bytes, bytearray, memoryview)):
        raw = bytes(block)
        usable = len(raw) - (len(raw) % 2)
        samples = array.array("h")
        samples.frombytes(raw[:usable])
        samples = samples.tolist()
    elif hasattr(block, "tolist"):  # numpy
        samples = block.tolist()
    else:
        samples = list(block)

    total = len(samples)
    if total == 0:
        return [0.0] * points

    out = []
    for i in range(points):
        lo = total * i // points
        hi = max(total * (i + 1) // points, lo + 1)
        seg = samples[lo:hi]
        if not seg:
            out.append(0.0)
        else:
            out.append(sum(abs(s) for s in seg) / len(seg))
    return out


def waveform(block, force: bool = False) -> None:
    """Publish one waveform frame, at most WAVEFORM_HZ times per second.

    Self-heal rule: every waveform write also re-writes the state to
    "speaking". This only ever runs while audio is audibly playing, so any
    stray process that stomps the state file gets corrected within ~70 ms.
    """
    global _last_waveform
    try:
        now = time.time()
        if not force and (now - _last_waveform) < _MIN_INTERVAL:
            return
        _last_waveform = now
        payload = {"ts": now, "samples": [round(v, 2) for v in downsample(block)]}
        WAVEFORM_PATH.write_text(json.dumps(payload), encoding="utf-8")
        set_state(SPEAKING)
    except Exception:
        pass


def loading_start(pid: int | None = None) -> None:
    try:
        LOADING_PATH.write_text(str(pid if pid is not None else os.getpid()), encoding="utf-8")
    except Exception:
        pass


def loading_stop() -> None:
    try:
        LOADING_PATH.unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass


def reset() -> None:
    """Leave the bus in a clean state on startup and shutdown."""
    set_state(IDLE)
    loading_stop()

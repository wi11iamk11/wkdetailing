#!/usr/bin/env python3
"""voice-visualizer server: the only bridge between the voice line and the scene.

Two jobs, nothing else:
  1. serve the page
  2. serve /state as JSON, read from the voice line's signal bus files

STRICTLY READ-ONLY on the bus. This process never writes .voice_state,
.voice_waveform or .voice_alert. Two writers on one bus is how you get a
scene that flickers between states for reasons nobody can reproduce.

Standard library only. Whatever python3 is already on the machine is fine.

    python3 server.py            # real bus, port 8777
    python3 server.py --mock     # scripted loop, port 8778, bus untouched
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# --------------------------------------------------------------------------
# Constants -- edit these if your bus lives somewhere else
# --------------------------------------------------------------------------

BUS_DIR = Path.home() / "voice-line"
STATE_FILE = BUS_DIR / ".voice_state"
WAVEFORM_FILE = BUS_DIR / ".voice_waveform"
ALERT_FILE = BUS_DIR / ".voice_alert"

HOST = "127.0.0.1"
PORT = 8777
MOCK_PORT = 8778

# A waveform older than this is not live audio any more.
FRESH_S = 2.0
# Waveform samples are mean-absolute int16 magnitudes. This is roughly the
# mean level of loud speech, and what maps to level 1.0.
LEVEL_FULL_SCALE = 6000.0

VALID_STATES = ("idle", "listening", "thinking", "speaking")
ROOT = Path(__file__).resolve().parent

MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


# --------------------------------------------------------------------------
# Reading the bus
# --------------------------------------------------------------------------


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except Exception:
        return ""


def compute_level(samples) -> float:
    """Mean absolute sample, scaled to 0..1.

    Accepts either raw int16 magnitudes (what the voice line writes) or
    already-normalised 0..1 floats, so a different producer on the same bus
    still drives the scene sensibly.
    """
    if not samples:
        return 0.0
    try:
        vals = [abs(float(s)) for s in samples]
    except (TypeError, ValueError):
        return 0.0
    if not vals:
        return 0.0
    mean = sum(vals) / len(vals)
    scale = 1.0 if max(vals) <= 1.5 else LEVEL_FULL_SCALE
    return max(0.0, min(1.0, mean / scale))


def read_bus(want_samples: bool = False) -> dict:
    state = _read_text(STATE_FILE).lower()
    if state not in VALID_STATES:
        state = "idle"

    level = 0.0
    samples = []
    fresh = False
    try:
        raw = _read_text(WAVEFORM_FILE)
        if raw:
            data = json.loads(raw)
            ts = float(data.get("ts", 0.0))
            if (time.time() - ts) < FRESH_S:
                fresh = True
                samples = data.get("samples") or []
                level = compute_level(samples)
    except Exception:
        # A torn read while the voice line is mid-write is normal at 15 Hz.
        # Skip the frame rather than break the show.
        pass

    # Stomp tolerance: a live waveform means the voice IS speaking, whatever
    # the state file says. This is what protects the scene from any stray
    # process overwriting .voice_state mid-sentence.
    if fresh:
        state = "speaking"

    out = {
        "state": state,
        "level": round(level, 4),
        "alert": ALERT_FILE.exists(),
        "live": fresh,
    }
    if want_samples:
        out["samples"] = samples
    return out


# --------------------------------------------------------------------------
# Mock: a scripted loop, so the test path never touches the real bus
# --------------------------------------------------------------------------

MOCK_LOOP_S = 34.0


def mock_state(t: float, want_samples: bool = False) -> dict:
    """Walk idle -> listening -> thinking -> speaking -> alert -> idle."""
    p = t % MOCK_LOOP_S
    state, level, alert = "idle", 0.0, False

    if p < 4.0:
        state = "idle"
    elif p < 9.0:
        state = "listening"
    elif p < 14.0:
        state = "thinking"
    elif p < 26.0:
        state = "speaking"
        # Synthetic breathing: a slow phrase envelope, syllable-rate ripple,
        # and short pauses between "sentences".
        s = p - 14.0
        phrase = 0.5 + 0.5 * math.sin(s * 0.55)
        syll = 0.5 + 0.5 * math.sin(s * 9.3 + math.sin(s * 3.1) * 1.7)
        gap = 1.0 if (s % 5.5) < 4.6 else 0.05
        level = max(0.0, min(1.0, (0.22 + 0.78 * phrase * syll) * gap))
    elif p < 30.0:
        state = "idle"
        alert = True
    else:
        state = "idle"

    out = {"state": state, "level": round(level, 4), "alert": alert,
           "live": state == "speaking"}
    if want_samples:
        # 64 synthetic magnitudes so the on-die oscilloscope has something real
        # to draw in mock mode too.
        out["samples"] = [
            round(abs(math.sin(i * 0.31 + p * 6.0) * math.sin(i * 0.11 + p * 1.7))
                  * level * LEVEL_FULL_SCALE, 1)
            for i in range(64)
        ]
    return out


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    server_version = "voice-visualizer/1.0"
    mock = False
    verbose = False
    started = time.time()

    def log_message(self, fmt, *args):
        if self.verbose:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- helpers ----------------------------------------------------------
    def _send(self, code, body: bytes, ctype: str, no_store=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if no_store:
            self.send_header("Cache-Control", "no-store, max-age=0")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, obj):
        self._send(200, json.dumps(obj).encode("utf-8"),
                   "application/json; charset=utf-8", no_store=True)

    def _file(self, path: Path):
        try:
            body = path.read_bytes()
        except Exception:
            self._send(404, b"not found", "text/plain; charset=utf-8")
            return
        ctype = MIME.get(path.suffix.lower(), "application/octet-stream")
        self._send(200, body, ctype, no_store=path.suffix.lower() == ".html")

    # -- routing ----------------------------------------------------------
    def do_GET(self):
        raw = self.path.split("?", 1)
        route = raw[0]
        query = raw[1] if len(raw) > 1 else ""
        want_samples = "samples=1" in query

        if route == "/state":
            if self.mock:
                self._json(mock_state(time.time() - self.started, want_samples))
            else:
                self._json(read_bus(want_samples))
            return

        if route in ("/", "/index.html"):
            self._file(ROOT / "index.html")
            return

        if route == "/health":
            self._json({"ok": True, "mock": self.mock,
                        "bus": str(BUS_DIR), "pid": os.getpid()})
            return

        # Static files, confined to the project folder.
        rel = route.lstrip("/")
        target = (ROOT / rel).resolve()
        if not str(target).startswith(str(ROOT)) or not target.is_file():
            self._send(404, b"not found", "text/plain; charset=utf-8")
            return
        self._file(target)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="voice-visualizer server")
    ap.add_argument("--mock", action="store_true",
                    help="serve a scripted state loop on port 8778; never reads "
                         "or writes the real bus")
    ap.add_argument("--port", type=int, default=None)
    ap.add_argument("--verbose", action="store_true", help="log every request")
    args = ap.parse_args(argv)

    port = args.port or (MOCK_PORT if args.mock else PORT)
    Handler.mock = args.mock
    Handler.verbose = args.verbose
    Handler.started = time.time()

    httpd = ThreadingHTTPServer((HOST, port), Handler)
    httpd.daemon_threads = True
    mode = "MOCK (scripted loop, bus untouched)" if args.mock else f"bus {BUS_DIR}"
    print(f"voice-visualizer on http://{HOST}:{port}  [{mode}]  pid {os.getpid()}",
          flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

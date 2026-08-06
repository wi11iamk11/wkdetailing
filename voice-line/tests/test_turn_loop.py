"""Turn-loop wiring tests with faked audio devices.

This drives the real VoiceLine object -- the real mouth, the real gating, the
real state machine -- with stand-ins only for the things that need hardware or
a network: sounddevice, the whisper server, and the Claude session.

It is not a substitute for the on-machine checks (you still have to hear it),
but it does prove the wiring: that the mic is gated shut while the mouth
speaks, that the state file walks thinking -> speaking -> idle, that the wake
word gates hands-free turns, and that an interrupt stops playback and reopens
the mic.

Run with:  python tests/test_turn_loop.py
"""

from __future__ import annotations

import asyncio
import sys
import tempfile
import time
import types
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import numpy as np  # noqa: E402

import signals  # noqa: E402

_tmp = Path(tempfile.mkdtemp())
signals.STATE_PATH = _tmp / ".voice_state"
signals.WAVEFORM_PATH = _tmp / ".voice_waveform"
signals.LOADING_PATH = _tmp / ".voice_loading_pid"

import ears  # noqa: E402
import mouth as mouth_mod  # noqa: E402
import main as main_mod  # noqa: E402

FAILURES: list[str] = []
PASSES = 0


def check(name, cond, detail=""):
    global PASSES
    if cond:
        PASSES += 1
    else:
        FAILURES.append(f"{name}: {detail}")


# --- fakes ----------------------------------------------------------------


class FakeStream:
    def __init__(self, log):
        self.log = log
        self.active = True
        self.aborted = False

    def write(self, block):
        if self.aborted:
            raise RuntimeError("aborted")
        time.sleep(0.01)
        self.log.append(len(block))

    def abort(self):
        self.aborted = True
        self.active = False

    def start(self):
        self.aborted = False
        self.active = True

    def stop(self):
        self.active = False

    def close(self):
        pass


class FakeEngine:
    async def synth(self, text):
        await asyncio.sleep(0.01)
        return mouth_mod.Audio(24000, np.zeros(2048, dtype="<i2"))

    async def aclose(self):
        pass


class StubBrain:
    """Stands in for the Claude session; yields chunks on a schedule."""

    def __init__(self, chunks, per_chunk=0.01):
        self.chunks = chunks
        self.per_chunk = per_chunk
        self.project_dir = "/tmp"
        self.prompts = []
        self.interrupted = False

    async def stream_turn(self, text):
        self.prompts.append(text)
        for c in self.chunks:
            await asyncio.sleep(self.per_chunk)
            yield c

    async def interrupt(self):
        self.interrupted = True

    async def close(self):
        pass


def build_line(chunks=("First bit.", "Second bit.", "Third bit."), argv=None):
    args = main_mod.parse_args(list(argv or ["--no-duck"]))
    line = main_mod.VoiceLine(args)
    line.brain = StubBrain(list(chunks))
    line.mouth.engine = FakeEngine()
    return line


def states_seen():
    """Record every state written, by wrapping the bus."""
    seen = []
    original = signals.set_state

    def spy(state):
        seen.append(state)
        original(state)

    signals.set_state = spy
    return seen, (lambda: setattr(signals, "set_state", original))


# --- tests ----------------------------------------------------------------


def test_full_turn():
    writes = []
    mouth_mod.sd = types.SimpleNamespace(OutputStream=lambda **kw: FakeStream(writes))

    async def go():
        seen, restore = states_seen()
        line = build_line()
        await line.mouth.start()
        try:
            await line.handle_text("what is on port 2022", spoken=True)
            await line.turn_task
            check("turn.spoke", len(writes) == 6, f"{len(writes)} blocks for 3 chunks")
            check("turn.prompt_passed",
                  line.brain.prompts == ["what is on port 2022"], str(line.brain.prompts))
            check("turn.state_order",
                  "thinking" in seen and "speaking" in seen and seen[-1] == "idle",
                  str(seen))
            check("turn.mic_reopened", not line.mic.gated, "mic left gated after the turn")
            check("turn.follow_up_open", line.follow_up_until > time.monotonic(),
                  "follow-up window did not open")
        finally:
            restore()
            await line.mouth.close()

    asyncio.run(go())


def test_mic_is_gated_while_speaking():
    """Half duplex: the mic must be shut for the whole time audio is playing."""
    writes = []
    gated_during_playback = []

    class WatchingStream(FakeStream):
        def __init__(self, log, line_ref):
            super().__init__(log)
            self.line_ref = line_ref

        def write(self, block):
            gated_during_playback.append(self.line_ref[0].mic.gated)
            super().write(block)

    async def go():
        holder = [None]
        mouth_mod.sd = types.SimpleNamespace(
            OutputStream=lambda **kw: WatchingStream(writes, holder)
        )
        line = build_line()
        holder[0] = line
        await line.mouth.start()
        try:
            await line.handle_text("hello", spoken=True)
            await line.turn_task
            check("halfduplex.gated_throughout",
                  len(gated_during_playback) > 0 and all(gated_during_playback),
                  f"gate states during playback: {gated_during_playback}")
        finally:
            await line.mouth.close()

    asyncio.run(go())


def test_interrupt_mid_reply():
    writes = []
    mouth_mod.sd = types.SimpleNamespace(OutputStream=lambda **kw: FakeStream(writes))

    async def go():
        line = build_line(chunks=[f"Sentence {i}." for i in range(8)], argv=["--no-duck"])
        line.brain.per_chunk = 0.02
        await line.mouth.start()
        try:
            await line.handle_text("tell me a long thing", spoken=True)
            await asyncio.sleep(0.06)
            stopped = line.interrupt("by test")
            blocks_at_cut = len(writes)
            await asyncio.sleep(0.2)
            check("interrupt.reported", stopped, "interrupt() returned False")
            check("interrupt.stopped_audio", len(writes) - blocks_at_cut <= 1,
                  f"{len(writes) - blocks_at_cut} blocks after the cut")
            check("interrupt.told_the_brain", line.brain.interrupted,
                  "brain.interrupt() was never called")
            check("interrupt.mic_reopened", not line.mic.gated, "mic left gated")
            check("interrupt.not_all_played", len(writes) < 16,
                  f"{len(writes)} blocks played, expected far fewer")
        finally:
            await line.mouth.close()

    asyncio.run(go())


def test_replacement_turn_keeps_mic_shut():
    """A cancelled turn's cleanup must not reopen the mic under the new turn."""
    writes = []
    mouth_mod.sd = types.SimpleNamespace(OutputStream=lambda **kw: FakeStream(writes))

    async def go():
        line = build_line(chunks=[f"Sentence {i}." for i in range(8)])
        line.brain.per_chunk = 0.02
        await line.mouth.start()
        try:
            await line.handle_text("first question", spoken=True)
            await asyncio.sleep(0.05)
            # Barge in with a second turn while the first is still speaking.
            await line.handle_text("second question", spoken=True)
            # The cancelled turn resumes on the next tick. Its cleanup must not
            # run at all -- if it does, it reopens the mic and marks the bus
            # idle underneath the turn that is now speaking. follow_up_until is
            # the tell: only the cleanup path sets it.
            for _ in range(5):
                await asyncio.sleep(0)
            check("replace.no_stale_cleanup", line.follow_up_until == 0.0,
                  "the cancelled turn ran its cleanup under the live turn")
            check("replace.mic_still_shut", line.mic.gated,
                  "the cancelled turn reopened the mic while the new one was speaking")
            await line.turn_task
            check("replace.mic_reopens_at_end", not line.mic.gated,
                  "mic never reopened after the replacement turn finished")
        finally:
            await line.mouth.close()

    asyncio.run(go())


def test_wake_word_gates_hands_free():
    writes = []
    mouth_mod.sd = types.SimpleNamespace(OutputStream=lambda **kw: FakeStream(writes))

    async def go():
        line = build_line()
        await line.mouth.start()
        try:
            transcripts = iter([
                "so anyway the movie was fine",   # room chatter, must be ignored
                "Jarvis, restart the server",     # a real turn
            ])

            async def fake_transcribe(pcm, samplerate=16000, open_mic=False):
                return next(transcripts)

            line.transcriber.transcribe = fake_transcribe

            await line.on_utterance(b"\x00\x00" * 1600)
            check("wake.ignored_chatter", line.turn_task is None,
                  "room chatter started a turn")

            await line.on_utterance(b"\x00\x00" * 1600)
            check("wake.started_turn", line.turn_task is not None, "wake word did not fire")
            await line.turn_task
            check("wake.stripped",
                  line.brain.prompts == ["restart the server"], str(line.brain.prompts))

            # Inside the follow-up window, no wake word is needed.
            transcripts = iter(["and now run the tests"])
            await line.on_utterance(b"\x00\x00" * 1600)
            await line.turn_task
            check("wake.follow_up",
                  line.brain.prompts[-1] == "and now run the tests",
                  str(line.brain.prompts))
        finally:
            await line.mouth.close()

    asyncio.run(go())


def test_short_tap_ignored_in_ptt():
    writes = []
    mouth_mod.sd = types.SimpleNamespace(OutputStream=lambda **kw: FakeStream(writes))
    ears.sd = types.SimpleNamespace(RawInputStream=lambda **kw: types.SimpleNamespace(
        start=lambda: None, stop=lambda: None, close=lambda: None))

    async def go():
        line = build_line(argv=["--ptt", "--no-duck"])
        await line.mouth.start()
        try:
            await line.on_key((main_mod.PRESS, time.monotonic()))
            check("ptt.recording", line.recorder.active, "recorder did not start")
            line.recorder._started_at = time.monotonic() - 0.1  # a 100 ms tap
            await line.on_key((main_mod.RELEASE, 0.1))
            check("ptt.tap_ignored", line.turn_task is None, "a 100 ms tap started a turn")
        finally:
            await line.mouth.close()

    asyncio.run(go())


def test_quit_phrase_ends_session():
    writes = []
    mouth_mod.sd = types.SimpleNamespace(OutputStream=lambda **kw: FakeStream(writes))

    async def go():
        line = build_line()
        await line.mouth.start()
        try:
            await line.handle_text("goodbye", spoken=True)
            check("quit.stops", not line.running, "session still running after goodbye")
            check("quit.said_farewell", len(writes) > 0, "sign-off was never spoken")
            check("quit.no_turn", line.brain.prompts == [],
                  "goodbye was sent to the model as a turn")
        finally:
            await line.mouth.close()

    asyncio.run(go())


def test_typed_line_is_a_real_turn():
    writes = []
    mouth_mod.sd = types.SimpleNamespace(OutputStream=lambda **kw: FakeStream(writes))

    async def go():
        line = build_line()
        await line.mouth.start()
        try:
            await line.handle_text("typed question", spoken=False)
            await line.turn_task
            check("typed.spoken_aloud", len(writes) == 6, f"{len(writes)} blocks")
            check("typed.same_handler", line.brain.prompts == ["typed question"],
                  str(line.brain.prompts))

            await line.handle_text("mute", spoken=False)
            check("typed.mute", line.muted and line.mic.gated, "mute did not close the mic")
            await line.handle_text("unmute", spoken=False)
            check("typed.unmute", not line.muted and not line.mic.gated,
                  "unmute did not reopen the mic")
        finally:
            await line.mouth.close()

    asyncio.run(go())


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        try:
            t()
        except Exception:
            import traceback

            FAILURES.append(f"{t.__name__} raised\n{traceback.format_exc()}")
    print(f"\n{PASSES} checks passed, {len(FAILURES)} failed")
    for f in FAILURES:
        print(f"  FAIL {f}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())

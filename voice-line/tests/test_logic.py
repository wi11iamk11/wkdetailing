"""Logic tests for the voice line.

These cover everything that does not need a microphone, speakers, a GPU or a
Windows console: sentence chunking, markdown scrubbing, transcript cleaning,
wake-word matching, whisper route probing, the signal bus, paste scrubbing,
the ducking math, and the two-stage mouth pipeline (with fake audio devices).

Run with:  uv run python tests/test_logic.py     (or plain `python tests/test_logic.py`)
"""

from __future__ import annotations

import asyncio
import io
import json
import sys
import tempfile
import time
import types
import wave
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import claude_agent_sdk as sdk  # noqa: E402
import brain  # noqa: E402
import config  # noqa: E402
import console  # noqa: E402
import ducking  # noqa: E402
import ears  # noqa: E402
import signals  # noqa: E402
import state as state_mod  # noqa: E402

FAILURES: list[str] = []
PASSES = 0


def check(name, cond, detail=""):
    global PASSES
    if cond:
        PASSES += 1
    else:
        FAILURES.append(f"{name}: {detail}")


def eq(name, got, want):
    check(name, got == want, f"got {got!r}, want {want!r}")


# ---------------------------------------------------------------------------
# Sentence chunking
# ---------------------------------------------------------------------------


def test_sentence_split():
    sents, rest = brain.split_sentences("Hello there. How are you? ")
    eq("split.basic", sents, ["Hello there.", "How are you?"])
    eq("split.remainder_empty", rest, "")

    # A period at the very end of the buffer is not a boundary yet: more
    # tokens may still be arriving.
    sents, rest = brain.split_sentences("Half a sentence.")
    eq("split.pending", sents, [])
    eq("split.pending_rest", rest, "Half a sentence.")

    sents, _ = brain.split_sentences("Ask Dr. Chandra about it. Then leave. ")
    eq("split.abbrev", sents, ["Ask Dr. Chandra about it.", "Then leave."])

    sents, rest = brain.split_sentences("It costs 3.14 dollars per unit and ")
    eq("split.decimal", sents, [])


def test_chunker_breaths():
    c = brain.SentenceChunker()
    # First sentence ships alone: that is the number the ear measures.
    eq("chunk.first_alone", c.feed("On it. "), ["On it."])
    # Then two-sentence breaths.
    eq("chunk.waits_for_pair", c.feed("I checked the config. "), [])
    eq("chunk.breath",
       c.feed("The port is wrong. "),
       ["I checked the config. The port is wrong."])


def test_chunker_flush_on_block_stop():
    """The bug this prevents: filler before a tool call sitting silent."""
    c = brain.SentenceChunker()
    eq("flush.nothing_yet", c.feed("On it, checking now"), [])
    eq("flush.releases", c.flush(), ["On it, checking now"])
    # And the next block starts a fresh breath count without replaying anything.
    eq("flush.no_replay", c.feed("Found it. "), ["Found it."])
    eq("flush.empty_after", c.flush(), [])


def test_chunker_never_duplicates():
    c = brain.SentenceChunker()
    spoken = []
    for piece in ["The ", "answer ", "is ", "yes. ", "I ", "checked ", "twice."]:
        spoken.extend(c.feed(piece))
    spoken.extend(c.flush())
    spoken.extend(c.flush())  # a second flush must not re-emit
    eq("chunk.no_dupes", " ".join(spoken), "The answer is yes. I checked twice.")


def test_clean_for_speech():
    eq("clean.bold", brain.clean_for_speech("This is **very** important"),
       "This is very important")
    eq("clean.bullets", brain.clean_for_speech("- first\n- second"), "first second")
    eq("clean.heading", brain.clean_for_speech("## Results"), "Results")
    eq("clean.fence", brain.clean_for_speech("Try this ```print(1)``` and see"),
       "Try this and see")
    eq("clean.link", brain.clean_for_speech("see [the docs](http://x.io) now"),
       "see the docs now")
    eq("clean.inline_code", brain.clean_for_speech("run `uv sync` first"),
       "run uv sync first")
    # Last-resort net: even glued on with no newline, a STATE_UPDATE line
    # must never reach speech.
    eq("clean.state_leak",
       brain.clean_for_speech('Done for today. STATE_UPDATE: {"x": 1}'),
       "Done for today.")


# ---------------------------------------------------------------------------
# Durable state and the STATE_UPDATE line
# ---------------------------------------------------------------------------


def test_state_extract_and_merge():
    eq("state.is_update_true", state_mod.is_update_line('STATE_UPDATE: {"a": 1}'), True)
    eq("state.is_update_false", state_mod.is_update_line("just a sentence."), False)

    eq("state.extract_ok",
       state_mod.extract_update('STATE_UPDATE: {"deposit_cleared": true}'),
       {"deposit_cleared": True})
    eq("state.extract_bad_json", state_mod.extract_update("STATE_UPDATE: {not json"), None)
    eq("state.extract_not_object", state_mod.extract_update("STATE_UPDATE: [1, 2]"), None)
    eq("state.extract_wrong_prefix", state_mod.extract_update('{"a": 1}'), None)

    merged = state_mod.merge({"a": 1, "b": 2}, {"b": 3, "c": 4})
    eq("state.merge_overwrites_and_adds", merged, {"a": 1, "b": 3, "c": 4})


def test_state_save_load_roundtrip():
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "jarvis_state.json"
        old_path = state_mod.STATE_PATH
        state_mod.STATE_PATH = path
        try:
            eq("state.load_missing_file", state_mod.load(), {})
            state_mod.save({"invoice_1042": "unpaid"})
            eq("state.load_after_save", state_mod.load(), {"invoice_1042": "unpaid"})
            check("state.tmp_not_left_behind", not path.with_suffix(".tmp").exists())

            path.write_text("{not valid json", encoding="utf-8")
            eq("state.load_corrupt_file_is_empty", state_mod.load(), {})
        finally:
            state_mod.STATE_PATH = old_path


def test_state_list_merge_by_identity():
    state = {"assignments": [
        {"course": "CS 3400", "title": "Systems paper", "due": "2026-08-14T23:59",
         "status": "open", "notes": "8 pages"},
    ]}

    # Marking it done must not wipe the due date or notes it already had.
    merged = state_mod.merge(state, {"assignments": [
        {"course": "CS 3400", "title": "Systems paper", "status": "done"}]})
    eq("state.list_len_after_update", len(merged["assignments"]), 1)
    eq("state.list_status_updated", merged["assignments"][0]["status"], "done")
    eq("state.list_kept_due", merged["assignments"][0]["due"], "2026-08-14T23:59")
    eq("state.list_kept_notes", merged["assignments"][0]["notes"], "8 pages")

    # Identity ignores case and stray spacing, or a re-dictated title would
    # silently become a second assignment.
    merged = state_mod.merge(state, {"assignments": [
        {"course": "cs 3400", "title": "  systems paper ", "status": "done"}]})
    eq("state.list_identity_normalized", len(merged["assignments"]), 1)

    # A genuinely different assignment appends.
    merged = state_mod.merge(state, {"assignments": [
        {"course": "CS 3400", "title": "Problem set 4", "due": "2026-08-17"}]})
    eq("state.list_appends_new", len(merged["assignments"]), 2)

    # The original is never mutated in place.
    eq("state.merge_is_pure", state["assignments"][0]["status"], "open")

    # Keys with no identity defined still replace wholesale.
    merged = state_mod.merge({"cash": 100}, {"cash": 250})
    eq("state.scalar_still_replaces", merged["cash"], 250)


def test_state_parse_when():
    eq("when.datetime", state_mod.parse_when("2026-08-14T23:59"),
       datetime(2026, 8, 14, 23, 59))
    # A bare date means end of day: "due Friday" is not overdue at breakfast.
    eq("when.bare_date_is_end_of_day", state_mod.parse_when("2026-08-14"),
       datetime(2026, 8, 14, 23, 59))
    eq("when.garbage", state_mod.parse_when("sometime next week"), None)
    eq("when.empty", state_mod.parse_when(""), None)
    eq("when.wrong_type", state_mod.parse_when(None), None)
    check("when.trailing_z", state_mod.parse_when("2026-08-14T10:00:00Z") is not None)


def test_agenda():
    now = datetime(2026, 8, 10, 9, 0)
    state = {
        "assignments": [
            {"course": "CS 3400", "title": "Systems paper", "due": "2026-08-12T23:59"},
            {"course": "CS 3400", "title": "Old essay", "due": "2026-08-08T23:59"},
            {"course": "MATH 2400", "title": "Done already", "due": "2026-08-11",
             "status": "done"},
            {"course": "HIST 1010", "title": "Far future", "due": "2026-12-01"},
            {"course": "CS 3400", "title": "No date at all"},
        ],
        "exams": [{"course": "MATH 2400", "title": "Midterm", "at": "2026-08-14T10:00"}],
    }

    entries = state_mod.upcoming(state, now)
    titles = [e["title"] for e in entries]
    eq("agenda.order_and_filter", titles, ["Old essay", "Systems paper", "Midterm"])
    eq("agenda.overdue_flagged", entries[0]["overdue"], True)
    eq("agenda.exam_kind", entries[2]["kind"], "exam")

    rendered = state_mod.render_agenda(state, now)
    check("agenda.marks_overdue", "OVERDUE" in rendered, rendered)
    check("agenda.excludes_done", "Done already" not in rendered, rendered)
    check("agenda.excludes_far_future", "Far future" not in rendered, rendered)
    check("agenda.excludes_undated", "No date at all" not in rendered, rendered)

    eq("agenda.empty_state", state_mod.render_agenda({}, now),
       "Nothing dated is open in the next two weeks.")


def test_prompt_substitution_fills_clock_and_agenda():
    now = datetime(2026, 8, 10, 9, 0)
    state = {"assignments": [
        {"course": "CS 3400", "title": "Systems paper", "due": "2026-08-12T23:59"}]}
    built = brain._build_append_prompt(state, now)

    check("prompt.no_placeholders_left",
          "{{" not in built, [c for c in built.split() if "{{" in c])
    check("prompt.has_date", "August 2026" in built, built[:200])
    check("prompt.has_agenda_item", "Systems paper" in built)
    check("prompt.has_streaming_addendum", "voice_mode" in built)


class _FakeClient:
    """Stands in for ClaudeSDKClient: query() is a no-op, receive_response()
    replays a canned list of SDK messages."""

    def __init__(self, messages):
        self._messages = messages

    async def query(self, text):
        pass

    async def receive_response(self):
        for msg in self._messages:
            yield msg


def _delta_event(text):
    return sdk.StreamEvent(uuid="u", session_id="s",
                           event={"type": "content_block_delta",
                                  "delta": {"type": "text_delta", "text": text}})


def _block_start_event(block_type="text"):
    return sdk.StreamEvent(uuid="u", session_id="s",
                           event={"type": "content_block_start",
                                  "content_block": {"type": block_type}})


def _block_stop_event():
    return sdk.StreamEvent(uuid="u", session_id="s",
                           event={"type": "content_block_stop"})


def _result_message():
    return sdk.ResultMessage(subtype="success", duration_ms=0, duration_api_ms=0,
                             is_error=False, num_turns=1, session_id="s")


def _run_turn(brain_obj, messages):
    brain_obj._client = _FakeClient(messages)

    async def collect():
        return [c async for c in brain_obj.stream_turn("hi")]

    return asyncio.run(collect())


def test_stream_turn_state_update_not_spoken():
    with tempfile.TemporaryDirectory() as d:
        state_mod.STATE_PATH = Path(d) / "jarvis_state.json"
        updates = []
        b = brain.Brain(on_state_update=lambda u: updates.append(u))
        chunks = _run_turn(b, [
            _delta_event("Client draft goes first. "),
            _delta_event('\nSTATE_UPDATE: {"deposit_cleared": true}'),
            _block_stop_event(),
            _result_message(),
        ])
        eq("stream.speaks_only_prose", chunks, ["Client draft goes first."])
        eq("stream.state_applied", b.state, {"deposit_cleared": True})
        eq("stream.callback_fired", updates, [{"deposit_cleared": True}])
        eq("stream.persisted_to_disk", state_mod.load(), {"deposit_cleared": True})


def test_stream_turn_malformed_state_update_dropped():
    with tempfile.TemporaryDirectory() as d:
        state_mod.STATE_PATH = Path(d) / "jarvis_state.json"
        warnings = []
        b = brain.Brain(on_state_warning=lambda m: warnings.append(m))
        chunks = _run_turn(b, [
            _delta_event("Noted. "),
            _delta_event("\nSTATE_UPDATE: {not valid json"),
            _block_stop_event(),
            _result_message(),
        ])
        eq("stream.malformed_not_spoken", chunks, ["Noted."])
        eq("stream.malformed_state_unchanged", b.state, {})
        check("stream.malformed_warned", len(warnings) == 1, warnings)
        check("stream.malformed_not_persisted", not state_mod.STATE_PATH.exists())


def test_stream_turn_holds_tail_until_block_boundary():
    with tempfile.TemporaryDirectory() as d:
        state_mod.STATE_PATH = Path(d) / "jarvis_state.json"
        b = brain.Brain()
        chunks = _run_turn(b, [
            _delta_event("On it, one moment.\n"),
            _block_start_event("tool_use"),  # proves the held text wasn't final
            _delta_event("Found it."),
            _block_stop_event(),
            _result_message(),
        ])
        spoken = " ".join(chunks)
        check("stream.held_text_not_lost", "one moment" in spoken, spoken)
        check("stream.held_text_not_treated_as_state", b.state == {}, b.state)


# ---------------------------------------------------------------------------
# Transcripts and the wake word
# ---------------------------------------------------------------------------


def test_clean_transcript():
    eq("transcript.markers", ears.clean_transcript("[SIGHS] okay so [BLANK_AUDIO] yes"),
       "okay so yes")
    eq("transcript.asterisk", ears.clean_transcript("*laughs* fine"), "fine")
    eq("transcript.keeps_speech", ears.clean_transcript("what is on port 2022"),
       "what is on port 2022")
    # Hallucination filtering only applies to the always-open mic.
    eq("transcript.halluc_open", ears.clean_transcript("Thanks for watching!", open_mic=True), "")
    eq("transcript.halluc_ptt", ears.clean_transcript("Thanks for watching!", open_mic=False),
       "Thanks for watching!")
    eq("transcript.blank_only", ears.clean_transcript("[BLANK_AUDIO]", open_mic=True), "")


def test_wake_word():
    eq("wake.plain", ears.strip_wake_word("Jarvis, what time is it?"),
       (True, "what time is it?"))
    eq("wake.hey", ears.strip_wake_word("hey Jarvis run the tests"),
       (True, "run the tests"))
    eq("wake.misheard", ears.strip_wake_word("Jervis check the logs")[0], True)
    eq("wake.bare", ears.strip_wake_word("Jarvis?"), (True, ""))
    eq("wake.absent", ears.strip_wake_word("what time is it?")[0], False)
    # Not a turn just because the word shows up late in a sentence someone
    # said across the room.
    eq("wake.too_late",
       ears.strip_wake_word("I was telling Bob about the movie where Jarvis talks")[0],
       False)
    eq("wake.keeps_case", ears.strip_wake_word("Jarvis, open README.md")[1],
       "open README.md")


def test_wav_roundtrip():
    pcm = b"\x01\x02" * 1600
    data = ears.pcm_to_wav(pcm, 16000)
    with wave.open(io.BytesIO(data)) as wf:
        eq("wav.channels", wf.getnchannels(), 1)
        eq("wav.width", wf.getsampwidth(), 2)
        eq("wav.rate", wf.getframerate(), 16000)
        eq("wav.frames", wf.getnframes(), 1600)


def test_parse_payload():
    eq("payload.text", ears.parse_transcript_payload("application/json", '{"text":" hi "}'), "hi")
    eq("payload.segments",
       ears.parse_transcript_payload("application/json",
                                     '{"segments":[{"text":" one"},{"text":" two"}]}'),
       "one two")
    eq("payload.plain", ears.parse_transcript_payload("text/plain", "  raw text \n"), "raw text")


def test_route_probe():
    """A build that only serves /inference must still work."""
    import httpx

    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request.url.path)
        if request.url.path == "/inference":
            return httpx.Response(200, json={"text": "hello from whisper"})
        return httpx.Response(404, text="not found")

    async def go():
        client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        t = ears.Transcriber(base="http://127.0.0.1:2022", client=client)
        route = await t.probe()
        text = await t.transcribe(b"\x00\x00" * 100)
        await client.aclose()
        return route, text

    route, text = asyncio.run(go())
    eq("probe.route", route, "/inference")
    eq("probe.transcribes", text, "hello from whisper")
    check("probe.tried_inference_first", seen[0] == "/inference", str(seen))

    def only_openai(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/v1/audio/transcriptions":
            return httpx.Response(200, json={"text": "openai style"})
        return httpx.Response(501, text="nope")

    async def go2():
        client = httpx.AsyncClient(transport=httpx.MockTransport(only_openai))
        t = ears.Transcriber(base="http://127.0.0.1:2022", client=client)
        route = await t.probe()
        await client.aclose()
        return route

    eq("probe.fallback_route", asyncio.run(go2()), "/v1/audio/transcriptions")


# ---------------------------------------------------------------------------
# Signal bus
# ---------------------------------------------------------------------------


def test_signals():
    tmp = Path(tempfile.mkdtemp())
    signals.STATE_PATH = tmp / ".voice_state"
    signals.WAVEFORM_PATH = tmp / ".voice_waveform"
    signals.LOADING_PATH = tmp / ".voice_loading_pid"

    signals.set_state(signals.LISTENING)
    eq("signals.state", signals.read_state(), "listening")

    pts = signals.downsample(b"\x10\x27" * 512)  # 10000 repeated
    eq("signals.points", len(pts), 64)
    check("signals.magnitude", abs(pts[0] - 10000) < 1, str(pts[0]))

    signals._last_waveform = 0.0
    signals.set_state(signals.IDLE)
    signals.waveform(b"\x10\x27" * 512)
    payload = json.loads(signals.WAVEFORM_PATH.read_text())
    eq("signals.waveform_points", len(payload["samples"]), 64)
    check("signals.waveform_ts", isinstance(payload["ts"], float), str(payload["ts"]))
    # The self-heal rule: a waveform write always repairs the state file.
    eq("signals.self_heal", signals.read_state(), "speaking")

    # Throttled to WAVEFORM_HZ.
    signals.WAVEFORM_PATH.unlink()
    signals.waveform(b"\x00\x00" * 512)
    check("signals.throttled", not signals.WAVEFORM_PATH.exists(), "wrote twice too fast")

    signals.loading_start(1234)
    eq("signals.loading", signals.LOADING_PATH.read_text(), "1234")
    signals.loading_stop()
    check("signals.loading_gone", not signals.LOADING_PATH.exists())
    signals.loading_stop()  # must not raise when already gone

    # Never writes .voice_alert -- that file belongs to other processes.
    check("signals.no_alert", not (tmp / ".voice_alert").exists())


def test_signals_never_raises():
    signals.STATE_PATH = Path("/nonexistent-dir-xyz/.voice_state")
    signals.WAVEFORM_PATH = Path("/nonexistent-dir-xyz/.voice_waveform")
    signals.LOADING_PATH = Path("/nonexistent-dir-xyz/.voice_loading_pid")
    signals._last_waveform = 0.0
    try:
        signals.set_state("idle")
        signals.waveform(b"\x00\x00" * 64)
        signals.loading_start()
        signals.loading_stop()
        signals.reset()
        check("signals.no_crash", True)
    except Exception as exc:
        check("signals.no_crash", False, repr(exc))


# ---------------------------------------------------------------------------
# Paste scrubbing
# ---------------------------------------------------------------------------


def test_scrub_paste():
    eq("paste.hardwrap",
       console.scrub_paste("this line was hard\nwrapped by the terminal"),
       "this line was hard wrapped by the terminal")
    eq("paste.gutter",
       console.scrub_paste("│ def main():\n│     return 1"),
       "def main(): return 1")
    eq("paste.linenumbers",
       console.scrub_paste("  12→import os\n  13→import sys"),
       "import os import sys")
    eq("paste.quote", console.scrub_paste("> quoted text\n> more"), "quoted text more")
    eq("paste.crlf", console.scrub_paste("a\r\nb\r\n"), "a b")
    eq("paste.empty", console.scrub_paste(""), "")


# ---------------------------------------------------------------------------
# Ducking math
# ---------------------------------------------------------------------------


def test_duck_level():
    eq("duck.above", ducking.duck_level(100.0), 60.0)
    eq("duck.floor", ducking.duck_level(40.0), 30.0)  # 40*0.6=24 -> floored to 30
    eq("duck.already_quiet", ducking.duck_level(30.0), None)
    eq("duck.below_floor", ducking.duck_level(10.0), None)


# ---------------------------------------------------------------------------
# The mouth: two-stage pipeline, interrupt, no double play
# ---------------------------------------------------------------------------


class FakeStream:
    def __init__(self, log, write_delay=0.02):
        self.log = log
        self.active = True
        self.write_delay = write_delay
        self.aborted = False

    def write(self, block):
        if self.aborted:
            raise RuntimeError("stream aborted")
        time.sleep(self.write_delay)
        self.log.append(("write", len(block)))

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
    name = "fake"

    def __init__(self, events, delay=0.04, samples=2048):
        self.events = events
        self.delay = delay
        self.samples = samples

    async def synth(self, text):
        import numpy as np

        self.events.append(("synth_start", text))
        await asyncio.sleep(self.delay)
        self.events.append(("synth_end", text))
        return mouth_mod.Audio(24000, np.zeros(self.samples, dtype="<i2"))

    async def aclose(self):
        pass


def _install_fake_sd(log):
    fake = types.SimpleNamespace(
        OutputStream=lambda **kw: FakeStream(log),
        RawInputStream=lambda **kw: None,
    )
    mouth_mod.sd = fake


def test_mouth_pipeline_overlaps():
    """Synthesis of the next sentence must overlap playback of the current one.

    A one-queue loop that synthesizes then plays each sentence to completion
    produces an audible dead-air gap at every sentence boundary. The timeline
    below is what proves the two-stage pipeline is doing its job.
    """
    writes = []
    events = []
    _install_fake_sd(writes)

    async def go():
        m = mouth_mod.Mouth(FakeEngine(events))
        await m.start()
        for s in ["one.", "two.", "three."]:
            m.say(s)
        await m.drain()
        await m.close()

    started = time.monotonic()
    asyncio.run(go())
    elapsed = time.monotonic() - started

    order = [f"{k}:{v}" for k, v in events]
    # Sentence two is being synthesized before sentence one has finished playing.
    play_writes = [i for i, w in enumerate(writes)]
    check("mouth.all_played", len(writes) == 6, f"{len(writes)} writes for 3 sentences")
    i_synth2 = order.index("synth_start:two.")
    i_synth1_end = order.index("synth_end:one.")
    check("mouth.pipelined", i_synth2 == i_synth1_end + 1,
          f"synthesis did not run ahead: {order}")
    # Fully sequential would be 3*(40ms synth + 40ms play) = 240ms.
    check("mouth.faster_than_sequential", elapsed < 0.22, f"{elapsed:.3f}s")


def test_mouth_interrupt():
    writes = []
    events = []
    _install_fake_sd(writes)

    async def go():
        m = mouth_mod.Mouth(FakeEngine(events, delay=0.02))
        await m.start()
        for s in ["one.", "two.", "three.", "four."]:
            m.say(s)
        await asyncio.sleep(0.05)
        m.interrupt()
        before = len(writes)
        await asyncio.sleep(0.15)  # nothing from the old turn may arrive late
        after = len(writes)
        # At most the one block already handed to the device can land; the
        # queued sentences (8 blocks' worth) must never be played.
        check("mouth.interrupt_stops", after - before <= 1,
              f"{after - before} blocks played after interrupt")
        check("mouth.queue_dropped", after < 8, f"{after} blocks total, expected < 8")
        check("mouth.not_speaking", not m.speaking, "still marked speaking")

        # And a new turn still works afterwards.
        events.clear()
        m.say("fresh.")
        await m.drain()
        check("mouth.recovers", ("synth_start", "fresh.") in events, str(events))
        await m.close()

    asyncio.run(go())


def test_mouth_elevenlabs_falls_back():
    """A dead ElevenLabs must degrade to Kokoro, not go mute."""
    import numpy as np

    class DeadEleven(mouth_mod.ElevenLabsEngine):
        async def synth(self, text):
            return await super().synth(text)

    class FakeKokoro:
        def __init__(self):
            self.calls = []

        async def synth(self, text):
            self.calls.append(text)
            return mouth_mod.Audio(24000, np.zeros(64, dtype="<i2"))

        async def aclose(self):
            pass

    fallback = FakeKokoro()
    warned = []
    eleven = mouth_mod.ElevenLabsEngine(fallback, voice_id="",
                                        on_fallback=warned.append)
    audio = asyncio.run(eleven.synth("hello"))
    check("eleven.fallback_used", fallback.calls == ["hello"], str(fallback.calls))
    check("eleven.warned", len(warned) == 1, str(warned))
    eq("eleven.audio_rate", audio.samplerate, 24000)


# ---------------------------------------------------------------------------


def main():
    global mouth_mod
    import mouth as mouth_mod  # noqa: F401  (imported late so sd can be faked)

    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        try:
            t()
        except Exception as exc:
            import traceback

            FAILURES.append(f"{t.__name__} raised {exc!r}\n{traceback.format_exc()}")

    print(f"\n{PASSES} checks passed, {len(FAILURES)} failed")
    for f in FAILURES:
        print(f"  FAIL {f}")
    return 1 if FAILURES else 0


mouth_mod = None

if __name__ == "__main__":
    sys.exit(main())

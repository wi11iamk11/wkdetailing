"""voice-line: talk to Claude out loud at your desk.

    mic -> ears (capture + local whisper) -> warm Claude Agent SDK session
        -> mouth (sentence-chunked TTS, cancellable) -> speakers

Half duplex on purpose: the mic is gated shut while the mouth is speaking, so
the system can never hear itself. No barge-in on open speakers.

Default mode is hands free -- the mic stays open and an utterance only counts
as a turn when it starts with the wake word. Pass --ptt for hold-to-talk,
which has no false-trigger risk at all because the mic is shut between holds.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys
import time

import config
import ears
import signals
import state
from brain import Brain
from console import ConsoleReader
from ducking import NullDucker, SpotifyDucker
from mouth import Mouth, build_engine
from ptt import PRESS, RELEASE, PushToTalk

C_DIM = "\x1b[2m"
C_OFF = "\x1b[0m"
C_YOU = "\x1b[36m"
C_ME = "\x1b[32m"
C_WARN = "\x1b[33m"


def log(msg: str, color: str = C_DIM) -> None:
    print(f"{color}{msg}{C_OFF}", flush=True)


def normalize(text: str) -> str:
    return "".join(c for c in text.lower() if c.isalnum() or c.isspace()).strip()


def is_quit(text: str) -> bool:
    norm = normalize(text)
    return any(norm == p or norm.startswith(p + " ") or norm.endswith(" " + p)
               for p in (normalize(q) for q in config.QUIT_PHRASES))


class VoiceLine:
    def __init__(self, args):
        self.args = args
        self.loop = asyncio.get_running_loop()
        self.running = True

        self.mic = ears.Microphone(device=args.input_device)
        self.transcriber = ears.Transcriber()
        self.recorder = ears.HoldRecorder(self.mic)
        self.vad: ears.VadListener | None = None

        self.key_q: asyncio.Queue = asyncio.Queue()
        self.typed_q: asyncio.Queue = asyncio.Queue()
        self.utter_q: asyncio.Queue = asyncio.Queue()

        self.ducker = NullDucker() if args.no_duck else SpotifyDucker(
            on_error=lambda m: log(f"[duck] {m}", C_WARN)
        )
        engine = build_engine(
            args.voice,
            voice_id=args.voice_id,
            master=not args.no_master,
            on_fallback=lambda m: log(f"[voice] {m}", C_WARN),
        )
        self.mouth = Mouth(engine, ducker=self.ducker, output_device=args.output_device,
                           on_error=lambda m: log(f"[mouth] {m}", C_WARN))
        self.mouth.on_speaking_start = self._on_speaking_start
        self.mouth.on_speaking_end = self._on_speaking_end

        self.brain = Brain(project_dir=args.project, model=args.model,
                           permission_mode="bypassPermissions" if args.yolo else None,
                           on_state_update=lambda u: log(f"[state] {u}"),
                           on_state_warning=lambda m: log(f"[state] {m}", C_WARN))
        self.ptt: PushToTalk | None = None
        self.console: ConsoleReader | None = None

        self.turn_task: asyncio.Task | None = None
        self.muted = False
        self.follow_up_until = 0.0
        self.wake_enabled = (not args.ptt) and (not args.no_wake)

    # -- half duplex -------------------------------------------------------
    def _on_speaking_start(self) -> None:
        self.mic.gate(True)

    def _on_speaking_end(self) -> None:
        # Anything the speakers put into the room while talking is discarded
        # before the gate reopens.
        self.mic.drain()
        if not self.muted:
            self.mic.gate(False)

    # -- setup -------------------------------------------------------------
    async def setup(self) -> None:
        signals.reset()
        log(f"project    {self.brain.project_dir}")
        if config.JARVIS_PROMPT_PATH is not None:
            log(f"prompt     {config.JARVIS_PROMPT_PATH} (state: {state.STATE_PATH})")
        else:
            log("prompt     no prompts/jarvis-system-prompt.md found, using SPOKEN_DISCIPLINE")

        route = await self.transcriber.probe()
        log(f"whisper    {config.WHISPER_BASE}{route}")

        if self.args.voice == "elevenlabs":
            key = "set" if os.environ.get(config.ELEVEN_API_KEY_ENV) else "MISSING"
            log(f"voice      elevenlabs ({config.ELEVEN_MODEL}, key {key}), "
                f"kokoro as fallback")
        else:
            log(f"voice      kokoro {config.KOKORO_VOICE} at {config.KOKORO_BASE}")

        await self.mouth.start()
        await self.brain.start()

        self.console = ConsoleReader(self.loop, self.typed_q)
        self.console.start()

        try:
            self.ptt = PushToTalk(self.loop, self.key_q, key_name=self.args.key,
                                  on_error=lambda m: log(f"[ptt] {m}", C_WARN))
            self.ptt.start()
        except Exception as exc:
            self.ptt = None
            log(f"[ptt] key listener unavailable: {exc}", C_WARN)

        if self.args.ptt:
            log(f"mode       hold-to-talk on {self.args.key}")
        else:
            self.vad = ears.VadListener(self.mic, self.loop, self.utter_q)
            self.vad.start()
            if self.wake_enabled:
                log(f"mode       hands free, wake word \"{config.WAKE_WORD}\"")
            else:
                log("mode       hands free, no wake word (everything is a turn)")

        print()
        log("hold-to-talk key also works as INTERRUPT at any time. "
            "Type to talk. Say goodbye to hang up.\n")

        # Hide the first-turn prompt-cache toll behind the greeting.
        self.mouth.say(config.GREETING)
        await self.brain.warmup()
        await self.mouth.drain()
        self._prompt()

    def _prompt(self) -> None:
        if self.console is not None:
            self.console.show_prompt()

    # -- interrupts --------------------------------------------------------
    def interrupt(self, reason: str = "") -> bool:
        stopped = False
        if self.turn_task is not None and not self.turn_task.done():
            self.turn_task.cancel()
            asyncio.create_task(self.brain.interrupt())
            stopped = True
        if self.mouth.speaking:
            self.mouth.interrupt()
            stopped = True
        if stopped:
            log(f"\n[cut off{' ' + reason if reason else ''}]")
            signals.set_state(signals.IDLE)
            self.mic.drain()
            if not self.muted:
                self.mic.gate(False)
        return stopped

    # -- turns -------------------------------------------------------------
    async def handle_text(self, text: str, spoken: bool) -> None:
        text = (text or "").strip()
        if not text:
            self._prompt()
            return

        if not spoken:
            lowered = text.lower()
            if lowered == "__eof__":
                self.running = False
                return
            if lowered in ("mute", "/mute"):
                self.muted = True
                self.mic.gate(True)
                log("[mic muted]")
                self._prompt()
                return
            if lowered in ("unmute", "/unmute"):
                self.muted = False
                self.mic.gate(False)
                log("[mic live]")
                self._prompt()
                return

        if is_quit(text):
            print(f"{C_YOU}you> {text}{C_OFF}")
            self.mouth.say(config.SIGN_OFF)
            await self.mouth.drain()
            self.running = False
            return

        print(f"{C_YOU}you> {text}{C_OFF}")
        self.interrupt()
        signals.set_state(signals.THINKING)
        self.mic.gate(True)  # half duplex from the moment we commit
        self.turn_task = asyncio.create_task(self._run_turn(text))

    async def _run_turn(self, text: str) -> None:
        started = time.monotonic()
        first_chunk = True
        try:
            async with asyncio.timeout(config.TURN_TIMEOUT_S):
                async for chunk in self.brain.stream_turn(text):
                    if first_chunk:
                        log(f"[first chunk in {time.monotonic() - started:.1f}s]")
                        first_chunk = False
                    print(f"{C_ME}claude> {chunk}{C_OFF}")
                    self.mouth.say(chunk)
            await self.mouth.drain()
        except asyncio.CancelledError:
            raise
        except TimeoutError:
            self.mouth.say("That one stalled out. Try me again.")
            await self.mouth.drain()
        except Exception as exc:
            log(f"[brain] {type(exc).__name__}: {exc}", C_WARN)
            self.mouth.say("Something went wrong on my side.")
            await self.mouth.drain()
        finally:
            # Only clean up if this is still the live turn. A cancelled turn's
            # finally block runs on a later tick, by which point a replacement
            # turn may already be speaking -- reopening the mic here would
            # break half duplex and let the speakers back into the mic.
            if self.turn_task is asyncio.current_task():
                signals.set_state(signals.IDLE)
                self.mic.drain()
                if not self.muted:
                    self.mic.gate(False)
                self.follow_up_until = time.monotonic() + config.FOLLOW_UP_WINDOW_S
                self._prompt()

    # -- input handlers ----------------------------------------------------
    async def on_key(self, event) -> None:
        kind, value = event
        if kind == PRESS:
            if self.interrupt("by key"):
                if not self.args.ptt:
                    self._prompt()
                    return
            if self.args.ptt:
                signals.set_state(signals.LISTENING)
                log("[listening]")
                self.recorder.start()
        elif kind == RELEASE and self.args.ptt:
            pcm, held = await self.recorder.stop()
            if held < config.MIN_HOLD_S:
                log(f"[tap ignored, {held * 1000:.0f}ms]")
                signals.set_state(signals.IDLE)
                self._prompt()
                return
            signals.set_state(signals.THINKING)
            text = await self._transcribe(pcm, open_mic=False)
            if not text:
                log("[nothing heard]")
                signals.set_state(signals.IDLE)
                self._prompt()
                return
            await self.handle_text(text, spoken=True)

    async def on_utterance(self, pcm: bytes) -> None:
        if self.muted or self.mouth.speaking:
            return
        signals.set_state(signals.LISTENING)
        text = await self._transcribe(pcm, open_mic=True)
        if not text:
            signals.set_state(signals.IDLE)
            return

        if self.wake_enabled and time.monotonic() > self.follow_up_until:
            matched, remainder = ears.strip_wake_word(text)
            if not matched:
                log(f"[ignored: {text}]")
                signals.set_state(signals.IDLE)
                return
            if not remainder:
                # Bare "Jarvis" -- acknowledge and hold the door open.
                self.mouth.say("Yeah?")
                self.follow_up_until = time.monotonic() + config.FOLLOW_UP_WINDOW_S
                return
            text = remainder
        elif self.wake_enabled:
            matched, remainder = ears.strip_wake_word(text)
            if matched and remainder:
                text = remainder

        await self.handle_text(text, spoken=True)

    async def _transcribe(self, pcm: bytes, open_mic: bool) -> str:
        if not pcm:
            return ""
        try:
            return await self.transcriber.transcribe(pcm, open_mic=open_mic)
        except Exception as exc:
            log(f"[whisper] {type(exc).__name__}: {exc}", C_WARN)
            return ""

    # -- the loop ----------------------------------------------------------
    async def run(self) -> None:
        # Race every input source, and keep the unfinished futures alive across
        # iterations so nothing is dropped between turns.
        waiters = {
            asyncio.ensure_future(self.key_q.get()): ("key", self.key_q),
            asyncio.ensure_future(self.typed_q.get()): ("typed", self.typed_q),
            asyncio.ensure_future(self.utter_q.get()): ("utter", self.utter_q),
        }
        try:
            while self.running:
                done, _ = await asyncio.wait(waiters.keys(),
                                             return_when=asyncio.FIRST_COMPLETED)
                for fut in done:
                    kind, queue = waiters.pop(fut)
                    try:
                        item = fut.result()
                    except asyncio.CancelledError:
                        continue
                    waiters[asyncio.ensure_future(queue.get())] = (kind, queue)
                    if kind == "key":
                        await self.on_key(item)
                    elif kind == "typed":
                        if self.mouth.speaking or (
                            self.turn_task is not None and not self.turn_task.done()
                        ):
                            self.interrupt("by typing")
                        await self.handle_text(item, spoken=False)
                    else:
                        await self.on_utterance(item)
                    if not self.running:
                        break
        finally:
            for fut in waiters:
                fut.cancel()

    async def shutdown(self) -> None:
        log("\nhanging up")
        if self.turn_task is not None and not self.turn_task.done():
            self.turn_task.cancel()
        if self.vad is not None:
            self.vad.stop()
        if self.ptt is not None:
            self.ptt.stop()
        if self.console is not None:
            self.console.stop()
        self.mouth.interrupt()
        await self.mouth.close()
        await self.brain.close()
        await self.transcriber.aclose()
        self.ducker.shutdown()
        self.mic.close()
        signals.reset()


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        prog="voice-line",
        description="Hands-free (or hold-to-talk) voice conversation with Claude.",
    )
    p.add_argument("--ptt", action="store_true",
                   help="hold-to-talk instead of hands free; mic is shut between holds")
    p.add_argument("--open-mic", action="store_true",
                   help="hands-free mode (this is the default; kept for muscle memory)")
    p.add_argument("--no-wake", action="store_true",
                   help="hands free without the wake word: every utterance is a turn")
    p.add_argument("--wake", default=None, help=f"wake word (default {config.WAKE_WORD})")
    p.add_argument("--key", default=config.PTT_KEY,
                   help="hold-to-talk / interrupt key (default ctrl_r)")
    p.add_argument("--voice", choices=config.VOICE_CHOICES, default=config.VOICE,
                   help=f"TTS engine (default {config.VOICE}, from VOICE_LINE_VOICE)")
    p.add_argument("--voice-id", default="", help="ElevenLabs voice id")
    p.add_argument("--no-master", action="store_true",
                   help="skip the local ffmpeg mastering chain on ElevenLabs audio")
    p.add_argument("--no-duck", action="store_true", help="do not duck Spotify")
    p.add_argument("--project", default="", help="cwd for the Claude session")
    p.add_argument("--model", default="", help="model override")
    p.add_argument("--yolo", action="store_true",
                   help="bypassPermissions: never stall a turn on a permission prompt")
    p.add_argument("--input-device", default=None, help="input device index or name")
    p.add_argument("--output-device", default=None, help="output device index or name")
    p.add_argument("--list-devices", action="store_true", help="list audio devices and exit")
    args = p.parse_args(argv)
    # argparse validates `choices` for arguments that are passed, but not for a
    # default -- so a typo in VOICE_LINE_VOICE would sail through and only
    # surface as a silent fallback to Kokoro inside build_engine.
    if args.voice not in config.VOICE_CHOICES:
        p.error(f"VOICE_LINE_VOICE is {args.voice!r}; expected one of "
                f"{', '.join(config.VOICE_CHOICES)}")
    for attr in ("input_device", "output_device"):
        val = getattr(args, attr)
        if val is not None and str(val).isdigit():
            setattr(args, attr, int(val))
    if args.wake:
        config.WAKE_WORD = args.wake.lower()
    return args


async def amain(args) -> int:
    line = VoiceLine(args)
    try:
        await line.setup()
    except Exception as exc:
        log(f"\nstartup failed: {exc}", C_WARN)
        await line.shutdown()
        return 2
    try:
        await line.run()
    except KeyboardInterrupt:
        pass
    finally:
        await line.shutdown()
    return 0


def main(argv=None) -> int:
    args = parse_args(argv)

    if args.list_devices:
        import sounddevice as sd

        print(sd.query_devices())
        return 0

    # Leave the event loop policy ALONE on Windows. The Claude Agent SDK needs
    # the ProactorEventLoop for subprocess handling; swapping in a selector
    # loop to get add_reader back would break it. Nothing in this program reads
    # input through the loop -- input arrives on threads.
    print(f"{C_DIM}voice-line{C_OFF}")
    try:
        return asyncio.run(amain(args))
    except KeyboardInterrupt:
        signals.reset()
        return 0


if __name__ == "__main__":
    sys.exit(main())

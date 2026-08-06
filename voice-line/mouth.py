"""TTS synthesis and playback.

The shape that matters: two stages, two queues. Synthesis of the NEXT sentence
overlaps playback of the current one. A single-queue loop that synthesizes then
plays each sentence to completion produces a real, audible dead-air gap at
every sentence boundary.

    say(text) -> text_q -> [synth worker] -> audio_q -> [play worker] -> speakers

Interrupt bumps a generation counter, drains both queues and aborts the open
stream, so in-flight work from the previous turn is discarded rather than
played late.
"""

from __future__ import annotations

import asyncio
import os
import subprocess
from dataclasses import dataclass

import httpx
import numpy as np

import config
import signals

try:
    import sounddevice as sd
except Exception:  # pragma: no cover
    sd = None

_NO_WINDOW = 0x08000000 if os.name == "nt" else 0


@dataclass
class Audio:
    samplerate: int
    pcm: np.ndarray  # mono int16


# ---------------------------------------------------------------------------
# Engines
# ---------------------------------------------------------------------------


class KokoroEngine:
    """Local kokoro-fastapi. Free, fast, and the fallback for everything else."""

    name = "kokoro"

    def __init__(self, client: httpx.AsyncClient | None = None):
        self._client = client or httpx.AsyncClient(timeout=config.KOKORO_TIMEOUT_S)
        self._owns = client is None

    async def synth(self, text: str) -> Audio:
        resp = await self._client.post(
            f"{config.KOKORO_BASE}/v1/audio/speech",
            json={
                "model": "kokoro",
                "input": text,
                "voice": config.KOKORO_VOICE,
                "response_format": "pcm",  # raw int16, 24 kHz, mono
                "speed": config.KOKORO_SPEED,
            },
        )
        resp.raise_for_status()
        pcm = np.frombuffer(resp.content, dtype="<i2")
        return Audio(config.KOKORO_SR, pcm)

    async def health(self) -> bool:
        try:
            await self.synth("ok")
            return True
        except Exception:
            return False

    async def aclose(self):
        if self._owns:
            await self._client.aclose()


def master_mp3(mp3: bytes, chain: str | None = None) -> np.ndarray:
    """Decode mp3 and master it locally with ffmpeg.

    ElevenLabs website previews are mastered demo clips; raw API output never
    matches them. Presence lift around 3.2k, a little low shelf, gentle
    compression, limiter.
    """
    args = [config.FFMPEG_BIN, "-hide_banner", "-loglevel", "error", "-i", "pipe:0"]
    if chain:
        args += ["-af", chain]
    args += ["-ar", str(config.ELEVEN_SR), "-ac", "1", "-f", "s16le", "pipe:1"]
    proc = subprocess.run(args, input=mp3, capture_output=True, creationflags=_NO_WINDOW)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {proc.stderr.decode(errors='replace')[:300]}")
    return np.frombuffer(proc.stdout, dtype="<i2")


class ElevenLabsEngine:
    """ElevenLabs turbo, with Kokoro wired in underneath as automatic fallback.

    If the key is missing, the service is down, or the credits run out, the
    voice degrades to local instead of going mute.
    """

    name = "elevenlabs"

    def __init__(self, fallback: KokoroEngine, voice_id: str = "",
                 master: bool = True, client: httpx.AsyncClient | None = None,
                 on_fallback=None):
        self.fallback = fallback
        self.voice_id = voice_id or config.ELEVEN_VOICE_ID
        self.master = master
        self.api_key = os.environ.get(config.ELEVEN_API_KEY_ENV, "")
        self._client = client or httpx.AsyncClient(timeout=config.ELEVEN_TIMEOUT_S)
        self._owns = client is None
        self._on_fallback = on_fallback
        self._warned = False

    def _warn(self, reason: str) -> None:
        if self._on_fallback is not None and not self._warned:
            self._warned = True
            self._on_fallback(reason)

    async def synth(self, text: str) -> Audio:
        if not self.api_key:
            self._warn(f"{config.ELEVEN_API_KEY_ENV} is not set, using Kokoro")
            return await self.fallback.synth(text)
        if not self.voice_id:
            self._warn("no ELEVENLABS_VOICE_ID set, using Kokoro")
            return await self.fallback.synth(text)
        try:
            resp = await self._client.post(
                f"{config.ELEVEN_BASE}/text-to-speech/{self.voice_id}/stream",
                params={"output_format": config.ELEVEN_OUTPUT_FORMAT},
                headers={"xi-api-key": self.api_key, "accept": "audio/mpeg"},
                json={
                    "text": text,
                    "model_id": config.ELEVEN_MODEL,
                    "voice_settings": {
                        "stability": config.ELEVEN_STABILITY,
                        "similarity_boost": config.ELEVEN_SIMILARITY,
                        "style": config.ELEVEN_STYLE,
                        "use_speaker_boost": config.ELEVEN_SPEAKER_BOOST,
                    },
                },
            )
            resp.raise_for_status()
            pcm = await asyncio.to_thread(
                master_mp3, resp.content, config.MASTER_CHAIN if self.master else None
            )
            return Audio(config.ELEVEN_SR, pcm)
        except Exception as exc:
            self._warn(f"ElevenLabs failed ({type(exc).__name__}), falling back to Kokoro")
            return await self.fallback.synth(text)

    async def aclose(self):
        if self._owns:
            await self._client.aclose()
        await self.fallback.aclose()


def build_engine(kind: str, voice_id: str = "", master: bool = True, on_fallback=None):
    kokoro = KokoroEngine()
    if kind == "elevenlabs":
        return ElevenLabsEngine(kokoro, voice_id=voice_id, master=master,
                                on_fallback=on_fallback)
    return kokoro


# ---------------------------------------------------------------------------
# The mouth
# ---------------------------------------------------------------------------


class Mouth:
    def __init__(self, engine, ducker=None, output_device=None, on_error=None):
        self.engine = engine
        self.ducker = ducker
        self.output_device = output_device
        self._on_error = on_error

        self.text_q: asyncio.Queue = asyncio.Queue()
        self.audio_q: asyncio.Queue = asyncio.Queue(maxsize=2)
        self._gen = 0
        self._inflight = 0
        self._idle = asyncio.Event()
        self._idle.set()
        self._speaking = False
        self._streams: dict[int, object] = {}
        self._active_stream = None
        self._tasks: list[asyncio.Task] = []
        self.on_speaking_start = None
        self.on_speaking_end = None

    # -- lifecycle ---------------------------------------------------------
    async def start(self) -> None:
        self._tasks = [
            asyncio.create_task(self._synth_worker(), name="mouth-synth"),
            asyncio.create_task(self._play_worker(), name="mouth-play"),
        ]

    async def close(self) -> None:
        for t in self._tasks:
            t.cancel()
        for t in self._tasks:
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
        for stream in self._streams.values():
            try:
                stream.stop()
                stream.close()
            except Exception:
                pass
        self._streams.clear()
        try:
            await self.engine.aclose()
        except Exception:
            pass

    # -- input -------------------------------------------------------------
    def say(self, text: str) -> None:
        text = (text or "").strip()
        if not text:
            return
        self._inflight += 1
        self._idle.clear()
        self.text_q.put_nowait((self._gen, text))

    @property
    def speaking(self) -> bool:
        return self._speaking or self._inflight > 0

    async def drain(self) -> None:
        """Wait until everything queued has finished playing."""
        await self._idle.wait()

    def interrupt(self) -> None:
        """Stop now: drop the queues, abort the stream, orphan in-flight work."""
        self._gen += 1
        for q in (self.text_q, self.audio_q):
            while True:
                try:
                    q.get_nowait()
                    q.task_done()
                except asyncio.QueueEmpty:
                    break
        self._inflight = 0
        self._idle.set()
        stream = self._active_stream
        if stream is not None:
            try:
                stream.abort()
            except Exception:
                pass
        self._finish_speaking()

    # -- workers -----------------------------------------------------------
    def _done_one(self) -> None:
        self._inflight = max(0, self._inflight - 1)
        if self._inflight == 0:
            self._idle.set()
            self._finish_speaking()

    async def _synth_worker(self) -> None:
        while True:
            gen, text = await self.text_q.get()
            try:
                if gen != self._gen:
                    continue  # from an interrupted turn
                try:
                    audio = await self.engine.synth(text)
                except Exception as exc:
                    if self._on_error:
                        self._on_error(f"synthesis failed: {exc}")
                    self._done_one()
                    continue
                if gen != self._gen:
                    self._done_one()
                    continue
                await self.audio_q.put((gen, audio))
            finally:
                self.text_q.task_done()

    async def _play_worker(self) -> None:
        while True:
            gen, audio = await self.audio_q.get()
            try:
                if gen != self._gen:
                    continue
                try:
                    await self._play(audio, gen)
                except Exception as exc:
                    if self._on_error:
                        self._on_error(f"playback failed: {exc}")
            finally:
                self.audio_q.task_done()
                self._done_one()

    # -- playback ----------------------------------------------------------
    def _stream_for(self, samplerate: int):
        stream = self._streams.get(samplerate)
        if stream is None:
            if sd is None:
                raise RuntimeError("sounddevice is not available for playback")
            stream = sd.OutputStream(
                samplerate=samplerate,
                channels=1,
                dtype="int16",
                blocksize=0,
                device=self.output_device,
            )
            stream.start()
            self._streams[samplerate] = stream
        elif not stream.active:
            # abort() during an interrupt leaves the stream stopped.
            stream.start()
        return stream

    def _begin_speaking(self) -> None:
        if self._speaking:
            return
        self._speaking = True
        signals.set_state(signals.SPEAKING)
        if self.ducker is not None:
            self.ducker.duck()
        if self.on_speaking_start:
            self.on_speaking_start()

    def _finish_speaking(self) -> None:
        if not self._speaking:
            return
        self._speaking = False
        if self.ducker is not None:
            self.ducker.release()
        signals.set_state(signals.IDLE)
        if self.on_speaking_end:
            self.on_speaking_end()

    async def _play(self, audio: Audio, gen: int) -> None:
        pcm = audio.pcm
        if pcm.size == 0:
            return
        stream = self._stream_for(audio.samplerate)
        self._active_stream = stream
        self._begin_speaking()
        try:
            for start in range(0, pcm.size, config.PLAY_BLOCK):
                if gen != self._gen:
                    return  # interrupted
                block = pcm[start:start + config.PLAY_BLOCK]
                try:
                    await asyncio.to_thread(stream.write, block)
                except Exception:
                    return  # aborted out from under us
                signals.waveform(block)
        finally:
            if self._active_stream is stream:
                self._active_stream = None

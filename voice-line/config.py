"""Central configuration for the voice line.

Every value here can be overridden with an environment variable, so you can
tune the rig without editing code. Secrets are never stored in this file --
the ElevenLabs key is read from the environment only.
"""

from __future__ import annotations

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def _s(name: str, default: str) -> str:
    val = os.environ.get(name)
    return default if val is None or val == "" else val


def _f(name: str, default: float) -> float:
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default


def _i(name: str, default: int) -> int:
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default


def _b(name: str, default: bool) -> bool:
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


# --------------------------------------------------------------------------
# Local services
# --------------------------------------------------------------------------

# whisper.cpp server. Different builds expose different routes, so we probe
# these in order at startup and use whichever one actually answers.
WHISPER_BASE = _s("VOICE_LINE_WHISPER_URL", "http://127.0.0.1:2022").rstrip("/")
WHISPER_ROUTES = ("/inference", "/v1/audio/transcriptions")
WHISPER_TIMEOUT_S = _f("VOICE_LINE_WHISPER_TIMEOUT", 30.0)

# kokoro-fastapi
KOKORO_BASE = _s("VOICE_LINE_KOKORO_URL", "http://127.0.0.1:8880").rstrip("/")
KOKORO_VOICE = _s("VOICE_LINE_KOKORO_VOICE", "bm_lewis")
KOKORO_SPEED = _f("VOICE_LINE_KOKORO_SPEED", 1.0)
KOKORO_SR = 24000  # kokoro returns raw int16 mono at 24 kHz
KOKORO_TIMEOUT_S = _f("VOICE_LINE_KOKORO_TIMEOUT", 30.0)

# --------------------------------------------------------------------------
# ElevenLabs (optional, Kokoro stays wired in as the automatic fallback)
# --------------------------------------------------------------------------

ELEVEN_API_KEY_ENV = "ELEVENLABS_API_KEY"
ELEVEN_BASE = "https://api.elevenlabs.io/v1"
# Pick any voice from https://elevenlabs.io/app/voice-library and paste its id
# here or into the ELEVENLABS_VOICE_ID env var. This is the one setting to change.
ELEVEN_VOICE_ID = _s("ELEVENLABS_VOICE_ID", "")
# Turbo, deliberately. The multilingual model is slower and duller on English.
ELEVEN_MODEL = _s("ELEVENLABS_MODEL", "eleven_turbo_v2_5")
# Raw PCM at 44.1k is a Pro-tier feature; mp3 costs us nothing because the
# decode hides inside the network wait.
ELEVEN_OUTPUT_FORMAT = _s("ELEVENLABS_FORMAT", "mp3_44100_128")
ELEVEN_SR = 44100
ELEVEN_STABILITY = _f("ELEVENLABS_STABILITY", 0.5)
ELEVEN_SIMILARITY = _f("ELEVENLABS_SIMILARITY", 0.75)
ELEVEN_STYLE = _f("ELEVENLABS_STYLE", 0.0)  # above 0 makes delivery slow and dull
ELEVEN_SPEAKER_BOOST = _b("ELEVENLABS_SPEAKER_BOOST", True)
ELEVEN_TIMEOUT_S = _f("ELEVENLABS_TIMEOUT", 30.0)

# Their website previews are mastered demo clips; raw API output never matches
# them, so we master locally: presence lift, a little low shelf, gentle
# compression, and a limiter to catch the peaks that adds.
FFMPEG_BIN = _s("VOICE_LINE_FFMPEG", "ffmpeg")
MASTER_CHAIN = _s(
    "VOICE_LINE_MASTER_CHAIN",
    "equalizer=f=3200:t=q:w=1.4:g=3.5,"
    "bass=g=2:f=140:t=h,"
    "acompressor=threshold=-18dB:ratio=3:attack=8:release=140:makeup=1.6,"
    "alimiter=level_in=1:level_out=0.95:limit=0.95",
)

# --------------------------------------------------------------------------
# Audio
# --------------------------------------------------------------------------

MIC_SR = 16000  # what whisper wants; no resampling anywhere in the path
MIC_BLOCK = 320  # 20 ms frames, the only sizes webrtcvad accepts are 10/20/30 ms
PLAY_BLOCK = 1024  # frames per write; small enough to interrupt fast
MAX_UTTERANCE_S = _f("VOICE_LINE_MAX_UTTERANCE", 45.0)

RELEASE_TAIL_S = _f("VOICE_LINE_RELEASE_TAIL", 0.18)  # so the last word survives
MIN_HOLD_S = _f("VOICE_LINE_MIN_HOLD", 0.25)  # taps shorter than this are ignored

# Open-mic endpointing
VAD_LEVEL = _i("VOICE_LINE_VAD_LEVEL", 2)  # 0 permissive .. 3 aggressive
MIN_SPEECH_MS = _i("VOICE_LINE_MIN_SPEECH_MS", 240)
END_SILENCE_MS = _i("VOICE_LINE_END_SILENCE_MS", 700)
PREROLL_MS = _i("VOICE_LINE_PREROLL_MS", 300)

# --------------------------------------------------------------------------
# Wake word (hands-free mode)
# --------------------------------------------------------------------------

WAKE_WORD = _s("VOICE_LINE_WAKE_WORD", "jarvis")
# Whisper mishears proper nouns; these are the spellings it actually produces.
WAKE_VARIANTS = ("jarvis", "jarvus", "jervis", "javis", "jarviss", "jarvi", "charvis")
# After a reply, keep listening without the wake word for this long.
FOLLOW_UP_WINDOW_S = _f("VOICE_LINE_FOLLOW_UP", 15.0)

# --------------------------------------------------------------------------
# Push to talk
# --------------------------------------------------------------------------

PTT_KEY = _s("VOICE_LINE_PTT_KEY", "ctrl_r")

# --------------------------------------------------------------------------
# Brain
# --------------------------------------------------------------------------


def _default_project_dir() -> str:
    """The folder whose CLAUDE.md defines the assistant's identity."""
    env = os.environ.get("VOICE_LINE_PROJECT_DIR")
    if env:
        return env
    # Walk up from here looking for a CLAUDE.md, so dropping voice-line inside
    # a project just works.
    for candidate in [ROOT, *ROOT.parents]:
        if (candidate / "CLAUDE.md").exists():
            return str(candidate)
    return str(Path.home())


def _default_jarvis_prompt_path() -> Path | None:
    """The versioned JARVIS system prompt, if this checkout has one.

    voice-line is designed to be dropped into any project (see
    _default_project_dir above), so a missing prompts/ directory is normal,
    not an error -- brain.py falls back to the plain SPOKEN_DISCIPLINE text
    when this is None.
    """
    env = os.environ.get("VOICE_LINE_JARVIS_PROMPT")
    if env:
        return Path(env)
    candidate = ROOT.parent / "prompts" / "jarvis-system-prompt.md"
    return candidate if candidate.exists() else None


PROJECT_DIR = _default_project_dir()
JARVIS_PROMPT_PATH = _default_jarvis_prompt_path()
MODEL = _s("VOICE_LINE_MODEL", "")  # empty means the CLI default
PERMISSION_MODE = _s("VOICE_LINE_PERMISSION_MODE", "acceptEdits")
TURN_TIMEOUT_S = _f("VOICE_LINE_TURN_TIMEOUT", 240.0)

GREETING = _s("VOICE_LINE_GREETING", "Voice line is up. What are we working on?")
SIGN_OFF = _s("VOICE_LINE_SIGN_OFF", "Talk later.")
QUIT_PHRASES = ("goodbye", "end voice mode", "hang up")

# Two-sentence breaths after the first sentence: a lone short sentence lands flat.
FIRST_CHUNK_SENTENCES = 1
BREATH_SENTENCES = _i("VOICE_LINE_BREATH", 2)

# Full fallback discipline, used when no versioned JARVIS prompt is found
# (see _default_jarvis_prompt_path above) -- e.g. voice-line dropped into a
# project that isn't this repo. Covers both spoken style and streaming
# mechanics on its own, since there's no prompts/jarvis-system-prompt.md to
# carry the style half.
SPOKEN_DISCIPLINE = """
<voice_mode>
You are being heard, not read. Everything you write is spoken aloud by a
text-to-speech voice through desk speakers, one sentence at a time as you
generate it.

Write for the ear:
- Short, conversational sentences. Talk the way you would to someone standing
  at your desk, not the way you would write a document.
- No markdown of any kind. No asterisks, no headings, no bullet points, no
  numbered lists, no tables, no code blocks.
- Never read code or long file paths aloud. Say what the code does, and name
  the file plainly, like "the mouth module".
- Give steps as prose: "First I'll check the config, then rerun it."
- Lead with the answer. Do not restate the question before answering it.
- Keep a normal turn to about six sentences unless asked for more detail.
- Spell things out for a voice: say "about 30 percent" not "~30%", say
  "port 8880" not ":8880".
- Punctuation is performance. The voice performs your commas, periods and
  question marks, so vary sentence length and let it breathe. Flat text is
  flat audio.
- After your first sentence, think in two-sentence breaths. A lone short
  sentence on its own sounds abrupt.
- Before any tool call that will take a moment, say one short natural line
  about what you are about to do, so the silence is explained. Then do it.
</voice_mode>
""".strip()

# Appended after the versioned JARVIS prompt instead of SPOKEN_DISCIPLINE.
# The JARVIS prompt already covers spoken style (THE SPOKEN CONSTRAINT); this
# covers only what's specific to voice-line's streaming mechanics, so the two
# documents don't say the same thing twice and drift out of sync.
STREAMING_ADDENDUM = """
<voice_mode>
You are being heard, not read. Text you write is spoken aloud through desk
speakers, one sentence at a time, streamed to the speakers as you generate
it -- once a sentence is out, it has already been spoken.

Before any tool call that will take a moment, say one short natural line
about what you are about to do, so the silence during the call is explained.
Then do it.

After your first sentence, think in two-sentence breaths. A lone short
sentence on its own sounds abrupt.
</voice_mode>
""".strip()

# --------------------------------------------------------------------------
# Signal bus
# --------------------------------------------------------------------------

WAVEFORM_HZ = _f("VOICE_LINE_WAVEFORM_HZ", 15.0)
WAVEFORM_POINTS = 64

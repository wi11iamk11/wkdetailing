# voice-line

Talk to Claude out loud at your desk, on Windows.

```
mic -> ears (sounddevice capture + local whisper on 2022)
    -> warm Claude Agent SDK session (streaming, one client per session)
    -> mouth (sentence-chunked TTS, Kokoro on 8880, cancellable playback)
    -> speakers
```

Half duplex on purpose: the mic is gated shut while the mouth speaks, so the
system can never hear itself. No barge-in on open speakers.

**Default mode is hands free.** The mic stays open and an utterance only
becomes a turn when it starts with the wake word, "jarvis". After a reply
there is a 15 second follow-up window where you can keep talking without
saying the name again.

---

## Install

If you just want it running, clone the repo and double-click
`start-jarvis.bat`. It checks for `uv`, offers to install the two speech
servers if they are missing, starts them, waits for them, and launches the
voice line -- skipping whichever of those is already done. `scripts\install-shortcut.ps1`
puts it on the Desktop.

The rest of this section is the same thing done by hand, which is worth
reading once so you know what the one-click path is actually doing.

Copy this folder to `%USERPROFILE%\voice-line` (that is where the rest of this
doc assumes it lives), then:

```powershell
cd $env:USERPROFILE\voice-line

# 1. the two local servers (normal, non-elevated PowerShell)
powershell -ExecutionPolicy Bypass -File scripts\setup-servers.ps1

# 2. start them (two windows, or install them as services -- see the bottom)
%USERPROFILE%\voice-line-servers\start-whisper.cmd
%USERPROFILE%\voice-line-servers\start-kokoro.cmd

# 3. prove they answer BEFORE trusting them
powershell -ExecutionPolicy Bypass -File scripts\check-servers.ps1

# 4. go
.\run-voice-line.bat
```

`run-voice-line.bat` creates the uv-managed Python 3.12 environment on first
run and launches from then on.

### A Desktop shortcut

To launch it without opening a terminal first:

```powershell
# no Administrator needed -- this only writes to your own Desktop
powershell -ExecutionPolicy Bypass -File scripts\install-shortcut.ps1

# bake in the flags you always use
powershell -ExecutionPolicy Bypass -File scripts\install-shortcut.ps1 -Arguments "--voice elevenlabs"

# and to undo
powershell -ExecutionPolicy Bypass -File scripts\install-shortcut.ps1 -Uninstall
```

The shortcut opens a console window on purpose: you type into the voice line as
well as talk to it, so a windowless launch would cost you half the interface.
The servers still need to be up, which is what makes the services option below
worth it if you use a Desktop shortcut.

One Windows setting matters: **Settings > Privacy & security > Microphone >
let desktop apps access your microphone** must be on. There is no other
permission gate; the global key listener works in a normal console process.

### What the check script is really checking

- **Which whisper route actually exists.** Different whisper.cpp builds expose
  different routes: some serve only `/inference`, not the OpenAI-style
  `/v1/audio/transcriptions` that client libraries assume. The app probes both
  at startup and binds to whichever answers, so either build works.
- **That Kokoro returns raw PCM** on `/v1/audio/speech` (int16, 24 kHz, mono).
- **That Kokoro's torch is really on CUDA.** This one is silent and expensive:
  kokoro-fastapi's own GPU install path can pull a CPU-only torch, because
  `uv pip install -e ".[gpu]"` runs in uv's pip-compatible legacy mode and
  ignores the project's PyTorch CUDA index routing (and `uv sync --extra gpu`
  can resolve wrong too). Everything still *works*, just 10 to 14 times
  slower, and nothing tells you. If `torch.cuda.is_available()` is False,
  install the exact pinned CUDA wheel straight from the PyTorch index:
  ```powershell
  cd $env:USERPROFILE\kokoro-fastapi
  uv pip install torch==2.6.0 --index-url https://download.pytorch.org/whl/cu124
  ```

---

## The voice

Kokoro is the default: local, free forever, and the lowest-latency path.
ElevenLabs is fully wired as an alternative, with Kokoro underneath as the
automatic fallback, so if the service is down or your credits run out the
voice degrades instead of going mute.

To switch:

```powershell
.\run-voice-line.bat --voice elevenlabs --voice-id <the id you picked>
```

### Setting up ElevenLabs, if you want it

1. Make an account at <https://elevenlabs.io>.
2. Click your avatar, bottom left, then **API Keys**, then **Create API Key**.
   Copy it once; they do not show it again.
3. Store it in the environment, never in the code:
   ```powershell
   setx ELEVENLABS_API_KEY "sk_your_key_here"
   ```
   Open a new terminal afterwards so the variable exists in it.
4. Pick any voice you like from the voice library at
   <https://elevenlabs.io/app/voice-library>. Open the voice, copy its **voice
   ID**. That id is the one setting that changes the voice:
   ```powershell
   setx ELEVENLABS_VOICE_ID "voice_id_here"
   ```
   or pass `--voice-id` on the command line.
5. Make ElevenLabs the default, so the Desktop shortcut and every other
   launch use it without a flag:
   ```powershell
   setx VOICE_LINE_VOICE "elevenlabs"
   ```
   `--voice kokoro` still overrides it for one run.

On a machine with no Nvidia GPU this is the difference between usable and
not: Kokoro synthesises on the CPU, competing with whisper for the same
cores, while ElevenLabs does the work remotely and leaves the CPU to the
transcription.

Their site previews are mastered demo clips, so raw API output never sounds
like them. This is handled: audio comes back as `mp3_44100_128` (raw PCM at
44.1k is a Pro-tier feature, and the mp3 decode hides inside the network wait)
and gets decoded and mastered locally with ffmpeg -- presence lift around
3.2 kHz, a little low shelf at 140 Hz, gentle compression, a limiter. Turbo
model, stability 0.5, similarity 0.75, style 0. Do not raise style and do not
use the multilingual model for English; both make the delivery slow and dull.
Pass `--no-master` to hear the unmastered version.

---

## Modes

| | hands free (default) | hold-to-talk (`--ptt`) |
|---|---|---|
| how a turn starts | say "Jarvis, ..." | hold Right Ctrl |
| mic between turns | open, but wake-gated | fully closed |
| false triggers | possible: a video or a podcast in the room can say the wake word | impossible |
| interrupt | tap Right Ctrl, or type | tap Right Ctrl, or type |

Hold-to-talk is the more robust design and is why it is built. If room audio
starts triggering turns, `--ptt` and the problem is gone. `--no-wake` goes the
other way: every utterance becomes a turn, which is only sane with headphones
in a quiet room.

Whatever the mode, the mic never hears the speakers: it is gated from the
moment a turn is committed until playback ends, and drained before it reopens.

---

## How it hangs together

- **`ears.py`** captures 16 kHz mono int16 and talks to whisper. Push-to-talk
  opens the mic on key down and closes it 0.18 s after key up so the last word
  survives; taps under 250 ms are ignored. Hands-free uses webrtcvad
  endpointing, discards anything with under 240 ms of real speech, and strips
  the non-speech markers whisper emits (`[SIGHS]`, `[BLANK_AUDIO]`).
- **`brain.py`** holds one warm `ClaudeSDKClient` for the session. `cwd` is
  the project folder and `setting_sources` includes `"project"`, which is what
  makes CLAUDE.md load -- so the voice session is the same assistant as your
  terminal sessions. It streams partial messages, chunks them into sentences,
  and **flushes the buffer when a content block stops**, which is what makes
  pre-tool filler play immediately instead of sitting silent through the whole
  tool run and then arriving glued to the answer.
- **`mouth.py`** is a two-stage pipeline with two queues, so synthesis of the
  next sentence overlaps playback of the current one. A single-queue loop that
  synthesizes then plays each sentence to completion has an audible dead-air
  gap at every sentence boundary. Interrupt bumps a generation counter, drains
  both queues and aborts the stream.
- **`ptt.py`** is the global key listener. Windows fires key-repeat
  `on_press` events continuously while a key is held, so a held-state flag
  filters them; without it every repeat reads as a fresh press and kills the
  reply that is trying to speak.
- **`console.py`** makes typing a first-class turn -- typed lines go into the
  same handler as speech, so replies are spoken, typing interrupts playback,
  and the quit phrases work typed. Windows consoles have no termios and no
  cbreak mode, so it reads characters with `msvcrt` on a thread and hands
  lines to the loop with `call_soon_threadsafe`.
- **`ducking.py`** drops Spotify to `max(30, current * 0.6)` while the
  assistant talks, and restores on a 1.2 s debounce so back-to-back sentences
  do not yo-yo the volume. It never launches Spotify.
- **`signals.py`** writes the visualizer bus.

### The crash this design avoids

Windows' default asyncio loop is the ProactorEventLoop, which the Claude Agent
SDK needs for subprocess handling, and it does **not** implement
`asyncio.add_reader()`. Any input path built on `add_reader` raises
`NotImplementedError` at startup. So nothing here reads input through the
loop: keystrokes and typed lines arrive on background threads and cross into
asyncio with `call_soon_threadsafe`. Do not "fix" this by installing a
selector event loop -- that trades this crash for a broken SDK.

---

## The signal bus

Written in this folder, for any visualizer to watch. Every write is wrapped;
the bus can never crash the voice line.

| file | contents |
|---|---|
| `.voice_state` | plain text: `idle`, `listening`, `thinking`, `speaking` |
| `.voice_waveform` | `{"ts": <unix float>, "samples": [64 floats]}`, at most 15/sec while audio plays |
| `.voice_loading_pid` | exists while a thinking sound is playing |

`.voice_alert` is deliberately **never written here** -- that one belongs to
any other process on the machine that wants the visualizer's attention.

Every waveform write also re-writes the state to `speaking`. That only runs
while audio is audibly playing, so any stray process that stomps the state
file gets corrected within about 70 ms.

---

## Running the servers as Windows services (optional)

Survives reboots, restarts on crash. Requires an **elevated** PowerShell
window; service installs always need Administrator.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install-services.ps1
# and to undo
powershell -ExecutionPolicy Bypass -File scripts\install-services.ps1 -Uninstall
```

Two things that bite here, both handled in the script:

- `LocalSystem` does not inherit your user PATH. The whisper service is
  therefore started without any ffmpeg-dependent conversion flag -- the client
  already sends 16 kHz mono WAV, so there is nothing to convert. If you do
  need ffmpeg visible to the service account, run with
  `-AddFfmpegToSystemPath`.
- Re-running an install against a service that already exists can silently
  no-op on its arguments, because some tools only apply the command line at
  creation. The script force-sets `Application`, `AppParameters` and
  `AppDirectory` on every run, not just the first.

**Only the servers become services.** The voice line itself stays a foreground
app you launch when you want it. Nobody wants a 24/7 open mic.

---

## Tests

```powershell
uv run python tests\test_logic.py      # chunking, wake word, route probe, bus, ducking math
uv run python tests\test_turn_loop.py  # the turn loop with faked audio devices
```

These cover everything that does not need real hardware. They do not replace
listening to it.

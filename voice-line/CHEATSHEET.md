# voice-line cheat sheet

## Launch

```
cd %USERPROFILE%\voice-line
run-voice-line.bat
```

That is the whole command. Everything below is optional.

| variation | command |
|---|---|
| hold-to-talk instead of hands free | `run-voice-line.bat --ptt` |
| no wake word, every utterance is a turn | `run-voice-line.bat --no-wake` |
| a different wake word | `run-voice-line.bat --wake computer` |
| ElevenLabs voice | `run-voice-line.bat --voice elevenlabs --voice-id <id>` |
| leave Spotify alone | `run-voice-line.bat --no-duck` |
| never stall on a permission prompt | `run-voice-line.bat --yolo` |
| point at another project's CLAUDE.md | `run-voice-line.bat --project C:\path\to\repo` |
| pick a mic or speaker | `run-voice-line.bat --list-devices` then `--input-device 3` |

## Controls

| you do | it does |
|---|---|
| say **"Jarvis, ..."** | starts a turn with everything after the name |
| say **"Jarvis"** alone | answers "yeah?" and listens for 15 s with no wake word needed |
| keep talking after a reply | works for 15 s, no wake word needed |
| **tap Right Ctrl** | interrupts whatever it is saying, immediately |
| **hold Right Ctrl** (with `--ptt`) | opens the mic; release to send |
| **type a line + Enter** | a real turn: the reply is spoken out loud |
| **type while it talks** | interrupts playback, then takes your line |
| **paste anything** | becomes one message, gutters and hard wraps scrubbed, echoed as a character count |
| type **`mute`** / **`unmute`** | closes / reopens the mic without quitting |
| say or type **"goodbye"**, **"end voice mode"**, **"hang up"** | ends the session |
| **Ctrl-C** | ends the session |

## What you should see and hear

- Greeting speaks at launch. The first turn's prompt-cache toll is paid behind
  it, so turn one is not slow.
- Warm turns: first audio about 1 to 2 seconds after you stop talking.
- A tool-using turn speaks filler within a couple of seconds ("on it, checking
  now"), then the answer.
- No dead air between sentences.
- Spotify ducks while it talks, comes back about a second after.

## When something is off

| symptom | look here |
|---|---|
| nothing transcribes | `powershell -File scripts\check-servers.ps1` -- it tells you which whisper route actually answers |
| no audio at all | same script, section 2: Kokoro must return PCM on `/v1/audio/speech` |
| replies are slow to speak | section 3: `torch.cuda.is_available()` is False and Kokoro is on CPU, 10-14x slower |
| mic never opens | Settings > Privacy & security > Microphone > let desktop apps access your microphone |
| the TV keeps starting turns | `--ptt`. The mic is then shut except while you hold the key |
| turn hangs with no reply | a tool is waiting on a permission prompt; relaunch with `--yolo` |
| `NotImplementedError` at startup | something was rewired onto `add_reader`; input must stay on threads (see README) |

## Files it writes (the visualizer bus)

`.voice_state` · `.voice_waveform` · `.voice_loading_pid` — in the voice-line
folder. It never writes `.voice_alert`; that one is for other processes to
raise.

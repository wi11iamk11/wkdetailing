# voice-visualizer — living circuit board

A fullscreen browser scene that reacts to the voice line. Dark PCB, etched
traces, signal packets racing toward a central chip that comes alive with your
voice.

```
~/voice-line/.voice_state       ──┐
~/voice-line/.voice_waveform    ──┤→  server.py (read-only)  →  /state  →  index.html
~/voice-line/.voice_alert       ──┘        127.0.0.1:8777         10 Hz poll
```

The page never opens a microphone. Everything it knows comes from the bus.

## Run it

```
run-visualizer.bat          the real bus, port 8777
run-visualizer.bat mock     the scripted loop, port 8778 — bus untouched
stop-visualizer.bat all     stop the servers
```

Double-click `run-visualizer.bat`. It starts the server in the background if
the port is not already answering (log in `%TEMP%`), then opens a Chrome kiosk
on a throwaway profile so no tabs or extensions ride along. **Alt+F4 closes the
kiosk and leaves the server warm.** No Chrome installed means your default
browser opens instead — press F11 for fullscreen.

Nothing to install: `server.py` is standard library only, and `index.html` is
one self-contained file with no frameworks, no CDN and no build step. It works
offline.

## Controls

| key | does |
|---|---|
| **Space** | start the ~30 second cinematic flythrough · press again to bail out |
| **F** | FPS meter |
| any key | skips the boot intro |

The state tag sits bottom-left so you always know what the scene thinks is
happening.

## The five states

| state | the board |
|---|---|
| **idle** | ~20% motion. A few slow packets on the outer traces, the die at a low ember with a six-second breath. Screensaver-calm. |
| **listening** | Packets reverse and flow **inward** from the board edges, brighter and four times denser than idle, with intake rings contracting onto the chip. Direction is the tell: this reads as receiving. |
| **thinking** | Traffic scatters both ways across the bus at full speed, the die runs a scanning compute grid, and progress arcs sweep the package. |
| **speaking** | The die **is** the voice: glow, scale and an on-die oscilloscope ride the live level, and every peak fires a burst of packets outward along the traces with a shockwave off the chip. |
| **alert** | The whole board turns red, a hazard pulse bleeds in from the edges. Overrides whatever is underneath. |

Every one of those rides a single continuously-eased energy value (≈0.5 s
attack, ≈1 s release) split into two axes: **glow** and **motion**. Speaking is
full glow at a calm cruise; thinking is full speed at moderate glow. Alive and
fast are different things. Nothing in the render path switches on a raw state
name — the state-specific treatments cross-fade on eased weights, which is what
keeps a transition from reading as a jump cut.

## The flythrough

Space deals a random hand from five shot types built around this board:

**trace run** (a long glide following one trace at high zoom, packets racing
past the lens) · **chip push** (a slow push into the die) · **diagonal sweep**
(corner to corner) · **component detail** (a drift across an SMD cluster) ·
**edge crawl** (a descent down the pin header)

Every run ends the same way: a pull-back that lands on the full wide board. The
dealer never cuts from a subject back to the same subject, and the finale never
starts on the shot you were just watching.

The grammar is what makes it read as cinema instead of a screensaver: constant
speed inside every shot so cuts land mid-motion, one apparent speed across the
whole deck (each shot's duration is derived from its travel distance and zoom),
and the only deceleration in the entire run is the finale easing in to land.
The perspective tilt is there from the first frame — easing it in after a cut
reads as the world warping — and it flattens in sync with the pull-back so the
landing and the un-tilt are one motion.

During a run the world is re-rendered through the camera transform every frame
and culled to what is in frame, rather than scaling a prebaked image, so
close-ups stay crisp enough to read the silkscreen. Canvas shadows do not scale
with a transform, so the die's rim light scales its blur by the zoom factor;
without that it visibly shrinks as the camera dives in.

## Harnesses

Never fake data on the real bus — two writers is chaos. Every test path avoids
it:

| URL | does |
|---|---|
| `?mockstate=speaking` | the page simulates that state locally, never calling `/state` |
| `?shot=thinking&t=4000` | deterministic: advances the sim 4000 ms and freezes, for screenshots |
| `?fly=1&t=9000&flyseed=7` | freezes a flythrough mid-run at 9000 ms |
| `?seed=12345` | a different board layout |
| `/state?samples=1` | adds the raw 64 samples, which drive the on-die oscilloscope |

Screenshot any of them headless:

```
chrome --headless --disable-gpu --window-size=1280,720 ^
  --screenshot=out.png "http://127.0.0.1:8778/?shot=speaking&t=4200"
```

## Gotchas worth knowing

- **Stale server.** After editing `server.py`, an old process keeps holding the
  port and answering with old code. `stop-visualizer.bat` finds the PID
  actually listening on the port with `netstat -ano` and kills exactly that —
  never a pattern kill, which would take down the voice line's Python too.
- **Headless screenshots come back black** if you render synchronously and
  Chrome then fires its late initial resize. `resize()` re-renders the frozen
  frame for exactly this reason.
- **`--headless=new` reports a viewport shorter than `--window-size`**, so
  screenshots get a black band at the bottom. Use `headless_shell`, or just
  ignore it — it is not a page bug.
- **The scene eases itself back to idle** if `/state` stops answering for two
  seconds, so a crashed or killed voice line leaves a calm board, not a frozen
  one.
- **Stomp tolerance:** a fresh waveform means the voice is speaking no matter
  what `.voice_state` says. Any stray process that overwrites the state file
  mid-sentence cannot interrupt the show.

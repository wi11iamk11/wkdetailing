# Vice Heights

An open-world crime sandbox for Roblox, in the shape of GTA V: drive, shoot,
rob, run from the cops, take jobs, spend the money.

The entire city is generated at runtime from a single seed, and the game ships
with **zero asset dependencies** — every building, car, gun and pedestrian is
built from primitives in code. Clone it, `rojo serve`, press play.

```
Config.Game.Seed = 20260809   -- change this number, get a different city
```

## What's in it

| System | Behaviour |
| --- | --- |
| **Open world** | 8×8 procedurally generated city blocks — roads, lane markings, crosswalks, sidewalks, towers with lit windows, parks, a beach and terrain ocean, streetlights that come on at dusk |
| **Driving** | Six vehicles with a raycast-suspension arcade physics model: real weight transfer, handbrake drifting, drag-limited top speed, collision damage, explosions, self-righting |
| **Gunplay** | Five weapons plus fists, server-authoritative hitscan with spread, distance falloff, headshots, magazines and reserves, reloads, recoil, scopes |
| **Wanted level** | Five stars driven by a heat meter. Crimes add heat, heat only decays once no officer has eyes on you, and repeat crimes are discounted so one shotgun blast doesn't max the meter |
| **Police** | Per-star response tiers. Officers pathfind, take cover distance, shoot with tier-based accuracy, and arrest you instead of killing you when you're cornered and bleeding. Cruisers spawn at 3★ and drive themselves using the same physics the player's car uses |
| **Pedestrians** | A crowd that spawns around wherever players actually are, wanders the pavement, and scatters when shots are fired |
| **Missions** | Five jobs (delivery, vehicle theft, street race, hits, a store heist) built from a data-driven stage machine — new jobs are new data, not new code |
| **Economy** | Cash, a gun shop, a car dealership, a personal garage, robbable 24/7 stores, hospital bills on death, bail on arrest |
| **Persistence** | DataStore-backed profiles with retry/backoff, autosave and `BindToClose`, degrading to session-only storage when DataStores are unavailable |
| **Interface** | HUD (cash, health, armour, stars, ammo, speedometer, objectives), a north-up radar drawn from the city grid, toast notifications, WASTED/BUSTED banners, shop menus |

## Running it

You need [Rojo](https://rojo.space) 7+ and Roblox Studio.

```bash
rojo serve            # then connect from the Rojo plugin in Studio
# or build a place file directly:
rojo build -o ViceHeights.rbxlx
```

Press **Play**. The city builds itself in the first second or so; watch the
output for `[ViceHeights] City built: N parts`.

### Controls

| Input | Action |
| --- | --- |
| `W A S D` | Move / drive |
| `Left Shift` | Handbrake (in a vehicle) |
| `Space` | Jump / exit vehicle |
| `E` | Use whatever you're standing next to |
| `Left Mouse` | Fire |
| `Right Mouse` | Aim (scope, with a sniper) |
| `R` | Reload |
| `Escape` | Close a menu |

Gamepad and touch are wired through `ContextActionService` and `VehicleSeat`,
so both work without a separate code path.

## Layout

```
src/
  shared/     replicated to both sides
    Config          every tuning number in the game
    CityGrid        the street layout as pure math
    CarSim          the arcade vehicle physics model
    Net             declarative remote registry + rate limiting
    *Catalog        vehicle, weapon and mission content
  server/
    init.server     boot order
    WorldBuilder    generates the city
    VehicleFactory  builds a car out of parts
    RigFactory      builds an R6 NPC out of parts
    Combat          the single place damage is applied
    *Service        data, players, vehicles, weapons, wanted, police,
                    pedestrians, missions, shops, day/night
  client/
    init.client     boot + state handshake
    ClientState     local mirror of server state
    HUD / Minimap / MenuUI / Notifier / Effects
    VehicleController / WeaponController / CameraController
```

## Design notes

**The client never reports hits.** It reports where it aimed. The server
re-rolls the spread, does its own raycasts, and validates the shot origin
against the shooter's head position, the fire rate against the weapon's stats,
and the ammunition against its own count. A modified client can point the barrel
somewhere silly; it cannot invent damage.

**Whoever drives, simulates.** The server hands network ownership of a car to
its driver, and that client runs `CarSim` locally so steering has no input
latency. The same `CarSim` runs on the server for police cruisers, which is why
a cop car handles exactly like a player's car instead of being a separate,
worse implementation.

**Parked cars sleep.** A city full of props would eat the physics budget, so
street cars stay anchored until someone opens the door, and re-anchor once
they've been abandoned and come to rest.

**The map can't go stale.** `CityGrid` is the single source of truth for the
street layout. The world builder places geometry from it, the police and
pedestrian spawners pick destinations from it, and the minimap draws its roads
from it — so the radar is always correct by construction.

## Tuning

Almost everything worth changing is in `src/shared/Config.luau`: city size,
building heights, wanted-level thresholds and decay, police tiers and accuracy,
crowd density, suspension stiffness, economy values, the day length. Vehicle
handling lives in `VehicleCatalog`, weapon stats in `WeaponCatalog`, and jobs in
`MissionCatalog`.

## Testing

The game can be run headlessly, outside Studio. `test/prelude.luau` is a small
Roblox API mock — instances, signals, the datatypes used here, a cooperative
task scheduler and a flat-ground raycaster — and `test/bundle.py` wraps every
module in a closure so Roblox-style `require(script.Parent.X)` resolves against
a mock instance tree. **The game source is used verbatim; nothing is stubbed
except the engine underneath it.**

```bash
LUAU=/path/to/luau test/run.sh
```

`test/smoke.luau` then plays the game: boots the server, generates the city,
joins a player, commits crimes, gets chased, spawns and crashes cars, fires
weapons, takes a job, buys a gun, dies, boots the client on top, and runs a
minute of simulated traffic and pursuit.

```
108 checks, 0 failures
```

It covers the things that are easy to get wrong and hard to notice: that
suspension springs push up and only when grounded, that the fire-rate limiter
and shot-origin validation actually reject bad packets, that a purchase from
across the map is refused, that armour absorbs before health, that explosions
spare people out of range, and that the cop and pedestrian populations stay
bounded over time.

What it does *not* cover is rendering, real physics integration, and animation
playback — those still need Studio.

## Tooling

```bash
stylua src/              # formatting, configured for Luau in stylua.toml
python3 test/bundle.py   # regenerate the test bundle only
```

Install stylua **with Luau support** — the default build only understands Lua
5.1 and will silently report success on files it cannot parse:

```bash
cargo install stylua --features luau
```

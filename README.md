# loop-slice

The playable vertical slice of the instanced loot-action core loop: a Hub deck
with a teleporter, a Field room with one enemy, the three-button melee combo,
first-touch loot contention, and the sqlite profile commit — server-authoritative
over WebTransport/QUIC (`feat/module-http3`, multi-session per
[godot#56](https://github.com/v-sekai-multiplayer-fabric/godot/pull/56)).

The reducers transcribe the proven Lean cores
([loot](https://github.com/v-sekai-multiplayer-fabric/loot),
[combat](https://github.com/v-sekai-multiplayer-fabric/combat),
[progression](https://github.com/v-sekai-multiplayer-fabric/progression)), whose
wire parities pin the behavior.

## Current state

Verified in this repo. The engine is not run here, so the smoke's runtime pass is
not asserted.

- Two cores are transcribed as named resolvers wired into the server: combat
  (`core/combat.gd`) and loot (`core/loot.gd`). Progression is an inline inventory
  append committed through the SQLite adapter (`adapters/sqlite_profiles.gd`)
  rather than a transcribed reducer, and presence runs through a Hilbert interest
  core (`core/hilbert.gd`) and a multiplayer sink rather than a named presence core.
- Persistence is SQLite. There is no CockroachDB path, and there is no budgeter core.
- `smoke.sh` asserts exactly one grant and, when `sqlite3` is available, exactly
  one committed profile row, verifying the persistence round trip.

## Play (flatscreen)

```sh
GODOT=godot.linuxbsd.editor.double.x86_64   # the merged double build
$GODOT --headless --script server.gd &      # the authority
$GODOT --path .                              # a windowed client
# WASD move, T vote teleport (4 votes start the run), SPACE attack on the beat,
# E grab the drop. Four clients run the full loop.
```

## The bot smoke

```sh
GODOT=... ./smoke.sh
# -> PLAYABLE LOOP SMOKE PASS: full slice ran end to end with exactly one grant
```

One server + four bots run hub -> vote -> fade -> field combat (timed combos
through the invulnerability window) -> loot contention (exactly one grant) ->
return + sqlite commit.

## XR mode

`XR=1` (or the Quest build) runs the same client through OpenXR: an XROrigin
with head camera and both controllers — left stick locomotion, right trigger
attack, A grab, left Y teleport vote. Verified headless against Monado: an
XR-session bot ran the full loop alongside three flatscreen bots.

## Quest 3

`export_presets.cfg` exports `build/loop-slice.apk` (arm64 double template,
debug-signed, OpenXR). The client reads the server host from `LOOP_HOST`, then
`res://server_host.txt` (baked at export), then loopback.

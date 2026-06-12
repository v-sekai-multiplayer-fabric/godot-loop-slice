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

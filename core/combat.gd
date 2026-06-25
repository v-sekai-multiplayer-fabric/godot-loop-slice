# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
class_name CombatCore

const MIN_GAP := 6
const MAX_GAP := 18
const INVULN := 30
const MAX_HP := 100
const MELEE_RANGE := 2.5

# Pure combat resolver.  Returns:
#   fx:           Array[String] — effect tokens for the attacker ("swing0", "hit10", …)
#   enemy:        Dictionary   — updated enemy state (hp, alive, spawn_tick, pos)
#   broadcasts:   Array[String]— messages to broadcast to all players
#   loot_spawned: bool         — true when enemy just died and loot box should open
static func resolve_swing(enemy: Dictionary, stage: int, dist: float, tick: int) -> Dictionary:
	var fx: Array[String] = ["swing%d" % stage]
	var broadcasts: Array = []
	var loot_spawned := false
	var e := enemy.duplicate(true)
	if not e["alive"]:
		return {"fx": fx, "enemy": e, "broadcasts": broadcasts, "loot_spawned": loot_spawned}
	if dist > MELEE_RANGE:
		fx.append("outofrange")
		return {"fx": fx, "enemy": e, "broadcasts": broadcasts, "loot_spawned": loot_spawned}
	if tick < e["spawn_tick"] + INVULN:
		fx.append("blocked")
		return {"fx": fx, "enemy": e, "broadcasts": broadcasts, "loot_spawned": loot_spawned}
	var dmg: int = ([10, 15, 25] as Array)[stage]
	e["hp"] = max(0, e["hp"] - dmg)
	fx.append("hit%d" % dmg)
	broadcasts.append("enemy:hp:%d" % e["hp"])
	if e["hp"] == 0:
		e["alive"] = false
		fx.append("death")
		loot_spawned = true
		broadcasts.append("loot:spawned")
	return {"fx": fx, "enemy": e, "broadcasts": broadcasts, "loot_spawned": loot_spawned}

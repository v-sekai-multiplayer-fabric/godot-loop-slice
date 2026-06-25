# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
class_name LootCore

# Proven loot roll: xorshift32 over cumulative weights 50/80/100 → items 101/202/303.
# Returns {item: int, next_seed: int}.
static func roll(seed: int) -> Dictionary:
	var s := seed & 0xFFFFFFFF
	s = (s ^ ((s << 13) & 0xFFFFFFFF)); s = (s ^ (s >> 17)); s = (s ^ ((s << 5) & 0xFFFFFFFF))
	var r := s % 100
	var item := 101 if r < 50 else (202 if r < 80 else 303)
	return {"item": item, "next_seed": s}

# First-touch resolution: earliest tick wins; ties broken by lowest pid.
# Returns winning pid, or -1 if claims is empty.
static func first_touch_winner(claims: Array) -> int:
	if claims.is_empty(): return -1
	var best = claims[0]
	for cl in claims:
		if cl[1] < best[1] or (cl[1] == best[1] and cl[0] < best[0]):
			best = cl
	return best[0]

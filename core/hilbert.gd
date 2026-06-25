# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
class_name HilbertCore

const SCENE_MIN := Vector3(-200.0, -50.0, -200.0)
const SCENE_MAX := Vector3(200.0, 50.0, 200.0)
const AOI_RADIUS := 60.0
const ZONE_CELL_SIZE := AOI_RADIUS
const ZONE_COLS := 8  # int(ceil(400.0 / ZONE_CELL_SIZE)) + 1

# Skilling 2004 forward Hilbert transform, order=10 → 30-bit code.
# Transcribed from axesToTranspose + interleave3 in HilbertRoundtrip.lean.
static func hilbert3d(nx: int, ny: int, nz: int) -> int:
	var x := nx & 1023; var y := ny & 1023; var z := nz & 1023
	for i in range(9):
		var q := 1 << (9 - i); var p := q - 1
		if z & q != 0: x ^= p
		else: var tz := (x ^ z) & p; x ^= tz; z ^= tz
		if y & q != 0: x ^= p
		else: var ty := (x ^ y) & p; x ^= ty; y ^= ty
	var y2 := y ^ x; var z2 := z ^ y2; var tf := 0
	for i in range(9):
		var q := 1 << (9 - i)
		if z2 & q != 0: tf ^= q - 1
	x ^= tf; y2 ^= tf; z2 ^= tf
	var h := 0
	for b in range(9, -1, -1):
		h = (h << 1) | ((z2 >> b) & 1)
		h = (h << 1) | ((y2 >> b) & 1)
		h = (h << 1) | ((x >> b) & 1)
	return h

# hilbertOfBox from HilbertBroadphase.lean: normalise to [0,1023]³ then hilbert3d.
static func hilbert_code(pos: Vector3) -> int:
	var nx := clampi(int((pos.x - SCENE_MIN.x) * 1024.0 / maxf(SCENE_MAX.x - SCENE_MIN.x, 1.0)), 0, 1023)
	var ny := clampi(int((pos.y - SCENE_MIN.y) * 1024.0 / maxf(SCENE_MAX.y - SCENE_MIN.y, 1.0)), 0, 1023)
	var nz := clampi(int((pos.z - SCENE_MIN.z) * 1024.0 / maxf(SCENE_MAX.z - SCENE_MIN.z, 1.0)), 0, 1023)
	return hilbert3d(nx, ny, nz)

# Zone key for authority/interest partitioning: pos → flat zone index (xi × ZONE_COLS + zi).
static func zone_key(pos: Vector3) -> int:
	var xi := clampi(int((pos.x - SCENE_MIN.x) / ZONE_CELL_SIZE), 0, ZONE_COLS - 1)
	var zi := clampi(int((pos.z - SCENE_MIN.z) / ZONE_CELL_SIZE), 0, ZONE_COLS - 1)
	return xi * ZONE_COLS + zi

# 3-pass counting sort on 30-bit Hilbert codes — O(n).
# Implements the radix-sort step from LowerBound.lean ("Radix sort: O(N)").
static func radix_sort(entries: Array) -> Array:
	var r := entries
	for shift in [0, 10, 20]:
		var count: Array = []; count.resize(1024); count.fill(0)
		for e in r: count[(e.code >> shift) & 1023] += 1
		var prefix := 0
		for i in range(1024): var c := count[i]; count[i] = prefix; prefix += c
		var out: Array = []; out.resize(r.size())
		for e in r: var b := (e.code >> shift) & 1023; out[count[b]] = e; count[b] += 1
		r = out
	return r

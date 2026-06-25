extends SceneTree
# The authoritative loop server: Hub -> fade -> Field (combat + loot) -> return.
# Runs the proven reducers (combat step, loot first-touch, progression commit)
# behind one WebTransportPeer listener; clients are humans or bots.
const DEFAULT_PORT = 54400
# Scene AABB for Hilbert code normalisation (hilbertOfBox in HilbertBroadphase.lean).
const SCENE_MIN := Vector3(-200.0, -50.0, -200.0)
const SCENE_MAX := Vector3( 200.0,  50.0,  200.0)
# AOI radius in metres — axis-aligned cube, aoiCells=1 from aoiBand_width_bound.
const AOI_RADIUS := 60.0
# Max entities per Hilbert prefix group (formGroups maxGroupSize in HilbertBroadphase.lean).
const HILBERT_GROUP_SIZE := 32
const TICK_HZ = 30.0
const PLAYERS_NEEDED = int(4)
# Authority capacity TARGET: one single-threaded server must support at least this
# many authoritative players (and more if the transport allows — no hard cap). This
# is NOT the QUIC connection limit: authority and interest are split, and interest
# fans out to many more peers than there are players, so the transport connection
# table is sized far above this (see WT_SERVER_MAX_CONNECTIONS in the http3 module).
const PLAYER_CAPACITY_TARGET = int(150)
# combat tuning (CombatCore values)
const MIN_GAP = 6; const MAX_GAP = 18; const INVULN = 30; const MAX_HP = 100
const MELEE_RANGE = 2.5

var peer: MultiplayerPeer
var phase := "hub"
var players := {}        # peer_id -> {name, pos: Vector3, ready, kit, items}
var tick := 0; var tick_accum := 0.0
var combo := {}          # peer_id -> {stage, last_attack}
var enemy := {"alive": false, "hp": 0, "spawn_tick": 0, "pos": Vector3(0, 0, -4)}
var loot_box := {"present": false, "claims": []}
var loot_seed := 12345
var db_path := OS.get_environment("LOOP_DB") if OS.get_environment("LOOP_DB") != "" else "/tmp/loop_profiles.db"
# Bind address/port come from the environment so packaging (the systemd unit and
# the Podman quadlet) can repoint the listener without re-exporting; default to
# all interfaces on DEFAULT_PORT. LOOP_HOST applies to ENet (WebTransport binds all).
var port := int(OS.get_environment("LOOP_PORT")) if OS.get_environment("LOOP_PORT").is_valid_int() else DEFAULT_PORT
var bind_host := OS.get_environment("LOOP_HOST") if OS.get_environment("LOOP_HOST") != "" else "*"

# OpenTelemetry engine module — required (fabric-godot-core custom build).
const SPAN_SERVER := 2   # SpanKind.SERVER
const STATUS_OK := 1     # StatusCode.OK
const METRIC_SUM := 1    # OTelMetric::METRIC_TYPE_SUM (counter)
const METRIC_GAUGE := 0  # OTelMetric::METRIC_TYPE_GAUGE
var _otel = null          # OpenTelemetry node (engine module, required)
var _span_round := ""    # current game.round root span
var _span_phase := ""    # current phase child span (hub/fade_out/loop.combat/fade_in)
var _round_number := 0

static func _fmt(t: int) -> String:
	var d = Time.get_datetime_dict_from_unix_time(t)
	return "%04d%02d%02d%02d%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]

# Transport is switchable: ENet for the local slice, WebTransport for the
# Quest-web path (TRANSPORT=wt). The text protocol is transport-agnostic, so only
# peer creation differs.
func _transport() -> String:
	return "wt" if OS.get_environment("TRANSPORT") == "wt" else "enet"

func _make_server_peer() -> MultiplayerPeer:
	if _transport() == "wt":
		var crypto = Crypto.new()
		var key = crypto.generate_ecdsa()
		var now = int(Time.get_unix_time_from_system())
		var cert = crypto.generate_self_signed_certificate_san(key, "CN=loop-zone",
			_fmt(now), _fmt(now + 86400), PackedStringArray(["DNS:localhost", "IP:127.0.0.1"]))
		var w := WebTransportPeer.new()
		return w if w.create_server(port, "/wt", cert, key) == OK else null
	var e := ENetMultiplayerPeer.new()
	if bind_host not in ["", "*", "0.0.0.0"]:
		e.set_bind_ip(bind_host)
	return e if e.create_server(port, PLAYER_CAPACITY_TARGET) == OK else null

func _init():
	peer = _make_server_peer()
	if not peer:
		printerr("listen failed"); quit(1); return
	print("LOOPSRV ready on %s:%d (transport=%s)" % [bind_host, port, _transport()])
	_otel_init()
	_span_round = _otel.start_span("game.round", SPAN_SERVER)
	_span_phase = _otel.start_span_with_parent("hub", _span_round)
	# Attach the runtime MCP so the headless server is testable like the clients.
	# The server is the SceneTree itself, so inspect its state in run_script via
	# `Engine.get_main_loop()` (e.g. Engine.get_main_loop().phase / .players).
	if OS.get_environment("MCP_PORT") != "":
		var mcp_script = load("res://addons/vsekai_godot_mcp/mcp_runtime.gd")
		if mcp_script:
			root.call_deferred("add_child", mcp_script.new())

func _otel_init() -> void:
	assert(ClassDB.class_exists("OpenTelemetry"), "OpenTelemetry engine module required — use fabric-godot-core build")
	_otel = ClassDB.instantiate("OpenTelemetry")
	# OpenTelemetry is a Node; in the tree it drives its async HTTP export queue.
	root.call_deferred("add_child", _otel)
	var endpoint := OS.get_environment("OTEL_EXPORTER_OTLP_ENDPOINT")
	if endpoint == "":
		endpoint = "http://127.0.0.1:4318"
	var svc := OS.get_environment("OTEL_SERVICE_NAME")
	if svc == "":
		svc = "loop-server"
	_otel.init_tracer_provider(svc, endpoint, {
		"service.name": svc,
		"service.version": "0.1",
		"loop.transport": _transport(),
	})
	var hdrs := _otel_headers()
	if not hdrs.is_empty():
		_otel.set_headers(hdrs)
	_otel.set_flush_interval(1000)
	print("OTEL ready -> %s" % endpoint)

# OTEL_EXPORTER_OTLP_HEADERS="k1=v1,k2=v2" -> Dictionary.
func _otel_headers() -> Dictionary:
	var h := {}
	for kv in OS.get_environment("OTEL_EXPORTER_OTLP_HEADERS").split(",", false):
		var p := kv.split("=", false, 1)
		if p.size() == 2:
			h[p[0].strip_edges()] = p[1].strip_edges()
	return h

# Control messages go reliable; high-frequency position ("p:") goes unreliable.
# This matters most on WebTransport, where each RELIABLE packet opens a fresh bidi
# stream — streaming positions reliably exhausts the QUIC concurrent-stream limit
# in seconds and silently wedges all sends. Datagrams (unreliable) have no such cap.
const CH_CONTROL := 0   # reliable, ordered: welcome/roster/votes/fade/phase/loot/grant
const CH_POSITION := 1  # unreliable: high-frequency "p:" position replication
func send_to(pid: int, msg: String, reliable := true, channel := CH_CONTROL) -> void:
	peer.set_target_peer(pid)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	peer.put_packet(msg.to_utf8_buffer())

func broadcast(msg: String, reliable := true, channel := CH_CONTROL) -> void:
	for pid in players: send_to(pid, msg, reliable, channel)

# Skilling 2004 forward Hilbert transform, order=10 → 30-bit code.
# Transcribed from axesToTranspose + interleave3 in HilbertRoundtrip.lean.
static func _hilbert3d(nx: int, ny: int, nz: int) -> int:
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

# hilbertOfBox from HilbertBroadphase.lean: normalise to [0,1023]³ then hilbert3D.
static func _hilbert_code(pos: Vector3) -> int:
	var nx := clampi(int((pos.x - SCENE_MIN.x) * 1024.0 / maxf(SCENE_MAX.x - SCENE_MIN.x, 1.0)), 0, 1023)
	var ny := clampi(int((pos.y - SCENE_MIN.y) * 1024.0 / maxf(SCENE_MAX.y - SCENE_MIN.y, 1.0)), 0, 1023)
	var nz := clampi(int((pos.z - SCENE_MIN.z) * 1024.0 / maxf(SCENE_MAX.z - SCENE_MIN.z, 1.0)), 0, 1023)
	return _hilbert3d(nx, ny, nz)

# 3-pass counting sort on 30-bit Hilbert codes — O(n), not O(n log n).
# Implements the radix-sort step from LowerBound.lean ("Radix sort: O(N)").
# HilbertBroadphase.lean uses merge sort for proof simplicity; this is production.
static func _radix_sort_hilbert(entries: Array) -> Array:
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

func roll_item() -> int:
	# the proven loot roll (xorshift32 over cumw 50/80/100 -> items 101/202/303)
	var s := loot_seed & 0xFFFFFFFF
	s = (s ^ ((s << 13) & 0xFFFFFFFF)); s = (s ^ (s >> 17)); s = (s ^ ((s << 5) & 0xFFFFFFFF))
	var r := s % 100
	return 101 if r < 50 else (202 if r < 80 else 303)

func handle(pid: int, parts: PackedStringArray) -> void:
	match parts[0]:
		"join":
			players[pid] = {"name": parts[1], "kind": (parts[2] if parts.size() > 2 else "flat"),
				"pos": Vector3(randf_range(-2, 2), 0, randf_range(2, 4)), "yaw": 0.0,
				"ready": false, "kit": false, "items": [], "rtt": 0, "last_heard": Time.get_ticks_msec()}
			combo[pid] = {"stage": 0, "last_attack": 0}
			send_to(pid, "welcome:%d" % pid)
			# the starting kit (the shop's free-kit pressure valve)
			players[pid]["kit"] = true
			send_to(pid, "kit:monomate")
			print("JOIN peer=%d name=%s roster=%d" % [pid, parts[1], players.size()])
			broadcast("roster:%d" % players.size())
			_otel.record_metric("loop.joins", 1.0, "", METRIC_SUM, {"name": parts[1]})
			_otel.log_message("INFO", "JOIN peer=%d name=%s roster=%d" % [pid, parts[1], players.size()], {})
		"tf":
			if players.has(pid) and parts.size() >= 5:
				players[pid]["pos"] = Vector3(float(parts[1]), float(parts[2]), float(parts[3]))
				players[pid]["yaw"] = float(parts[4])
		"teleport":
			if players.has(pid) and phase == "hub":
				players[pid]["ready"] = true
				var n := 0
				for p in players: if players[p]["ready"]: n += 1
				print("VOTE peer=%d votes=%d/%d" % [pid, n, PLAYERS_NEEDED])
				broadcast("votes:%d/%d" % [n, PLAYERS_NEEDED])
				if n >= PLAYERS_NEEDED:
					_otel.set_attributes(_span_phase, {"player_count": n})
					_otel.end_span(_span_phase)
					var roster := []
					for p in players: roster.append(players[p]["name"])
					_otel.set_attributes(_span_round, {"loop.players": players.size(), "loop.roster": ",".join(roster)})
					_otel.add_event(_span_round, "party.formed", {"votes": n})
					_span_phase = _otel.start_span_with_parent("fade_out", _span_round)
					phase = "fade_out"
					broadcast("fade:out")
		"attack":
			if phase != "field" or not players.has(pid): return
			_otel.record_metric("loop.attacks", 1.0, "", METRIC_SUM, {"peer": pid})
			var dist: float = players[pid]["pos"].distance_to(enemy["pos"])
			var c = combo[pid]
			var fx := []
			if c["stage"] == 0:
				c["stage"] = 1; c["last_attack"] = tick
				fx = resolve_swing(pid, 0, dist)
			else:
				var gap = tick - c["last_attack"]
				if gap >= MIN_GAP and gap <= MAX_GAP:
					var st = c["stage"]
					c["stage"] = 0 if st >= 2 else st + 1
					c["last_attack"] = tick
					fx = resolve_swing(pid, st, dist)
				else:
					c["stage"] = 0; fx = ["whiff"]
			send_to(pid, "fx:" + ":".join(fx))
		"grab":
			if phase == "field" and loot_box["present"]:
				loot_box["claims"].append([pid, tick])
		"pong":
			if players.has(pid) and parts.size() >= 2:
				players[pid]["rtt"] = Time.get_ticks_msec() - int(parts[1])
		"bye":
			_otel.record_metric("loop.leaves", 1.0, "", METRIC_SUM, {"peer": pid})
			players.erase(pid)

func resolve_swing(pid: int, stage: int, dist: float) -> Array:
	var fx := ["swing%d" % stage]
	if not enemy["alive"]: return fx
	if dist > MELEE_RANGE: fx.append("outofrange"); return fx
	if tick < enemy["spawn_tick"] + INVULN: fx.append("blocked"); return fx
	var dmg = [10, 15, 25][stage]
	enemy["hp"] = max(0, enemy["hp"] - dmg)
	fx.append("hit%d" % dmg)
	_otel.record_metric("loop.hits", 1.0, "", METRIC_SUM, {"stage": stage, "dmg": dmg, "peer": pid})
	broadcast("enemy:hp:%d" % enemy["hp"])
	if enemy["hp"] == 0:
		enemy["alive"] = false
		fx.append("death")
		loot_box["present"] = true
		loot_box["claims"] = []
		broadcast("loot:spawned")
	return fx

func commit_profiles() -> void:
	var db = SQLite.new()
	if not db.open(db_path): printerr("db open failed"); return
	db.create_query("CREATE TABLE IF NOT EXISTS profiles(pid INT, name TEXT, item INT)").execute()
	db.create_query("DELETE FROM profiles").execute()
	for pid in players:
		for it in players[pid]["items"]:
			db.create_query("INSERT INTO profiles VALUES (?, ?, ?)").execute([pid, players[pid]["name"], it])
	db.close()

func _process(delta: float) -> bool:
	if not peer: return false
	peer.poll()
	while peer.get_available_packet_count() > 0:
		# get_packet_peer() peeks the sender of the NEXT packet (the MultiplayerPeer
		# contract), so read it BEFORE get_packet() pops. (WebTransportPeer cached it
		# after the pop; ENet follows the contract, so order matters.)
		var from = peer.get_packet_peer()
		var pkt = peer.get_packet().get_string_from_utf8()
		if players.has(from): players[from]["last_heard"] = Time.get_ticks_msec()
		handle(from, pkt.split(":"))
	tick_accum += delta
	while tick_accum >= 1.0 / TICK_HZ:
		tick_accum -= 1.0 / TICK_HZ
		step_tick()
	return false

var fade_ticks := 0
func step_tick() -> void:
	tick += 1
	# combo windows expire
	for pid in combo:
		var c = combo[pid]
		if c["stage"] > 0 and tick > c["last_attack"] + MAX_GAP:
			c["stage"] = 0
			send_to(pid, "fx:comboDrop")
	match phase:
		"fade_out":
			fade_ticks += 1
			if fade_ticks >= 30:
				_otel.end_span(_span_phase)
				_otel.add_event(_span_round, "phase.field", {"enemy.hp": MAX_HP})
				_span_phase = _otel.start_span_with_parent("loop.combat", _span_round)
				_otel.set_attributes(_span_phase, {"enemy_hp": MAX_HP})
				phase = "field"; fade_ticks = 0
				enemy = {"alive": true, "hp": MAX_HP, "spawn_tick": tick, "pos": Vector3(0, 0, -4)}
				for pid in players: players[pid]["pos"] = Vector3(randf_range(-3, 3), 0, 2)
				broadcast("phase:field")
				broadcast("enemy:spawned:%d" % MAX_HP)
		"field":
			if loot_box["present"] and loot_box["claims"].size() > 0:
				# first-touch: earliest tick, ties to lowest pid (LootCore.resolve)
				var best = loot_box["claims"][0]
				for cl in loot_box["claims"]:
					if cl[1] < best[1] or (cl[1] == best[1] and cl[0] < best[0]): best = cl
				var item := roll_item()
				players[best[0]]["items"].append(item)
				loot_box["present"] = false
				for pid in players:
					send_to(pid, ("grant:%d" % item) if pid == best[0] else "reject:loot")
				print("LOOT granted item %d to peer %d" % [item, best[0]])
				_otel.set_attributes(_span_phase, {"enemy_ticks_alive": tick - enemy.get("spawn_tick", tick)})
				_otel.end_span(_span_phase)
				_otel.set_attributes(_span_round, {"loot.item": item, "loot.winner_peer": best[0]})
				_otel.add_event(_span_round, "loot.granted", {"loot.item": item, "loot.winner_peer": best[0],
					"winner_name": players[best[0]].get("name", "")})
				_span_phase = _otel.start_span_with_parent("fade_in", _span_round)
				phase = "fade_in"; broadcast("fade:out")
		"fade_in":
			fade_ticks += 1
			if fade_ticks >= 30:
				_otel.end_span(_span_phase)
				_otel.set_attributes(_span_round, {"round": _round_number})
				_otel.set_status(_span_round, STATUS_OK)
				_otel.end_span(_span_round)
				_otel.flush_all()
				_round_number += 1
				phase = "hub"; fade_ticks = 0
				commit_profiles()
				print("LOOP COMPLETE: party returned, profiles committed")
				# reset for a fresh round (continuous demo)
				for pid in players: players[pid]["ready"] = false
				for pid in combo: combo[pid] = {"stage": 0, "last_attack": 0}
				enemy = {"alive": false, "hp": 0, "spawn_tick": 0, "pos": Vector3(0, 0, -4)}
				loot_box = {"present": false, "claims": []}
				loot_seed += 7
				_span_round = _otel.start_span("game.round", SPAN_SERVER)
				_span_phase = _otel.start_span_with_parent("hub", _span_round)
				_otel.log_message("INFO", "LOOP COMPLETE: party returned, profiles committed", {})
				broadcast("phase:hub")
	# Replicate positions at 10 Hz via Hilbert broadphase — O(n+k).
	# Follows LowerBound.lean: radix sort O(n) + group scan O(n+k).
	# hilbert_prune_sound justifies skipping groups with disjoint AABBs.
	if tick % 3 == 0 and (phase == "field" or phase == "hub"):
		# Step 1: Hilbert codes — O(n)
		var entries: Array = []
		for pid in players:
			var pos: Vector3 = players[pid]["pos"]
			entries.append({"code": _hilbert_code(pos), "pid": pid, "pos": pos})
		# Step 2: radix sort on 30-bit codes — O(n)
		entries = _radix_sort_hilbert(entries)
		# Step 3: form groups by Hilbert prefix — O(n)
		var groups: Array = []
		var en := entries.size()
		var gi := 0
		while gi < en:
			var gj := mini(gi + HILBERT_GROUP_SIZE - 1, en - 1)
			var mnx: float = entries[gi].pos.x; var mnz: float = entries[gi].pos.z
			var mxx: float = mnx; var mxz: float = mnz
			for k in range(gi + 1, gj + 1):
				var p: Vector3 = entries[k].pos
				if p.x < mnx: mnx = p.x
				if p.z < mnz: mnz = p.z
				if p.x > mxx: mxx = p.x
				if p.z > mxz: mxz = p.z
			groups.append({"first": gi, "last": gj, "mnx": mnx, "mnz": mnz, "mxx": mxx, "mxz": mxz})
			gi = gj + 1
		# Step 4: per-sender group prune + AOI check — O(n+k)
		for entry in entries:
			var pid: int = entry.pid
			var pp: Vector3 = entry.pos
			var yw: float = players[pid].get("yaw", 0.0)
			var kd: String = players[pid].get("kind", "flat")
			var rt: int = players[pid].get("rtt", 0)
			var age: int = Time.get_ticks_msec() - players[pid].get("last_heard", 0)
			var msg := "p:%d:%.2f:%.2f:%.2f:%.3f:%s:%d:%d" % [pid, pp.x, pp.y, pp.z, yw, kd, rt, age]
			var smnx := pp.x - AOI_RADIUS; var smnz := pp.z - AOI_RADIUS
			var smxx := pp.x + AOI_RADIUS; var smxz := pp.z + AOI_RADIUS
			for g in groups:
				if smxx < g.mnx or g.mxx < smnx or smxz < g.mnz or g.mxz < smnz: continue
				for k in range(g.first, g.last + 1):
					var rp: Vector3 = entries[k].pos
					if absf(pp.x - rp.x) <= AOI_RADIUS and absf(pp.z - rp.z) <= AOI_RADIUS:
						send_to(entries[k].pid, msg, false, CH_POSITION)
	if tick % 15 == 0:
		for pid in players: send_to(pid, "ping:%d" % Time.get_ticks_msec())
	if tick % 30 == 0:
		_otel.record_metric("loop.players", float(players.size()), "", METRIC_GAUGE, {})
		if enemy["alive"]: _otel.record_metric("loop.enemy_hp", float(enemy["hp"]), "", METRIC_GAUGE, {})
	# no liveliness drop enforced here yet; the connection-FSM (liveliness window +
	# 5s rejoin) is the proven spec to wire in so dead sessions leave the roster

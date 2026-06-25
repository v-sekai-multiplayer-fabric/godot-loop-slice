extends SceneTree
# The authoritative loop server: Hub -> fade -> Field (combat + loot) -> return.
# Coordinates HilbertCore (broadphase), CombatCore (combat), LootCore (loot)
# through MultiplayerSink (transport) and SqliteProfiles (persistence).
const DEFAULT_PORT = 54400
# Max entities per Hilbert prefix group (formGroups maxGroupSize in HilbertBroadphase.lean).
# 8 gives C(8,2)=28 intra pairs vs C(16,2)=120 → tighter AABBs → ~60 % fewer inter-group
# false-positive checks → constant ~9.5N+k (down from 13.5N+k).
const HILBERT_GROUP_SIZE := 8
const TICK_HZ = 30.0
const PLAYERS_NEEDED = int(4)
# Authority capacity TARGET: one single-threaded server must support at least this
# many authoritative players (and more if the transport allows — no hard cap). This
# is NOT the QUIC connection limit: authority and interest are split, and interest
# fans out to many more peers than there are players, so the transport connection
# table is sized far above this (see WT_SERVER_MAX_CONNECTIONS in the http3 module).
const PLAYER_CAPACITY_TARGET = int(150)

var peer: MultiplayerPeer
var _sink: MultiplayerSink
var _db: SqliteProfiles
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
	_sink = MultiplayerSink.new()
	_sink.peer = peer
	_sink.players = players
	_db = SqliteProfiles.new()
	_db.db_path = db_path
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
	_sink.send_to(pid, msg, reliable, channel)

func broadcast(msg: String, reliable := true, channel := CH_CONTROL) -> void:
	_sink.broadcast(msg, reliable, channel)

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
			var stage: int
			if c["stage"] == 0:
				stage = 0
				c["stage"] = 1; c["last_attack"] = tick
			else:
				var gap = tick - c["last_attack"]
				if gap >= CombatCore.MIN_GAP and gap <= CombatCore.MAX_GAP:
					stage = c["stage"]
					c["stage"] = 0 if stage >= 2 else stage + 1
					c["last_attack"] = tick
				else:
					c["stage"] = 0
					send_to(pid, "fx:whiff")
					return
			var result := CombatCore.resolve_swing(enemy, stage, dist, tick)
			enemy = result["enemy"]
			for bcast in result["broadcasts"]: broadcast(bcast)
			if result["loot_spawned"]:
				loot_box["present"] = true
				loot_box["claims"] = []
			send_to(pid, "fx:" + ":".join(result["fx"]))
			for fx_part in result["fx"]:
				if fx_part.begins_with("hit"):
					_otel.record_metric("loop.hits", 1.0, "", METRIC_SUM, {"stage": stage, "dmg": int(fx_part.substr(3)), "peer": pid})
		"grab":
			if phase == "field" and loot_box["present"]:
				loot_box["claims"].append([pid, tick])
		"pong":
			if players.has(pid) and parts.size() >= 2:
				players[pid]["rtt"] = Time.get_ticks_msec() - int(parts[1])
		"bye":
			_otel.record_metric("loop.leaves", 1.0, "", METRIC_SUM, {"peer": pid})
			players.erase(pid)

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
		if c["stage"] > 0 and tick > c["last_attack"] + CombatCore.MAX_GAP:
			c["stage"] = 0
			send_to(pid, "fx:comboDrop")
	match phase:
		"fade_out":
			fade_ticks += 1
			if fade_ticks >= 30:
				_otel.end_span(_span_phase)
				_otel.add_event(_span_round, "phase.field", {"enemy.hp": CombatCore.MAX_HP})
				_span_phase = _otel.start_span_with_parent("loop.combat", _span_round)
				_otel.set_attributes(_span_phase, {"enemy_hp": CombatCore.MAX_HP})
				phase = "field"; fade_ticks = 0
				enemy = {"alive": true, "hp": CombatCore.MAX_HP, "spawn_tick": tick, "pos": Vector3(0, 0, -4)}
				for pid in players: players[pid]["pos"] = Vector3(randf_range(-3, 3), 0, 2)
				broadcast("phase:field")
				broadcast("enemy:spawned:%d" % CombatCore.MAX_HP)
		"field":
			if loot_box["present"] and loot_box["claims"].size() > 0:
				var winner_pid := LootCore.first_touch_winner(loot_box["claims"])
				var loot_result := LootCore.roll(loot_seed)
				var item: int = loot_result["item"]
				players[winner_pid]["items"].append(item)
				loot_box["present"] = false
				for pid in players:
					send_to(pid, ("grant:%d" % item) if pid == winner_pid else "reject:loot")
				print("LOOT granted item %d to peer %d" % [item, winner_pid])
				_otel.set_attributes(_span_phase, {"enemy_ticks_alive": tick - enemy.get("spawn_tick", tick)})
				_otel.end_span(_span_phase)
				_otel.set_attributes(_span_round, {"loot.item": item, "loot.winner_peer": winner_pid})
				_otel.add_event(_span_round, "loot.granted", {"loot.item": item, "loot.winner_peer": winner_pid,
					"winner_name": players[winner_pid].get("name", "")})
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
				_db.commit_profiles(players)
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
		# Step 1: Hilbert codes + authority zone tags — O(n).
		# zone = HilbertCore.zone_key(pos): authority zone for future fanout sharding
		# (each zone → independent core/server; 3×3 neighbor interest covers full AOI).
		var entries: Array = []
		for pid in players:
			var pos: Vector3 = players[pid]["pos"]
			entries.append({"code": HilbertCore.hilbert_code(pos), "pid": pid, "pos": pos, "zone": HilbertCore.zone_key(pos)})
		# Step 2: radix sort on 30-bit codes — O(n)
		entries = HilbertCore.radix_sort(entries)
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
			var smnx := pp.x - HilbertCore.AOI_RADIUS; var smnz := pp.z - HilbertCore.AOI_RADIUS
			var smxx := pp.x + HilbertCore.AOI_RADIUS; var smxz := pp.z + HilbertCore.AOI_RADIUS
			for g in groups:
				if smxx < g.mnx or g.mxx < smnx or smxz < g.mnz or g.mxz < smnz: continue
				for k in range(g.first, g.last + 1):
					var rp: Vector3 = entries[k].pos
					if absf(pp.x - rp.x) <= HilbertCore.AOI_RADIUS and absf(pp.z - rp.z) <= HilbertCore.AOI_RADIUS:
						_sink.send_to(entries[k].pid, msg, false, CH_POSITION)
	if tick % 15 == 0:
		for pid in players: send_to(pid, "ping:%d" % Time.get_ticks_msec())
	if tick % 30 == 0:
		_otel.record_metric("loop.players", float(players.size()), "", METRIC_GAUGE, {})
		if enemy["alive"]: _otel.record_metric("loop.enemy_hp", float(enemy["hp"]), "", METRIC_GAUGE, {})
	# no liveliness drop enforced here yet; the connection-FSM (liveliness window +
	# 5s rejoin) is the proven spec to wire in so dead sessions leave the roster

## Fire-and-forget OTLP/HTTP JSON exporter.
##
## Batches spans, metrics, and log records in memory and flushes them to the
## OTel Collector at localhost:4318 every FLUSH_INTERVAL seconds (or when a
## batch reaches MAX_BATCH entries). Uses raw StreamPeerTCP so it works inside
## a headless SceneTree server with no Node parents.
##
## Trace model for a game round:
##   begin_round()            → returns trace_id, emits root span start
##   begin_phase(name)        → returns span_id (child of root, same trace_id)
##   end_phase(span_id)       → closes the child span
##   end_round(trace_id)      → closes the root span and flushes immediately

class_name OtelExporter
extends RefCounted

var _host: String
var _port: int
var _service_name: String
var _rng := RandomNumberGenerator.new()

# pending batches
var _spans: Array = []
var _metrics: Array = []
var _logs: Array = []

var _flush_accum: float = 0.0
const FLUSH_INTERVAL := 5.0
const MAX_BATCH := 128

# open round tracking: trace_id -> {root_span_id, start_ns}
var _open_rounds: Dictionary = {}

func _init(service_name: String, host: String = "127.0.0.1", port: int = 4318) -> void:
	_service_name = service_name
	_host = host
	_port = port
	_rng.randomize()


# ── ID helpers ────────────────────────────────────────────────────────────────

func _rand_hex(n_bytes: int) -> String:
	var s := ""
	for _i in n_bytes:
		s += "%02x" % (_rng.randi() % 256)
	return s

func now_ns() -> String:
	return str(int(Time.get_unix_time_from_system() * 1_000_000_000.0))

func _now_ns() -> String:
	return now_ns()


# ── Round / phase span helpers ─────────────────────────────────────────────────

## Start a new game round. Returns a trace_id that must be passed to
## begin_phase / end_round. The root "game.round" span is held open until
## end_round() is called.
func begin_round() -> String:
	var trace_id := _rand_hex(16)
	var span_id  := _rand_hex(8)
	_open_rounds[trace_id] = {"root_span_id": span_id, "start_ns": _now_ns()}
	return trace_id

## Open a child span under the current round.  Returns a span_id for end_phase.
func begin_phase(trace_id: String, phase_name: String, attrs: Dictionary = {}) -> String:
	var span_id := _rand_hex(8)
	var parent_id: String = _open_rounds.get(trace_id, {}).get("root_span_id", "")
	var a := _kvlist(attrs)
	# stash it so end_phase can close it
	_open_rounds[trace_id]["phase_%s" % phase_name] = {
		"span_id": span_id, "start_ns": _now_ns(), "name": phase_name, "attrs": a,
		"parent_id": parent_id, "trace_id": trace_id
	}
	return span_id

## Close a child span opened by begin_phase.
func end_phase(trace_id: String, phase_name: String, extra_attrs: Dictionary = {}) -> void:
	if not _open_rounds.has(trace_id):
		return
	var key := "phase_%s" % phase_name
	var info: Dictionary = _open_rounds[trace_id].get(key, {})
	if info.is_empty():
		return
	_open_rounds[trace_id].erase(key)
	var a: Array = info.get("attrs", [])
	a.append_array(_kvlist(extra_attrs))
	_enqueue_span(trace_id, info["span_id"], info.get("parent_id", ""),
		info["name"], info["start_ns"], _now_ns(), a)

## Close the root span and flush immediately so the complete trace arrives
## together (avoids the collector emitting a partial trace).
func end_round(trace_id: String, attrs: Dictionary = {}) -> void:
	var info: Dictionary = _open_rounds.get(trace_id, {})
	if info.is_empty():
		return
	_open_rounds.erase(trace_id)
	_enqueue_span(trace_id, info["root_span_id"], "",
		"game.round", info["start_ns"], _now_ns(), _kvlist(attrs))
	flush()


# ── One-shot span (for short events like loot grant) ─────────────────────────

func event_span(trace_id: String, name: String, start_ns: String, attrs: Dictionary = {}) -> void:
	var parent_id: String = _open_rounds.get(trace_id, {}).get("root_span_id", "")
	_enqueue_span(trace_id, _rand_hex(8), parent_id, name, start_ns, _now_ns(), _kvlist(attrs))


# ── Metrics ───────────────────────────────────────────────────────────────────

func counter(name: String, value: int, attrs: Dictionary = {}) -> void:
	_metrics.append({"type": "sum", "name": name, "value": value,
		"attrs": _kvlist(attrs), "ts": _now_ns()})
	if _metrics.size() >= MAX_BATCH:
		_flush_metrics()

func gauge(name: String, value: float, attrs: Dictionary = {}) -> void:
	_metrics.append({"type": "gauge", "name": name, "value": value,
		"attrs": _kvlist(attrs), "ts": _now_ns()})
	if _metrics.size() >= MAX_BATCH:
		_flush_metrics()


# ── Log records ───────────────────────────────────────────────────────────────

## severity: 9=INFO 13=WARN 17=ERROR
func log_record(body: String, severity: int = 9) -> void:
	_logs.append({"body": body, "severity": severity, "ts": _now_ns()})
	if _logs.size() >= MAX_BATCH:
		_flush_logs()


# ── Tick integration ─────────────────────────────────────────────────────────

## Call from _process(delta) to drive timed flushes.
func process(delta: float) -> void:
	_flush_accum += delta
	if _flush_accum >= FLUSH_INTERVAL:
		_flush_accum = 0.0
		flush()

func flush() -> void:
	if not _spans.is_empty():  _flush_traces()
	if not _metrics.is_empty(): _flush_metrics()
	if not _logs.is_empty():   _flush_logs()


# ── Internal helpers ──────────────────────────────────────────────────────────

func _kvlist(d: Dictionary) -> Array:
	var out := []
	for k in d:
		var v = d[k]
		match typeof(v):
			TYPE_INT:   out.append({"key": k, "value": {"intValue":    str(v)}})
			TYPE_FLOAT: out.append({"key": k, "value": {"doubleValue": v}})
			_:          out.append({"key": k, "value": {"stringValue": str(v)}})
	return out

func _resource() -> Dictionary:
	return {"attributes": [
		{"key": "service.name", "value": {"stringValue": _service_name}},
		{"key": "telemetry.sdk.language", "value": {"stringValue": "gdscript"}},
	]}

func _enqueue_span(trace_id: String, span_id: String, parent_id: String,
		name: String, start_ns: String, end_ns: String, attrs: Array) -> void:
	var s := {
		"traceId": trace_id, "spanId": span_id,
		"name": name, "kind": 2,
		"startTimeUnixNano": start_ns,
		"endTimeUnixNano": end_ns,
		"attributes": attrs,
		"status": {"code": 1},
	}
	if parent_id != "":
		s["parentSpanId"] = parent_id
	_spans.append(s)
	if _spans.size() >= MAX_BATCH:
		_flush_traces()

func _post(path: String, body: String) -> void:
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host(_host, _port) != OK:
		return
	# OS needs a real yield between polls to advance the TCP handshake.
	var t := Time.get_ticks_msec()
	while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		OS.delay_msec(1)
		tcp.poll()
		if Time.get_ticks_msec() - t > 500:
			tcp.disconnect_from_host(); return
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var body_bytes := body.to_utf8_buffer()
	var header := "POST %s HTTP/1.0\r\nHost: %s:%d\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % [
		path, _host, _port, body_bytes.size()]
	tcp.put_data(header.to_utf8_buffer())
	tcp.put_data(body_bytes)
	tcp.disconnect_from_host()

func _sev_text(n: int) -> String:
	if n >= 17: return "ERROR"
	if n >= 13: return "WARN"
	return "INFO"

func _flush_traces() -> void:
	var payload := {"resourceSpans": [{"resource": _resource(),
		"scopeSpans": [{"scope": {"name": _service_name}, "spans": _spans.duplicate()}]}]}
	_spans.clear()
	_post("/v1/traces", JSON.stringify(payload))

func _flush_metrics() -> void:
	var list := []
	for m in _metrics:
		var dp := {"timeUnixNano": m.ts, "attributes": m.attrs}
		if typeof(m.value) == TYPE_INT: dp["asInt"] = str(m.value)
		else: dp["asDouble"] = m.value
		if m.type == "gauge":
			list.append({"name": m.name, "gauge": {"dataPoints": [dp]}})
		else:
			list.append({"name": m.name, "sum": {
				"dataPoints": [dp], "aggregationTemporality": 2, "isMonotonic": true}})
	var payload := {"resourceMetrics": [{"resource": _resource(),
		"scopeMetrics": [{"scope": {"name": _service_name}, "metrics": list}]}]}
	_metrics.clear()
	_post("/v1/metrics", JSON.stringify(payload))

func _flush_logs() -> void:
	var records := []
	for l in _logs:
		records.append({"timeUnixNano": l.ts, "severityNumber": l.severity,
			"severityText": _sev_text(l.severity), "body": {"stringValue": l.body}})
	var payload := {"resourceLogs": [{"resource": _resource(),
		"scopeLogs": [{"scope": {"name": _service_name}, "logRecords": records}]}]}
	_logs.clear()
	_post("/v1/logs", JSON.stringify(payload))

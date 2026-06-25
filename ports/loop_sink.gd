# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
class_name LoopSink

## Output port for the loop core.
## Adapters implement this to bind domain effects to concrete I/O.

func send_to(_pid: int, _msg: String, _reliable := true, _channel := 0) -> void:
	push_error("LoopSink.send_to not implemented")

func broadcast(_msg: String, _reliable := true, _channel := 0) -> void:
	push_error("LoopSink.broadcast not implemented")

func commit_profiles(_players: Dictionary) -> void:
	push_error("LoopSink.commit_profiles not implemented")

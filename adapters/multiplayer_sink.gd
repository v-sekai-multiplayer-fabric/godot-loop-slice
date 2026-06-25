# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
class_name MultiplayerSink
extends LoopSink

## Transport adapter: binds LoopSink to ENet or WebTransport via MultiplayerPeer.

var peer: MultiplayerPeer
var players: Dictionary  # shared reference to server's active players dict

const CH_CONTROL := 0
const CH_POSITION := 1

func send_to(pid: int, msg: String, reliable := true, channel := CH_CONTROL) -> void:
	peer.set_target_peer(pid)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	peer.put_packet(msg.to_utf8_buffer())

func broadcast(msg: String, reliable := true, channel := CH_CONTROL) -> void:
	for pid in players: send_to(pid, msg, reliable, channel)

func commit_profiles(_p: Dictionary) -> void:
	pass  # persistence delegated to SqliteProfiles

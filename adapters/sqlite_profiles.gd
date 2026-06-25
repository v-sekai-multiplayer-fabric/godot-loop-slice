# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
class_name SqliteProfiles
extends LoopSink

## Persistence adapter: writes loop player profiles to SQLite.

var db_path: String

func commit_profiles(players: Dictionary) -> void:
	var db = SQLite.new()
	if not db.open(db_path): printerr("db open failed"); return
	db.create_query("CREATE TABLE IF NOT EXISTS profiles(pid INT, name TEXT, item INT)").execute()
	db.create_query("DELETE FROM profiles").execute()
	for pid in players:
		for it in players[pid]["items"]:
			db.create_query("INSERT INTO profiles VALUES (?, ?, ?)").execute([pid, players[pid]["name"], it])
	db.close()

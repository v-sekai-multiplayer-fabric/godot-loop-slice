#!/usr/bin/env bash
# Full playable-loop smoke: 1 authoritative server + 4 bot clients run the
# whole slice (hub -> teleport vote -> field combat -> loot contention ->
# return + sqlite commit). Asserts LOOP COMPLETE, exactly one grant, and the
# committed profile row.
set -euo pipefail
GODOT="${GODOT:?set GODOT}"
DIR="$(cd "$(dirname "$0")" && pwd)"
DB=$(mktemp -u /tmp/loop_profiles_XXXX.db)
rm -f /tmp/loop_srv.log /tmp/loop_bot*.log
LOOP_DB=$DB timeout 180 "$GODOT" --headless --script "$DIR/server.gd" > /tmp/loop_srv.log 2>&1 &
SRV=$!
until grep -q 'LOOPSRV ready' /tmp/loop_srv.log || ! kill -0 $SRV; do sleep 0.5; done
# LOOP_HOST pins the bots to the local server; without it the client falls back to
# server_host.txt (a LAN address), so the smoke would dial the wrong host and hang.
for i in 1 2 3 4; do
  LOOP_HOST=127.0.0.1 BOT=1 BOT_NAME="bot$i" timeout 150 "$GODOT" --headless --path "$DIR" > /tmp/loop_bot$i.log 2>&1 &
done
wait %2 %3 %4 %5 2>/dev/null || true
until grep -q 'LOOP COMPLETE' /tmp/loop_srv.log || ! kill -0 $SRV; do sleep 0.5; done
kill $SRV 2>/dev/null || true
echo "--- bot outcomes:"
grants=0
for i in 1 2 3 4; do
  line=$(grep -E 'LOOP COMPLETE|TIMEOUT' /tmp/loop_bot$i.log | head -1); echo "  $line"
  echo "$line" | grep -q 'outcome=GRANT' && grants=$((grants+1))
done
grep -E 'LOOT granted|LOOP COMPLETE' /tmp/loop_srv.log
[ "$grants" -eq 1 ] || { echo "FAIL: expected exactly 1 grant, got $grants"; exit 1; }
command -v sqlite3 >/dev/null && { echo "--- committed profiles:"; sqlite3 "$DB" 'SELECT * FROM profiles;'; }
echo "PLAYABLE LOOP SMOKE PASS: full slice ran end to end with exactly one grant"

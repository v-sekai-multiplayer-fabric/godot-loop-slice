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
# MCP_PORT=off disables the per-instance godot_mcp listener: server + 4 bots are
# co-located here, so leaving it on the default port makes 4 of 5 fail to bind.
MCP_PORT=off LOOP_DB=$DB timeout 180 "$GODOT" --headless --script "$DIR/server.gd" > /tmp/loop_srv.log 2>&1 &
SRV=$!
until grep -q 'LOOPSRV ready' /tmp/loop_srv.log || ! kill -0 $SRV; do sleep 0.5; done
# LOOP_HOST pins the bots to the local server; without it the client falls back to
# server_host.txt (a LAN address), so the smoke would dial the wrong host and hang.
for i in 1 2 3 4; do
  MCP_PORT=off LOOP_HOST=127.0.0.1 BOT=1 BOT_NAME="bot$i" timeout 150 "$GODOT" --headless --path "$DIR" > /tmp/loop_bot$i.log 2>&1 &
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
# Loop closure (step 6): the granted item must reach the winning client (inventory sync).
granted_item=$(grep -oE 'LOOT granted item [0-9]+' /tmp/loop_srv.log | head -1 | grep -oE '[0-9]+$')
[ -n "$granted_item" ] || { echo "FAIL: no 'LOOT granted item' in server log"; exit 1; }
win_inv=$(grep -h 'outcome=GRANT' /tmp/loop_bot*.log | head -1 | sed -n 's/.*inventory=\([0-9,]*\).*/\1/p')
echo "--- winner client inventory: '${win_inv}' (granted item ${granted_item})"
echo ",${win_inv}," | grep -q ",${granted_item}," || { echo "FAIL: winner client inventory ('${win_inv}') missing granted item ${granted_item}"; exit 1; }
nonempty=$(grep -h 'LOOP COMPLETE' /tmp/loop_bot*.log | grep -cE 'inventory=[0-9]' || true)
[ "$nonempty" -eq 1 ] || { echo "FAIL: expected exactly 1 bot with a non-empty inventory, got $nonempty"; exit 1; }
# A correct grant must not coexist with GDScript errors on the server: that is what
# hid the hilbert.gd compile failure (the loot path does not use Hilbert, so the grant
# still landed while interest management was broken every tick).
if grep -qE 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script' /tmp/loop_srv.log; then
  echo "FAIL: GDScript errors in the server log:"
  grep -hE 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script' /tmp/loop_srv.log | sort -u | head
  exit 1
fi
if command -v sqlite3 >/dev/null; then
  echo "--- committed profiles:"
  sqlite3 "$DB" 'SELECT * FROM profiles;'
  rows=$(sqlite3 "$DB" 'SELECT count(*) FROM profiles;')
  [ "$rows" -eq 1 ] || { echo "FAIL: expected exactly 1 committed profile row, got $rows"; exit 1; }
  db_item=$(sqlite3 "$DB" 'SELECT item FROM profiles LIMIT 1;')
  [ "$db_item" = "$granted_item" ] || { echo "FAIL: committed item ($db_item) != granted item ($granted_item)"; exit 1; }
else
  echo "WARN: sqlite3 not found; persistence round trip not asserted"
fi
echo "PLAYABLE LOOP SMOKE PASS: full slice ran end to end with exactly one grant; the granted item reached the winning client and the committed row"

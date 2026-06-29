#!/usr/bin/env bash
# Containerized-server smoke: run the loop-slice server image as a Podman container
# and drive 4 bot clients against it, asserting exactly one grant. This verifies the
# quadlet deploy model (server.gd in a container + real network clients), not just the
# in-process smoke.
#
#   GODOT=<editor binary for the bot clients> IMAGE=<server image tag> tools/smoke_container.sh
#
# IMAGE defaults to loop-slice-server:test (build it first with `podman build -t that .`).
set -euo pipefail
GODOT="${GODOT:?set GODOT to the editor binary used for the bot clients}"
IMAGE="${IMAGE:-loop-slice-server:test}"
PORT="${LOOP_PORT:-54400}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

podman rm -f loop-smoke >/dev/null 2>&1 || true
trap 'podman rm -f loop-smoke >/dev/null 2>&1 || true' EXIT

# --network=host so the published UDP listener is reachable at 127.0.0.1 without
# rootless port-forward quirks; the clients dial 127.0.0.1:$PORT over ENet.
podman run -d --name loop-smoke --network=host -e "LOOP_PORT=$PORT" "$IMAGE" >/dev/null

for _ in $(seq 1 240); do
  podman logs loop-smoke 2>&1 | grep -q 'LOOPSRV ready' && break
  sleep 0.5
done
podman logs loop-smoke 2>&1 | grep -q 'LOOPSRV ready' || {
  echo "FAIL: containerized server never readied"; podman logs loop-smoke; exit 1; }
podman logs loop-smoke 2>&1 | grep 'LOOPSRV ready' | head -1

for i in 1 2 3 4; do
  LOOP_HOST=127.0.0.1 LOOP_PORT="$PORT" BOT=1 BOT_NAME="cbot$i" \
    timeout 150 "$GODOT" --headless --path "$DIR" > "/tmp/cbot$i.log" 2>&1 &
done
wait

podman logs loop-smoke 2>&1 | grep -E 'LOOT granted|LOOP COMPLETE' || true
grants=0
for i in 1 2 3 4; do
  line=$(grep -E 'LOOP COMPLETE|TIMEOUT' "/tmp/cbot$i.log" | head -1); echo "  cbot$i: $line"
  echo "$line" | grep -q 'outcome=GRANT' && grants=$((grants+1))
done
[ "$grants" -eq 1 ] || { echo "FAIL: expected exactly 1 grant against the container, got $grants"; exit 1; }
# A green grant must not coexist with GDScript errors in the containerized server.
if podman logs loop-smoke 2>&1 | grep -qE 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script'; then
  echo "FAIL: GDScript errors in the containerized server log:"
  podman logs loop-smoke 2>&1 | grep -hE 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script' | sort -u | head
  exit 1
fi
echo "CONTAINERIZED SERVER SMOKE PASS: full loop ran against the container with exactly one grant"

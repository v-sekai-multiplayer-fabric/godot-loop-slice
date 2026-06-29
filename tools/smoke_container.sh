#!/usr/bin/env bash
# Containerized-server boot check: run the loop-slice server image as a Podman container
# and verify it readies and boots cleanly (no GDScript errors). This gates the deploy
# image -- that it builds, and the server actually runs in a container with the engine
# modules it requires. The full playable loop (clients + loot contention) is covered by
# the in-process smoke (smoke.sh / the Smoke workflow), which runs deterministically;
# racing four bot containers here only added flakiness without new coverage.
#
#   IMAGE=<server image tag> tools/smoke_container.sh
set -euo pipefail
IMAGE="${IMAGE:-loop-slice-server:test}"
PORT="${LOOP_PORT:-54400}"

trap 'podman rm -f loop-smoke >/dev/null 2>&1 || true' EXIT
podman rm -f loop-smoke >/dev/null 2>&1 || true

# server: ENet/UDP on $PORT; --network=host so it is reachable at 127.0.0.1
podman run -d --name loop-smoke --network=host -e "LOOP_PORT=$PORT" "$IMAGE" >/dev/null

# wall-clock wait (up to 120s) for the server to log readiness; fail fast if it dies
echo "waiting up to 120s for the container server to ready..."
SECONDS=0
while ! podman logs loop-smoke 2>&1 | grep -q 'LOOPSRV ready'; do
  state=$(podman inspect -f '{{.State.Running}}' loop-smoke 2>/dev/null || echo missing)
  [ "$state" = "true" ] || { echo "FAIL: server container not running (state=$state) after ${SECONDS}s:"; podman logs loop-smoke 2>&1 | tail -40; exit 1; }
  [ "$SECONDS" -lt 120 ] || { echo "FAIL: server not ready after ${SECONDS}s:"; podman logs loop-smoke 2>&1 | tail -40; exit 1; }
  sleep 1
done
echo "containerized server ready after ${SECONDS}s"

# let it run a few ticks, then require a clean boot: no GDScript errors in the server log
sleep 3
if podman logs loop-smoke 2>&1 | grep -qE 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script'; then
  echo "FAIL: GDScript errors in the containerized server log:"
  podman logs loop-smoke 2>&1 | grep -hE 'SCRIPT ERROR|Parse Error|Compile Error|Failed to load script' | sort -u | head
  exit 1
fi
if [ "$(podman inspect -f '{{.State.Running}}' loop-smoke 2>/dev/null)" != "true" ]; then
  echo "FAIL: server exited shortly after readying:"; podman logs loop-smoke 2>&1 | tail -40; exit 1
fi
echo "CONTAINERIZED SERVER BOOT PASS: the image builds and the server readies cleanly in a container"

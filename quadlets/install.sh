#!/usr/bin/env bash
# Install the loop-slice-server Podman systemd quadlet on a Fedora host. Run as root.
# Mirrors the zone-server-quadlet install pattern.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

install -m 0644 "$here/loop-slice-server.container" /etc/containers/systemd/
install -d -m 0755 /etc/loop-slice /var/lib/loop-slice

if [ ! -f /etc/loop-slice/env ]; then
  cat > /etc/loop-slice/env <<'EOF'
LOOP_PORT=54400
LOOP_DB=/var/lib/loop-slice/profiles.db
TRANSPORT=enet
EOF
  echo "wrote default /etc/loop-slice/env"
fi

# PULL=1 (default) pre-pulls the image; needs GHCR auth if the package is private.
if [ "${PULL:-1}" = "1" ]; then
  podman pull ghcr.io/v-sekai-multiplayer-fabric/loop-slice-server:latest || \
    echo "WARN: pull failed (private package needs 'podman login ghcr.io'); systemd will pull on start"
fi

systemctl daemon-reload
echo "installed. start with: systemctl start loop-slice-server"
echo "logs:                  journalctl -u loop-slice-server -f"

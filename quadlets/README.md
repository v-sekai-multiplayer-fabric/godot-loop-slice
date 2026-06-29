# loop-slice-server quadlet

Deploys the loot-action loop-slice authoritative game server as a Podman systemd
quadlet, so an external reviewer can connect a client and run the full loop against
a live server (the third condition of the game-loop completion gate).

It follows the `zone-server-quadlet` pattern: a `.container` unit, an
`EnvironmentFile`, and an `install.sh` that drops the unit into
`/etc/containers/systemd` and reloads systemd.

## Image

The image is built from the repo `Containerfile`, which bakes this project on
`ghcr.io/v-sekai-multiplayer-fabric/godot-editor-double` and runs
`godot --headless --script server.gd`. The editor build is used (not the
export-template runtime) because the server runs as a script, and that build
carries the OpenTelemetry, SQLite, and WebTransport modules `server.gd` requires.
CI (`.github/workflows/release-server-image.yml`) builds and pushes
`ghcr.io/v-sekai-multiplayer-fabric/loop-slice-server` on pushes to `main`.

## Deploy

```sh
# on a Fedora host with podman + the quadlet generator (root):
sudo PULL=1 ./install.sh
sudo systemctl start loop-slice-server
journalctl -u loop-slice-server -f      # expect: "LOOPSRV ready on *:54400 (transport=enet)"
```

Override defaults in `/etc/loop-slice/env` (`LOOP_PORT`, `LOOP_DB`, `TRANSPORT`).

## Connect a client

Point a client at the host and port (ENet/UDP by default):

```sh
LOOP_HOST=<server-host-or-ip> LOOP_PORT=54400 <client>
```

`LOOP_HOST` overrides the baked `res://server_host.txt`. The transport must match
on both ends; the default here is ENet (no TLS). The WebTransport path
(`TRANSPORT=wt`) is not enabled by default because the server's self-signed cert
only covers `localhost` — widen the SAN or pin the cert hash before using it for a
remote client.

## Notes / not yet verified

The container image build runs in CI (it needs GHCR access to the private
`godot-editor-double` base, which a local anonymous pull cannot reach). The wrapped
invocation is verified locally: `godot --headless --script server.gd` on the editor
double build stands up and binds UDP `*:54400` over ENet, and the bot smoke runs the
full loop on that build. The `godot` binary path (`/usr/local/bin/godot`) follows the
godot-images `Containerfile`; confirm it against the editor image on the first CI build.

# Headless loot-action loop-slice game server, baked on the fabric "double" EDITOR
# build. server.gd is launched as a script (`--headless --script server.gd`), which
# is an editor invocation, so it needs the editor image, not the export-template
# runtime. That editor build carries the OpenTelemetry, SQLite, and WebTransport
# modules server.gd requires (verified with a ClassDB introspection against the
# godot.linuxbsd.editor.double build).
FROM ghcr.io/v-sekai-multiplayer-fabric/godot-editor-double:latest

WORKDIR /app
COPY . /app

# Build the import cache so a cold container starts fast. The bundled MCP plugin
# segfaults at editor exit (it probes adb for a Quest) after the import work is
# done, so the non-zero exit is tolerated and gated on the cache existing.
RUN godot --headless --import . || true; test -d .godot

# ENet (UDP, no TLS) by default. The WebTransport path generates a self-signed
# cert whose SAN only covers localhost, so it is not the default for a remote
# server; set TRANSPORT=wt only once the cert covers the public name.
ENV LOOP_PORT=54400 \
    LOOP_DB=/var/lib/loop-slice/profiles.db \
    TRANSPORT=enet

EXPOSE 54400/udp
CMD ["godot", "--headless", "--xr-mode", "off", "--script", "server.gd"]

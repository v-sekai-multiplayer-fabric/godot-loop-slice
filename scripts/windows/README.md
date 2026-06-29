# Loot-action demo — Windows 11, native (no Docker, no WSL)

This is the full playable slice running as native Windows processes: an authoritative
server, your client, and three bots that complete the four-player party, plus an optional
native observability stack (VictoriaMetrics + OpenTelemetry). Persistence is in-process
SQLite. No containers, no WSL.

## Run it

1. Download `v-sekai-loop-slice-demo-windows.zip` from the GitHub release and unzip it.
2. In PowerShell, from the unzipped folder:

   ```powershell
   powershell -ExecutionPolicy Bypass -File run-demo.ps1
   ```

That starts the observability stack, the server, three headless bots, and your client
window. In your window: **WASD** move, **T** to vote teleport (the run starts once the
party of four votes), **SPACE** to attack on the beat, **E** to grab the loot drop. When
the party returns to the hub your client shows the inventory it earned.

Closing your client window shuts everything back down.

## Options

```powershell
run-demo.ps1 -Bots 3        # number of bots (default 3, for a party of four)
run-demo.ps1 -Port 54400    # server UDP port (default 54400)
run-demo.ps1 -NoTelemetry   # skip the observability stack; just play
```

## Observability

With telemetry on (the default), the server exports OTLP to a local OpenTelemetry collector
on `127.0.0.1:4318`, which routes to native VictoriaMetrics and VictoriaLogs:

- Metrics: <http://127.0.0.1:8428>
- Logs: <http://127.0.0.1:9428>
- Traces: <http://127.0.0.1:10428> — only when a VictoriaTraces Windows build is available;
  otherwise metrics and logs run and traces are skipped (the launcher says which).

Binaries are fetched once into `%LOCALAPPDATA%\v-sekai-observability\`; the SQLite profile
database lives at `%LOCALAPPDATA%\v-sekai-loop-slice\profiles.db`.

## Notes

- First launch, Windows Defender Firewall may prompt to allow the server's UDP listener —
  allow it for local play.
- These are unsigned test builds; SmartScreen may warn on first run. For a signed installer
  instead, use the MSIX release (`packaging/build_msix.exs`).
- To run the server as an always-on Windows service (boot-start, auto-restart), wrap
  `loop-slice-server.exe` with nssm — see the decision record
  *Running background services on Windows with nssm*.

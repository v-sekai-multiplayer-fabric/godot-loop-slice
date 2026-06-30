<#
.SYNOPSIS
  Run the loot-action loop-slice demo on Windows 11 — native, no Docker, no WSL.

.DESCRIPTION
  Starts (optionally) the native observability stack, then the authoritative server,
  then -Bots bot clients and one human client window, all on 127.0.0.1 over ENet.
  Everything is a native Windows process; persistence is in-process SQLite. The loop
  needs four players, so the default 3 bots + your window completes the party.

  Expects loop-slice.exe, loop-slice-server.exe, and setup-observability.ps1 to sit
  next to this script (the demo release layout).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File run-demo.ps1
  powershell -ExecutionPolicy Bypass -File run-demo.ps1 -Bots 3 -NoTelemetry
#>
[CmdletBinding()]
param(
  [int]$Bots = 3,
  [int]$Port = 54400,
  [switch]$NoTelemetry
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$serverExe = Join-Path $root 'loop-slice-server.exe'
$clientExe = Join-Path $root 'loop-slice.exe'
foreach ($exe in @($serverExe, $clientExe)) {
  if (-not (Test-Path $exe)) { throw "missing $exe -- run this from the unzipped demo folder" }
}

$dataDir = Join-Path $env:LOCALAPPDATA 'v-sekai-loop-slice'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$loopDb = Join-Path $dataDir 'profiles.db'
$serverLog = Join-Path $dataDir 'server.log'
$procs = New-Object System.Collections.ArrayList

function Stop-All {
  Write-Host "`nshutting down..."
  foreach ($p in $procs) { if ($p -and -not $p.HasExited) { try { $p.Kill() } catch {} } }
}

try {
  # 1. observability (optional) — sets OTEL_EXPORTER_OTLP_ENDPOINT for the server
  if (-not $NoTelemetry) {
    Write-Host "=== starting native observability ==="
    $obs = & (Join-Path $root 'setup-observability.ps1')
    foreach ($p in $obs) { [void]$procs.Add($p) }
    $env:OTEL_EXPORTER_OTLP_ENDPOINT = 'http://127.0.0.1:4318'
    $env:OTEL_SERVICE_NAME = 'loop-server'
    Write-Host "telemetry on -> metrics http://127.0.0.1:8428  logs http://127.0.0.1:9428"
  } else {
    Remove-Item Env:\OTEL_EXPORTER_OTLP_ENDPOINT -ErrorAction SilentlyContinue
  }

  # 2. authoritative server (SQLite, ENet) — capture stdout to poll for readiness
  Write-Host "=== starting server on 127.0.0.1:$Port ==="
  $env:LOOP_PORT = "$Port"
  $env:LOOP_DB = $loopDb
  $env:TRANSPORT = 'enet'
  if (Test-Path $serverLog) { Remove-Item $serverLog -Force }
  $srv = Start-Process -FilePath $serverExe -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $serverLog -RedirectStandardError (Join-Path $dataDir 'server.err.log')
  [void]$procs.Add($srv)

  # wait up to 30s for "LOOPSRV ready" (clients also self-heal via reconnect)
  $ready = $false
  for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    if ($srv.HasExited) { throw "server exited early; see $serverLog" }
    if ((Test-Path $serverLog) -and (Select-String -Quiet -Path $serverLog -Pattern 'LOOPSRV ready')) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if ($ready) { Write-Host "server ready." } else { Write-Host "server not confirmed ready in 30s; starting clients anyway (they reconnect)." }

  # 3. clients — bots headless, then one human window, all pinned to localhost
  $env:LOOP_HOST = '127.0.0.1'
  Remove-Item Env:\OTEL_EXPORTER_OTLP_ENDPOINT -ErrorAction SilentlyContinue   # clients don't export
  Remove-Item Env:\LOOP_DB -ErrorAction SilentlyContinue
  $env:BOT = '1'
  for ($i = 1; $i -le $Bots; $i++) {
    $env:BOT_NAME = "bot$i"
    [void]$procs.Add((Start-Process -FilePath $clientExe -ArgumentList '--headless' -PassThru -WindowStyle Hidden))
  }
  Remove-Item Env:\BOT -ErrorAction SilentlyContinue
  Remove-Item Env:\BOT_NAME -ErrorAction SilentlyContinue
  Write-Host "=== launching your client window ==="
  Write-Host "WASD move, T vote teleport (party starts at 4), SPACE attack on the beat, E grab loot."
  $you = Start-Process -FilePath $clientExe -PassThru
  [void]$procs.Add($you)

  $you.WaitForExit()
  Write-Host "your client closed."
}
finally {
  Stop-All
}

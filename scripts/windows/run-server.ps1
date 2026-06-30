<#
.SYNOPSIS
  Run the loop-slice authoritative server on Windows (native, no Docker/WSL).

.DESCRIPTION
  Starts loop-slice-server.exe (ENet/UDP, in-process SQLite). The server binds all
  interfaces by default, so clients elsewhere on the LAN or internet connect to this
  machine's address on the port. -Telemetry also starts the native observability stack.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File run-server.ps1
  powershell -ExecutionPolicy Bypass -File run-server.ps1 -Port 54400 -Telemetry
#>
[CmdletBinding()]
param(
  [int]$Port = 54400,
  [switch]$Telemetry
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$exe = Join-Path $root 'loop-slice-server.exe'
if (-not (Test-Path $exe)) { throw "missing $exe -- run this from the installed/unzipped folder" }

$dataDir = Join-Path $env:LOCALAPPDATA 'v-sekai-loop-slice'
New-Item -ItemType Directory -Force $dataDir | Out-Null
$env:LOOP_PORT = "$Port"
$env:LOOP_DB = Join-Path $dataDir 'profiles.db'
$env:TRANSPORT = 'enet'

if ($Telemetry) {
  & (Join-Path $root 'setup-observability.ps1') | Out-Null
  $env:OTEL_EXPORTER_OTLP_ENDPOINT = 'http://127.0.0.1:4318'
  $env:OTEL_SERVICE_NAME = 'loop-server'
  Write-Host "telemetry on -> metrics http://127.0.0.1:8428  logs http://127.0.0.1:9428"
}

Write-Host "Loop-slice server on UDP $Port (ENet). Clients connect to one of these addresses:"
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
  ForEach-Object { Write-Host "  $($_.IPAddress):$Port" }
Write-Host "(allow the Windows Defender Firewall prompt for UDP $Port on first run)"
& $exe

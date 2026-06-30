<#
.SYNOPSIS
  Run the loop-slice client and connect to a server (native Windows, no Docker/WSL).

.DESCRIPTION
  Launches loop-slice.exe pointed at a server's address (host or IP). If -Server is
  omitted it prompts for one. The server must already be running and reachable on the
  port (default 54400). In the window: WASD move, T vote teleport, SPACE attack on the
  beat, E grab loot.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File run-client.ps1 -Server 192.168.1.50
#>
[CmdletBinding()]
param(
  [string]$Server,
  [int]$Port = 54400
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$exe = Join-Path $root 'loop-slice.exe'
if (-not (Test-Path $exe)) { throw "missing $exe -- run this from the installed/unzipped folder" }

if (-not $Server) { $Server = Read-Host "Server address (host or IP)" }
if (-not $Server) { throw "no server address given" }

$env:LOOP_HOST = $Server
$env:LOOP_PORT = "$Port"
$env:TRANSPORT = 'enet'
Write-Host "connecting to ${Server}:${Port} ..."
& $exe

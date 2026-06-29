<#
.SYNOPSIS
  Fetch and start the native Windows observability stack for the demo (no Docker/WSL).

.DESCRIPTION
  Downloads the OpenTelemetry collector and VictoriaMetrics (+ VictoriaLogs, and
  VictoriaTraces when a Windows build exists) as native Windows binaries, writes a
  collector config that routes OTLP on :4318 to those backends, starts them, and
  returns the started Process objects. VictoriaTraces is best-effort: if its release
  has no windows-amd64 asset, traces are skipped and metrics + logs still run.

  Backends: metrics http://127.0.0.1:8428, logs http://127.0.0.1:9428,
  traces http://127.0.0.1:10428 (if available). Collector OTLP: 4317 (gRPC), 4318 (HTTP).
#>
[CmdletBinding()]
param(
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'v-sekai-observability')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

function Get-Asset([string]$repo, [string]$rx) {
  # Return the browser_download_url of the latest release asset matching $rx, or $null.
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'v-sekai-demo' }
  } catch {
    try { $rel = (Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=10" -Headers @{ 'User-Agent' = 'v-sekai-demo' })[0] } catch { return $null }
  }
  ($rel.assets | Where-Object { $_.name -match $rx } | Select-Object -First 1).browser_download_url
}

function Fetch([string]$repo, [string]$rx, [string]$sub) {
  # Download + extract the matching asset into $InstallDir\$sub; return that dir or $null.
  $url = Get-Asset $repo $rx
  if (-not $url) { Write-Host "  [skip] no windows asset for $repo (pattern $rx)"; return $null }
  $dest = Join-Path $InstallDir $sub
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $file = Join-Path $dest ([IO.Path]::GetFileName($url))
  Write-Host "  fetching $repo -> $([IO.Path]::GetFileName($url))"
  Invoke-WebRequest -Uri $url -OutFile $file
  if ($file -match '\.zip$') { Expand-Archive -Path $file -DestinationPath $dest -Force }
  else { tar -xf $file -C $dest }   # bsdtar ships with Windows 10+
  return $dest
}

function Find-Exe([string]$dir, [string]$rx) {
  if (-not $dir) { return $null }
  (Get-ChildItem -Path $dir -Recurse -Filter *.exe | Where-Object { $_.Name -match $rx } | Select-Object -First 1).FullName
}

Write-Host "installing into $InstallDir"
$vmDir  = Fetch 'VictoriaMetrics/VictoriaMetrics' 'victoria-metrics-windows-amd64-.*\.zip'   'victoria-metrics'
$vlDir  = Fetch 'VictoriaMetrics/VictoriaLogs'    'victoria-logs-windows-amd64-.*\.zip'       'victoria-logs'
$vtDir  = Fetch 'VictoriaMetrics/VictoriaTraces'  'victoria-traces-windows-amd64-.*\.(zip|tar\.gz)' 'victoria-traces'
$otDir  = Fetch 'open-telemetry/opentelemetry-collector-releases' 'otelcol-contrib_.*_windows_amd64\.(tar\.gz|zip)' 'otelcol'

$vmExe = Find-Exe $vmDir 'victoria-metrics.*\.exe'
$vlExe = Find-Exe $vlDir 'victoria-logs.*\.exe'
$vtExe = Find-Exe $vtDir 'victoria-traces.*\.exe'
$otExe = Find-Exe $otDir 'otelcol-contrib\.exe'
if (-not $vmExe -or -not $otExe) { throw "could not resolve VictoriaMetrics and the OTEL collector binaries" }
$hasTraces = [bool]$vtExe

# collector config: metrics -> VM, logs -> VL, traces -> VT (only if present)
$tracesExporter = if ($hasTraces) { @"

  otlphttp/traces:
    endpoint: http://127.0.0.1:10428/insert/opentelemetry
    tls: { insecure: true }
"@ } else { '' }
$tracesPipeline = if ($hasTraces) { @"

    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/traces]
"@ } else { '' }

$config = @"
receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }
processors:
  batch: { timeout: 5s, send_batch_size: 1000 }
  memory_limiter: { check_interval: 5s, limit_mib: 256, spike_limit_mib: 64 }
exporters:
  prometheusremotewrite:
    endpoint: http://127.0.0.1:8428/api/v1/write
    tls: { insecure: true }
  otlphttp/logs:
    endpoint: http://127.0.0.1:9428/insert/opentelemetry
    tls: { insecure: true }$tracesExporter
service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/logs]$tracesPipeline
"@
$configPath = Join-Path $InstallDir 'otel-collector-config.yaml'
Set-Content -Path $configPath -Value $config -Encoding ascii

# start the backends, then the collector; return the Process objects
$procs = @()
$procs += Start-Process -FilePath $vmExe -PassThru -WindowStyle Hidden -ArgumentList @(
  '-httpListenAddr=:8428', "-storageDataPath=$(Join-Path $InstallDir 'vm-data')")
$procs += Start-Process -FilePath $vlExe -PassThru -WindowStyle Hidden -ArgumentList @(
  '-httpListenAddr=:9428', "-storageDataPath=$(Join-Path $InstallDir 'vl-data')")
if ($hasTraces) {
  $procs += Start-Process -FilePath $vtExe -PassThru -WindowStyle Hidden -ArgumentList @(
    '-httpListenAddr=:10428', "-storageDataPath=$(Join-Path $InstallDir 'vt-data')")
}
Start-Sleep -Seconds 1
$procs += Start-Process -FilePath $otExe -PassThru -WindowStyle Hidden -ArgumentList @("--config=$configPath")

if ($hasTraces) { Write-Host "observability up: metrics + logs + traces" }
else { Write-Host "observability up: metrics + logs (no VictoriaTraces windows build found; traces skipped)" }
$procs

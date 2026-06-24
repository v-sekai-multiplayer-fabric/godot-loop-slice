<#
  Build + sign the loop-slice-server MSIX from an already-exported Win64 Godot
  build that also contains loop-slice-server.exe (the .NET 8 launcher stub).
  Requires Windows + Windows SDK (makeappx.exe, signtool.exe).

  -BinDir   folder with loop-slice.exe, loop-slice.pck, and loop-slice-server.exe
  -Version  4-part version, e.g. 0.1.0.1
  -OutDir   output dir (default dist)
  -Publisher Identity Publisher; MUST equal the signing cert subject (default CN=v-sekai)
  -PfxPath  signing .pfx; if omitted a self-signed TEST cert is generated (test-install only)
  -PfxPassword  .pfx password, if any

  ex: pwsh packaging/msix-server/pack-server.ps1 -BinDir build/windows -Version 0.1.0.1
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$BinDir,
  [string]$Version  = "0.1.0.1",
  [string]$OutDir   = "dist",
  [string]$Publisher = "CN=v-sekai",
  [string]$PfxPath,
  [string]$PfxPassword
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Directory |
       Where-Object { Test-Path "$($_.FullName)\x64\makeappx.exe" } |
       Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdk) { throw "Windows SDK with makeappx.exe not found." }
$makeappx = "$($sdk.FullName)\x64\makeappx.exe"
$signtool = "$($sdk.FullName)\x64\signtool.exe"

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("loop-slice-server-msix-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path "$root\bin","$root\assets" | Out-Null
Copy-Item "$BinDir\*" "$root\bin\" -Recurse
Copy-Item "$here\assets\*" "$root\assets\"

[xml]$m = Get-Content "$here\AppxManifest.xml"
$m.Package.Identity.Version   = $Version
$m.Package.Identity.Publisher = $Publisher
$m.Save("$root\AppxManifest.xml")

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$msix = Join-Path $OutDir "v-sekai-loop-slice-server-$Version.msix"
& $makeappx pack /o /d $root /p $msix
if ($LASTEXITCODE) { throw "makeappx failed ($LASTEXITCODE)" }

if (-not $PfxPath) {
  $cert = New-SelfSignedCertificate -Type Custom -Subject $Publisher `
            -KeyUsage DigitalSignature -CertStoreLocation "Cert:\CurrentUser\My" `
            -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3","2.5.29.19={text}")
  $PfxPath = Join-Path $OutDir "loop-slice-server-test.pfx"; $PfxPassword = "test"
  Export-PfxCertificate -Cert $cert -FilePath $PfxPath `
    -Password (ConvertTo-SecureString $PfxPassword -AsPlainText -Force) | Out-Null
}
$pwArgs = if ($PfxPassword) { @("/p", $PfxPassword) } else { @() }
& $signtool sign /fd SHA256 /a /f $PfxPath @pwArgs $msix
if ($LASTEXITCODE) { throw "signtool failed ($LASTEXITCODE)" }

Write-Host "OK -> $msix"

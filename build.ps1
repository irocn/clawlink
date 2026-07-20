#Requires -Version 5.1
<#
.SYNOPSIS
  Build ClawLink Windows GUI into .\output (includes libs\ next to the exe).
#>
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

function Assert-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "'$Name' not found in PATH"
    }
}

Assert-Command flutter

$libsCore = Join-Path $Root "libs\clawlink-core.exe"
$libsWintun = Join-Path $Root "libs\wintun.dll"
if (-not (Test-Path $libsCore)) { throw "Missing $libsCore" }
if (-not (Test-Path $libsWintun)) { throw "Missing $libsWintun" }

Write-Host "==> flutter pub get"
& flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

Write-Host "==> flutter build windows --release"
& flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }

$release = Join-Path $Root "build\windows\x64\runner\Release"
$exe = Join-Path $release "clawlink.exe"
if (-not (Test-Path $exe)) { throw "Missing $exe" }

$Out = Join-Path $Root "output"
if (Test-Path $Out) {
    try {
        Remove-Item -Recurse -Force $Out -ErrorAction Stop
    } catch {
        throw "Cannot refresh output\ — close clawlink.exe then rebuild.`n$_"
    }
}
New-Item -ItemType Directory -Force -Path $Out | Out-Null

Write-Host "==> Copying Release -> output\"
Copy-Item -Force $exe $Out
Get-ChildItem (Join-Path $release "*.dll") | ForEach-Object {
    Copy-Item -Force $_.FullName $Out
}
Copy-Item -Recurse -Force (Join-Path $release "data") (Join-Path $Out "data")

$outLibs = Join-Path $Out "libs"
New-Item -ItemType Directory -Force -Path $outLibs | Out-Null
Copy-Item -Force $libsCore $outLibs
Copy-Item -Force $libsWintun $outLibs

# Ensure Release\libs is populated even if CMake install skipped a clean tree.
$relLibs = Join-Path $release "libs"
New-Item -ItemType Directory -Force -Path $relLibs | Out-Null
Copy-Item -Force $libsCore $relLibs
Copy-Item -Force $libsWintun $relLibs

Write-Host ""
Write-Host "Done. Output:"
Get-ChildItem $Out | ForEach-Object {
    if ($_.PSIsContainer) { "  $($_.Name)/" } else { "  $($_.Name) ($([math]::Round($_.Length/1KB)) KB)" }
}
Get-ChildItem $outLibs | ForEach-Object {
    "  libs/$($_.Name) ($([math]::Round($_.Length/1KB)) KB)"
}

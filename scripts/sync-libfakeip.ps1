#Requires -Version 5.1
<#
.SYNOPSIS
  Build libfakeip DLL in itunnel and copy it into clawlink for Dart FFI.

.DESCRIPTION
  Source crate (default):
    E:\github\itunnel\crates\libfakeip   # sibling of clawlink

  Build steps (same as manual):
    cd itunnel/crates/libfakeip
    cargo build --release
    # → target/release/libfakeip.dll

  This script runs those steps, then copies the DLL to:
    clawlink/windows/lib/libfakeip.dll
    clawlink/libs/libfakeip.dll

.NOTES
  Override crate path:  $env:CLAWLINK_LIBFAKEIP_ROOT = 'E:\github\itunnel\crates\libfakeip'
  Override itunnel root: $env:CLAWLINK_ITUNNEL_ROOT = 'E:\github\itunnel'
  Copy only (skip cargo):  -CopyOnly
#>
param(
    [switch]$CopyOnly
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Crate = if ($env:CLAWLINK_LIBFAKEIP_ROOT) {
    $env:CLAWLINK_LIBFAKEIP_ROOT.TrimEnd('\', '/')
} else {
    $Itunnel = if ($env:CLAWLINK_ITUNNEL_ROOT) {
        $env:CLAWLINK_ITUNNEL_ROOT.TrimEnd('\', '/')
    } else {
        Join-Path (Split-Path $Root -Parent) 'itunnel'
    }
    Join-Path $Itunnel 'crates\libfakeip'
}

$Built = Join-Path $Crate 'target\release\libfakeip.dll'
if (-not (Test-Path -LiteralPath (Join-Path $Crate 'Cargo.toml'))) {
    throw "libfakeip crate not found at $Crate (expected E:\github\itunnel\crates\libfakeip)."
}

$WindowsLib = Join-Path $Root 'windows\lib'
$LibsDir = Join-Path $Root 'libs'
foreach ($dir in @($WindowsLib, $LibsDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

if (-not $CopyOnly) {
    Write-Host ">> cd $Crate"
    Write-Host ">> cargo build --release"
    Push-Location $Crate
    try {
        cargo build --release
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path -LiteralPath $Built) {
                Write-Warning "cargo build failed; reusing existing $Built"
            } else {
                throw "cargo build --release failed (exit $LASTEXITCODE); no DLL at $Built"
            }
        }
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath $Built)) {
    throw "Missing $Built — run: cd $Crate; cargo build --release"
}

Copy-Item -LiteralPath $Built -Destination (Join-Path $WindowsLib 'libfakeip.dll') -Force
Copy-Item -LiteralPath $Built -Destination (Join-Path $LibsDir 'libfakeip.dll') -Force
Write-Host ">> OK: copied target/release/libfakeip.dll"
Write-Host "   -> $(Join-Path $WindowsLib 'libfakeip.dll')"
Write-Host "   -> $(Join-Path $LibsDir 'libfakeip.dll')"

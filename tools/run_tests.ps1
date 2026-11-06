# Runs the headless GDScript test suite.
# Usage: powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1 [-Filter name]
# Fails if any test fails OR if Godot printed a SCRIPT ERROR (runtime error inside a test).
param(
    [string]$Filter = "",
    [string]$Godot = $(if ($env:GODOT) { $env:GODOT } else { "C:\tools\Godot\Godot_v4.7.2-stable_win64_console.exe" })
)
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if (-not (Test-Path ".godot")) { & $Godot --headless --path . --import *> $null }
    $userArgs = @()
    if ($Filter) { $userArgs = @("--", "--filter=$Filter") }
    $out = & $Godot --headless --path . -s res://tests/run_tests.gd @userArgs 2>&1 | ForEach-Object { "$_" }
    $out | Where-Object { $_ -match '^\s+(PASS|FAIL|-)\s' -or $_ -match '^RESULT' -or $_ -match 'SCRIPT ERROR' -or $_ -match '^\s+at: ' }
    $code = $LASTEXITCODE
    $scriptErrors = ($out | Where-Object { $_ -match 'SCRIPT ERROR' }).Count
    if ($scriptErrors -gt 0) {
        Write-Output "SCRIPT ERRORS: $scriptErrors (treated as failure)"
        exit 1
    }
    exit $code
} finally {
    Pop-Location
}

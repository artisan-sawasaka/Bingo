# Builds the Windows x64 distribution into build/windows/ and smoke-tests it.
# Usage: powershell -ExecutionPolicy Bypass -File tools\build_windows.ps1 [-SkipSmoke]
# Requires: Godot 4.7.2 export templates (Editor > Manage Export Templates > Download),
#           installed at %APPDATA%\Godot\export_templates\4.7.2.stable\
param(
    [switch]$SkipSmoke,
    [string]$Godot = $(if ($env:GODOT) { $env:GODOT } else { "C:\tools\Godot\Godot_v4.7.2-stable_win64_console.exe" })
)
# "Continue": Godot writes warnings to stderr, which PowerShell 5.1 would turn into terminating errors.
$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "build\windows"
$exe = Join-Path $out "BingoDrum3D.exe"
$tpl = Join-Path $env:APPDATA "Godot\export_templates\4.7.2.stable\windows_release_x86_64.exe"

if (-not (Test-Path $tpl)) {
    throw "Export template not found: $tpl`nInstall Godot 4.7.2 export templates first (see README)."
}
Push-Location $root
try {
    New-Item -ItemType Directory -Force $out | Out-Null
    Write-Output "== import"
    & $Godot --headless --path . --import 2>&1 | Out-Null
    Write-Output "== export"
    $running = Get-CimInstance Win32_Process -Filter "Name like 'BingoDrum3D%'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($out, [StringComparison]::OrdinalIgnoreCase) }
    if ($running) {
        # (ASCII only: Windows PowerShell 5.1 misreads non-ASCII text in BOM-less scripts)
        throw "build\windows\BingoDrum3D.exe is running (PID $($running.ProcessId -join ', ')). Close the app and run the build again."
    }
    if (Test-Path $exe) { Remove-Item $exe -Force -ErrorAction Stop }
    & $Godot --headless --path . --export-release "Windows Desktop" $exe 2>&1 | ForEach-Object { "$_" } | Select-String -Pattern "ERROR|error|Export|export" | ForEach-Object { $_.Line }
    if (-not (Test-Path $exe)) { throw "export failed: $exe not created" }
    Write-Output "== notices"
    & $Godot --headless --path . -s res://tools/gen_licenses.gd -- "--out=$out\THIRD_PARTY_LICENSES.txt" 2>&1 | Select-String "wrote"
    Copy-Item README.md (Join-Path $out "README.md") -Force
    Copy-Item docs\protocol.md (Join-Path $out "protocol.md") -Force
    Get-ChildItem $out | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Output

    if (-not $SkipSmoke) {
        Write-Output "== smoke test (exported exe serves web remote + runs one draw)"
        $port = 18810
        $shot = Join-Path $env:TEMP "bingo_smoke.png"
        $p = Start-Process -FilePath $exe -ArgumentList "--", "--profile=smoke", "--port=$port", "--windowed", "--auto-start=75", "--demo-spin=1", "--capture=$shot", "--capture-delay=4.5", "--quit-after-capture" -PassThru
        Start-Sleep -Seconds 2
        $ok = $true
        foreach ($path in "/", "/app.js", "/styles.css", "/healthz") {
            try {
                $r = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$port$path" -TimeoutSec 5
                Write-Output ("  {0,-12} {1} {2} bytes" -f $path, $r.StatusCode, $r.RawContentLength)
                if ($r.StatusCode -ne 200 -or $r.RawContentLength -lt 2) { $ok = $false }
            } catch { Write-Output "  $path FAILED: $_"; $ok = $false }
        }
        $p.WaitForExit(20000) | Out-Null
        if (Test-Path $shot) { Write-Output "  screenshot: $shot" } else { Write-Output "  screenshot missing"; $ok = $false }
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Write-Output "  app did not quit by itself"; $ok = $false }
        $log = Join-Path $env:APPDATA "BingoDrum3D\logs\godot.log"
        if (Test-Path $log) {
            $hits = Select-String -Path $log -Pattern "draw #1 accepted|capture saved|SCRIPT ERROR|ERROR"
            $hits | ForEach-Object { Write-Output ("  log: " + $_.Line) }
            if (-not ($hits | Where-Object { $_.Line -match "draw #1 accepted" })) { Write-Output "  draw not found in log"; $ok = $false }
            if ($hits | Where-Object { $_.Line -match "SCRIPT ERROR" }) { $ok = $false }
        } else { Write-Output "  log not found: $log"; $ok = $false }
        Remove-Item -Recurse -Force (Join-Path $env:APPDATA "BingoDrum3D\profiles\smoke") -ErrorAction SilentlyContinue
        if (-not $ok) { Write-Output "SMOKE: FAIL"; exit 1 }
        Write-Output "SMOKE: PASS"
    }
} finally {
    Pop-Location
}

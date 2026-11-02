<#
.SYNOPSIS
    flash.ps1 - robust compile-and-upload for the Teknic ClearCore on Windows.
    Windows-native port of scripts/flash.sh (Windows PowerShell 5.1 or
    PowerShell 7). No WSL required.

.DESCRIPTION
    Strategy (same as flash.sh):
      1. Quick device checks before the slow compile: exactly one ClearCore
         on USB, and its COM port isn't held by another program
      2. Compile to a clean build dir with arduino-cli
      3. Determine device state via the USB PID
           2890:8022 = application running
           2890:0022 = bootloader waiting
      4. If in app mode: 1200-baud touch ourselves, then poll for the
         bootloader PID and let CDC settle. If already in the bootloader:
         skip the touch
      5. Call bossac directly - no -a (no second touch, which races the
         freshly-enumerated CDC: "Set binary mode / No device found") and
         no -R (see 6). Retry up to -Retries times with backoff
      6. Start the application with boot-app.ps1 instead of bossac's -R.
         After a plain reset the bootloader waits a moment for a second
         reset (its double-tap detection) before starting the application;
         boot-app.ps1 writes the bootloader's own "start the application
         now" word first, so it starts at once. See "How the bootloader
         decides" in the README
      7. Verify the device returns to PID 8022. If it is still in the
         bootloader, send the start command again: that's safe to repeat

    The bootloader (2890:0022) usually gets a different COM number from the
    application (2890:8022); the script finds it by USB ID each time.

.PARAMETER Sketch
    Sketch folder (its name must match the .ino inside it).

.PARAMETER Port
    COM port of the ClearCore in application mode. Default: auto-detect.
    The bootloader's port is always auto-detected.

.EXAMPLE
    .\scripts\flash.ps1 .\MySketch
    .\scripts\flash.ps1 .\MySketch -Port COM4 -AppReturnTimeout 20

.NOTES
    Exit codes (same as flash.sh):
      0  success
      1  compile / missing-dependency failure, or the port is held by
         another program
      2  device not detected (or more than one ClearCore connected)
      3  bootloader entry failed
      4  bossac flash failed after retries
      5  device didn't return to app mode after flash
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Sketch,
    [Parameter(Position = 1)][string]$Port,
    [ValidateRange(1, 10)][int]$Retries = 3,
    [ValidateRange(0, 60)][int]$RetryDelay = 2,
    [ValidateRange(1, 600)][int]$BootloaderTimeout = 10,
    [ValidateRange(1, 600)][int]$AppReturnTimeout = 10
)

$ErrorActionPreference = 'Stop'
$Fqbn     = 'ClearCore:sam:clearcore'
$Offset   = '0x4000'
$CcTmp    = Join-Path $env:TEMP 'cc-flash'     # %TEMP% is per user on Windows
$BuildDir = Join-Path $CcTmp 'build'
$BossacLog = Join-Path $CcTmp 'bossac.log'
$BootApp  = Join-Path $PSScriptRoot 'boot-app.ps1'

function Log($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "==> OK: $m" -ForegroundColor Green }
function Err($m) { Write-Host "==> ERR: $m" -ForegroundColor Red }

# ---------------------------------------------------------------- helpers

# All present ClearCore PnP nodes (USB device nodes, interfaces, COM ports).
function Get-ClearCoreNodes {
    @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE '%VID_2890%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match '^USB\\VID_2890&PID_[0-9A-F]{4}' })
}

function Get-NodePid($node) {
    [regex]::Match($node.PNPDeviceID, 'PID_([0-9A-F]{4})').Groups[1].Value.ToUpperInvariant()
}

# Snapshot of the ClearCores on USB: Count (physical devices), Pid of the
# first one ('8022', '0022' or $null) and the COM port that belongs to it.
function Get-ClearCore {
    $nodes = Get-ClearCoreNodes
    # One USB device node per physical board: composite interfaces carry &MI_xx.
    $devs = @($nodes | Where-Object { $_.PNPDeviceID -notmatch '&MI_' })
    $state = [pscustomobject]@{ Count = $devs.Count; Pid = $null; Com = $null }
    if ($devs.Count -eq 0) { return $state }
    $state.Pid = Get-NodePid $devs[0]
    foreach ($n in $nodes) {
        if ($n.Name -match '\((COM\d+)\)' -and (Get-NodePid $n) -eq $state.Pid) {
            $state.Com = $Matches[1].ToUpperInvariant(); break
        }
    }
    return $state
}

# Poll (by wall-clock deadline; one WMI query can take a while) until the
# ClearCore shows up with the given PID, and with -RequireCom until Windows
# has also given it a COM port. Returns the snapshot or $null.
function Wait-ClearCorePid([string]$want, [int]$timeoutSec, [switch]$RequireCom) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $d = Get-ClearCore
        if ($d.Pid -eq $want -and (-not $RequireCom -or $d.Com)) {
            $d | Add-Member -NotePropertyName WaitedMs -NotePropertyValue ([int]$sw.ElapsedMilliseconds)
            return $d
        }
        Start-Sleep -Milliseconds 200
    } while ($sw.Elapsed.TotalSeconds -lt $timeoutSec)
    return $null
}

# The bootloader can be on USB a moment before Windows gives it a COM port
# (longer the first time, while the driver installs). Wait for both.
function Wait-BootloaderPort {
    $d = Wait-ClearCorePid '0022' ([Math]::Max($BootloaderTimeout, 15)) -RequireCom
    if ($d) { return $d }
    Err "The bootloader is on USB (2890:0022) but Windows hasn't given it a COM port. Check Device"
    Err "Manager > Ports (a first-time driver install can take a while), then re-run flash.ps1."
    return $null
}

function Get-UsbipdHint {
    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { return }
    # Function-local: usbipd warnings on stderr must not become terminating errors (PS 5.1).
    $ErrorActionPreference = 'Continue'
    try {
        $attached = @(& usbipd list 2>$null | Where-Object { $_ -is [string] -and $_ -match '\b2890:(8022|0022)\b' -and $_ -match 'Attached' })
    } catch { return }
    if ($attached.Count -gt 0) {
        $busid = ($attached[0] -split '\s+')[0]
        Err "usbipd-win has the ClearCore attached to WSL, so Windows can't see it. Give it back with:"
        Err "  usbipd detach --busid $busid   (stop any 'usbipd attach --auto-attach' first)"
    }
}

function Find-ArduinoCli {
    $c = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    # winget (ArduinoSA.CLI) installs here; PATH may be stale in an old shell.
    foreach ($p in @("$env:ProgramFiles\Arduino CLI\arduino-cli.exe",
                     "$env:LOCALAPPDATA\Programs\Arduino CLI\arduino-cli.exe")) {
        if (Test-Path $p -PathType Leaf) { return $p }
    }
    Err "arduino-cli not found. Install it: winget install ArduinoSA.CLI (then open a new terminal)"
    exit 1
}

function Find-Bossac {
    $root = Join-Path $env:LOCALAPPDATA 'Arduino15\packages\arduino\tools\bossac'
    $b = Get-ChildItem -Path $root -Recurse -Filter bossac.exe -ErrorAction SilentlyContinue |
        Sort-Object { [version](($_.Directory.Name -replace '^(\d+(\.\d+)*).*$', '$1')) } -ErrorAction SilentlyContinue |
        Select-Object -Last 1
    if (-not $b) { Err "bossac.exe not found under $root - run: arduino-cli core install ClearCore:sam"; exit 1 }
    return $b.FullName
}

# Open the port without touching DTR and close it again. Returns $null when
# it's free, or a message. Windows COM ports are exclusive, so "access
# denied" means another program has it open.
function Test-PortFree([string]$com) {
    $sp = New-Object System.IO.Ports.SerialPort $com, 9600
    $sp.DtrEnable = $false
    try {
        $sp.Open()
        try { [GC]::SuppressFinalize($sp.BaseStream) } catch { }
        return $null
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        if ($e -is [System.UnauthorizedAccessException]) {
            return "$com is held by another program (Arduino IDE Serial Monitor, PuTTY, Tera Term, a running upload...). Close it and retry."
        }
        return "can't open $com ($($e.Message))"
    } finally {
        try { $sp.Close() } catch { }
        try { $sp.Dispose() } catch { }
    }
}

function Invoke-Touch([string]$com) {
    Log "Triggering bootloader (1200-baud touch on $com)..."
    # The firmware reboots to the bootloader when DTR drops while the line
    # rate is 1200 (libClearCore UsbManager::CBLineStateChanged).
    $sp = New-Object System.IO.Ports.SerialPort $com, 1200
    $sp.DtrEnable = $true
    $opened = $false
    try {
        $sp.Open(); $opened = $true
        try { [GC]::SuppressFinalize($sp.BaseStream) } catch { }
        Start-Sleep -Milliseconds 100
        $sp.DtrEnable = $false      # the drop at 1200 baud is the trigger
        Start-Sleep -Milliseconds 100
    } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        # The board often resets during Open() itself ("A device which does
        # not exist was specified"); that's success, judged by the poll below.
        Write-Verbose "touch: $($e.Message)"
        if (-not $opened -and $e -is [System.UnauthorizedAccessException]) {
            # A port vanishing mid-open can also say "access denied": only call
            # it held if the board is still sitting in application mode.
            Start-Sleep -Milliseconds 500
            $d = Get-ClearCore
            if ($d.Pid -eq '8022' -and $d.Com -eq $com) {
                Err "$com is held by another program; close it (Serial Monitor, PuTTY...) and retry."
                return $false
            }
        }
    } finally {
        try { $sp.Close() } catch { }
        try { $sp.Dispose() } catch { }
    }

    $d = Wait-ClearCorePid '0022' $BootloaderTimeout
    if ($d) {
        Log "Bootloader detected (PID 0022) after $($d.WaitedMs)ms"
        if (-not (Wait-BootloaderPort)) { return $false }
        Start-Sleep -Seconds 1      # extra CDC settle window - what the IDE does implicitly
        return $true
    }
    Err "Bootloader entry timed out after ${BootloaderTimeout}s (the board never showed up as 2890:0022)."
    Err "If the running sketch is hung or crashed, press RESET twice quickly (the board stays in the"
    Err "bootloader), then re-run flash.ps1; it skips the touch when the board is already in the bootloader."
    Get-UsbipdHint
    return $false
}

function Invoke-Bossac([string]$bossac, [string]$bin) {
    for ($a = 1; $a -le $Retries; $a++) {
        if ($a -gt 1) {
            Log "bossac retry $a/$Retries (waiting ${RetryDelay}s for CDC to settle)..."
            Start-Sleep -Seconds $RetryDelay
        }
        # The bootloader's COM port is looked up fresh each attempt; a brief
        # disappearance is waited out rather than spending a bossac attempt.
        $d = Wait-ClearCorePid '0022' $BootloaderTimeout -RequireCom
        if (-not $d) {
            $n = Get-ClearCore
            Err "The bootloader's COM port isn't there (USB PID now: $(if ($n.Pid) { $n.Pid } else { 'none' }))."
            return $false
        }
        $com = $d.Com
        # No -a (we did the touch already; a second one races the CDC
        # re-enumeration) and no -R (step 6 starts the application without
        # the double-tap wait). Run to completion, check the log afterwards.
        Log "bossac on $com (attempt $a)"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'   # bossac's stderr must not become a terminating error
        try {
            $out = & $bossac -i -d "--port=$com" -U -e -w -v "--offset=$Offset" $bin 2>&1 |
                ForEach-Object { "$_" } | Out-String
        } finally { $ErrorActionPreference = $prev }
        Set-Content -Path $BossacLog -Value $out -Encoding UTF8
        if ($out -match 'Verify successful') { return $true }
        if ($out -match '(?i)access is denied|UnauthorizedAccess') {
            Err "bossac couldn't open ${com}: another program (Serial Monitor, PuTTY...) holds the bootloader's port. Close it and retry."
            return $false
        }
    }
    Err "bossac failed after $Retries attempts. Last 15 lines of bossac output ($BossacLog):"
    Get-Content $BossacLog -Tail 15 | ForEach-Object { Write-Host $_ }
    return $false
}

# Leave the bootloader into the new application at once (see boot-app.ps1).
function Invoke-BootApp {
    Start-Sleep -Milliseconds 500   # let bossac's close settle before reopening the port
    $d = Get-ClearCore
    if ($d.Pid -ne '0022' -or -not $d.Com) { return ($d.Pid -eq '8022') }
    & $BootApp -Port $d.Com | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------- run

if (-not (Test-Path -LiteralPath $Sketch -PathType Container)) { Err "sketch dir not found: $Sketch"; exit 1 }
# No trailing separator: "C:\My Sketch\" would end in \" and PS 5.1 would
# pass arduino-cli a broken argument.
$Sketch = (Resolve-Path -LiteralPath $Sketch).ProviderPath.TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $BootApp -PathType Leaf)) { Err "boot-app.ps1 not found next to flash.ps1 ($BootApp)"; exit 1 }
$ArduinoCli = Find-ArduinoCli
$Bossac = Find-Bossac

# Step 1: cheap device checks before the slow compile.
$dev = Get-ClearCore
if ($dev.Count -gt 1) { Err "More than one ClearCore is connected. Unplug all but one and retry."; exit 2 }
if ($dev.Count -eq 0) {
    Err "ClearCore not detected on USB. Plug in the cable and retry (or press RESET twice quickly if the sketch doesn't start USB)."
    Get-UsbipdHint
    exit 2
}
if ($dev.Pid -eq '8022') {
    $appCom = if ($Port) { $Port.Trim().ToUpperInvariant() } else { $dev.Com }
    if (-not $appCom) { Err "ClearCore found (PID 8022) but no COM port for it; check Device Manager, or pass -Port COMx"; exit 2 }
    $held = Test-PortFree $appCom
    if ($held) { Err $held; exit 1 }
} elseif ($dev.Pid -eq '0022' -and $dev.Com) {
    # Opening the SAM-BA CDC port with DTR low and closing it is harmless.
    $held = Test-PortFree $dev.Com
    if ($held) { Err $held; exit 1 }
}

# Step 2: compile
Log "Compiling $Sketch..."
New-Item -ItemType Directory -Force -Path $CcTmp | Out-Null
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Path $BuildDir | Out-Null
# Compiler warnings go to stderr; with output redirected (*> log, CI, ISE)
# PS 5.1 would turn them into terminating errors under EAP=Stop.
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $ArduinoCli compile --fqbn $Fqbn --output-dir $BuildDir $Sketch 2>&1 | ForEach-Object { Write-Host "$_" }
    $compileRc = $LASTEXITCODE
} finally { $ErrorActionPreference = $prev }
if ($compileRc -ne 0) { Err "Compile failed."; exit 1 }

# arduino-cli names the .bin after the sketch folder / .ino basename
$Bin = Join-Path $BuildDir ((Split-Path -Leaf $Sketch) + '.ino.bin')
if (-not (Test-Path -LiteralPath $Bin -PathType Leaf)) {
    $Bin = Get-ChildItem -LiteralPath $BuildDir -Filter '*.ino.bin' | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Bin) { Err "Compiled .bin not found in $BuildDir"; exit 1 }
Log "Using bossac: $Bossac"
Log "Binary: $Bin ($((Get-Item -LiteralPath $Bin).Length) bytes)"

# Steps 3-4: determine device state; enter the bootloader if needed
$dev = Get-ClearCore
if ($dev.Count -gt 1) { Err "More than one ClearCore is connected. Unplug all but one and retry."; exit 2 }
if (-not $dev.Pid) {
    Err "ClearCore not detected on USB. Plug in the cable and retry."
    Get-UsbipdHint
    exit 2
}
switch ($dev.Pid) {
    '8022' {
        $appCom = if ($Port) { $Port.Trim().ToUpperInvariant() } else { $dev.Com }
        if (-not $appCom) { Err "ClearCore found (PID 8022) but no COM port for it; pass -Port COMx"; exit 2 }
        if (-not (Invoke-Touch $appCom)) { exit 3 }
    }
    '0022' {
        Log "Device is already in bootloader (PID 0022) - skipping touch"
        if (-not (Wait-BootloaderPort)) { exit 3 }
        Start-Sleep -Seconds 1      # let any in-flight CDC activity drain
    }
    default { Err "Unknown ClearCore USB PID: $($dev.Pid). Expected 8022 or 0022."; exit 2 }
}

# Step 5: flash
if (-not (Invoke-Bossac $Bossac $Bin)) { exit 4 }

# Step 6: start the application at once (no double-tap wait). If this
# fails, step 7 still checks where the board is and tries again.
Log "Starting the application..."
if (-not (Invoke-BootApp)) { Err "The start command didn't go through; checking the device..." }

# Step 7: verify
Log "Waiting for device to return to application mode..."
$back = Wait-ClearCorePid '8022' $AppReturnTimeout
if ($back) {
    Log "Device returned to application mode (PID 8022) after $($back.WaitedMs)ms"
    Ok "Flash complete."
    exit 0
}

$now = Get-ClearCore
if ($now.Pid -eq '0022' -and $now.Com) {
    # Still in the bootloader. Sending the start command again is safe.
    Log "Still in the bootloader - sending the start command again..."
    if (Invoke-BootApp) {
        $back = Wait-ClearCorePid '8022' $AppReturnTimeout
        if ($back) {
            Log "Device returned to application mode (PID 8022) after $($back.WaitedMs)ms"
            Ok "Flash complete."
            exit 0
        }
    }
    Err "Device is still in the bootloader. The new firmware is written and verified;"
    Err "start it with scripts\boot-app.ps1, or power-cycle the ClearCore."
} elseif (-not $now.Pid) {
    Err "The ClearCore left the bootloader but isn't visible to Windows."
    Get-UsbipdHint
    Err "The new firmware is written and verified and is most likely running; if it's just slow to"
    Err "enumerate, raise -AppReturnTimeout."
} else {
    Err "Device didn't return to PID 8022 after flash (USB PID now: $($now.Pid)). Bossac"
    Err "reported success, but the device may not be running the new firmware."
}
exit 5

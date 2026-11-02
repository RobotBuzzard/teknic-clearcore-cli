<#
.SYNOPSIS
    boot-app.ps1 - leave the ClearCore bootloader and start the application
    at once. No power cycle, no double-tap wait. Windows-native port of
    scripts/boot-app.sh (Windows PowerShell 5.1 or PowerShell 7).

.DESCRIPTION
    Why: after a plain reset (bossac's -R included) the ClearCore
    bootloader doesn't start the application straight away. For an Arduino
    sketch it first waits a moment for a second reset (its RESET double-tap
    detection), and a reset in that wait keeps it in the bootloader. This
    script skips that wait. It also gets a board that is sitting in the
    bootloader with good firmware back into the application without a
    power cycle.

    How: the bootloader (UF2 Bootloader v2.3.1-Teknic.4, Teknic's fork of
    Microsoft's uf2-samdx1) clears the last word of RAM (0x2002FFFC) and
    starts the application at once when that word holds 0xF02669EF,
    uf2-samdx1's DBL_TAP_MAGIC_QUICK_BOOT. The bootloader's own
    resetIntoApp() works the same way. This script checks that the port is
    a ClearCore bootloader answering SAM-BA, writes that word, then
    requests a system reset (AIRCR.SYSRESETREQ).
    See "How the bootloader decides" in the README and docs/bootloader.md.

.PARAMETER Port
    COM port of the ClearCore bootloader (e.g. COM7). Default: the port of
    the one ClearCore found on USB. Note the bootloader (USB 2890:0022)
    usually gets a different COM number from the application (2890:8022).

.EXAMPLE
    .\scripts\boot-app.ps1
    .\scripts\boot-app.ps1 -Port COM7

.NOTES
    Exit codes:
      0  start requested, or the application is already running
      1  the port is held by another process / access denied, or no SAM-BA answer
      2  the port doesn't exist, no ClearCore on it, more than one ClearCore,
         or it vanished while opening it
    Exit 0 means the start was requested, not that the application started.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Port
)

$ErrorActionPreference = 'Stop'

$QuickBootAddr  = '2002FFFC'   # uf2-samdx1 DBL_TAP_PTR: last word of RAM
$QuickBootMagic = 'F02669EF'   # uf2-samdx1 DBL_TAP_MAGIC_QUICK_BOOT
$AircrAddr      = 'E000ED0C'
$AircrSysReset  = '05FA0004'

function Fail([int]$code, [string[]]$lines) {
    # WriteErrorLine shows in the console, ISE and VS Code (stderr under
    # -File); Write-Information also lands in a caller's *> redirection.
    foreach ($l in $lines) {
        $Host.UI.WriteErrorLine("boot-app: $l")
        Write-Information "boot-app: $l"
    }
    exit $code
}

# All present ClearCore PnP nodes (USB device nodes and their COM ports).
function Get-ClearCoreNodes {
    @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE '%VID_2890%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match '^USB\\VID_2890&PID_[0-9A-F]{4}' })
}

# COM ports that belong to a ClearCore: @{ Com = 'COM7'; Pid = '0022' }
function Get-ClearCorePorts {
    foreach ($n in Get-ClearCoreNodes) {
        if ($n.Name -match '\((COM\d+)\)') {
            [pscustomobject]@{
                Com = $Matches[1].ToUpperInvariant()
                Pid = [regex]::Match($n.PNPDeviceID, 'PID_([0-9A-F]{4})').Groups[1].Value.ToUpperInvariant()
            }
        }
    }
}

# Hint when usbipd-win has the board attached to WSL (it then vanishes from Windows).
function Get-UsbipdHint {
    if (-not (Get-Command usbipd -ErrorAction SilentlyContinue)) { return @() }
    # Function-local: usbipd warnings on stderr must not become terminating errors (PS 5.1).
    $ErrorActionPreference = 'Continue'
    try {
        $attached = @(& usbipd list 2>$null | Where-Object { $_ -is [string] -and $_ -match '\b2890:(8022|0022)\b' -and $_ -match 'Attached' })
    } catch { return @() }
    if ($attached.Count -gt 0) {
        $busid = ($attached[0] -split '\s+')[0]
        return @("usbipd-win has the ClearCore attached to WSL; give it back to Windows with:",
                 "  usbipd detach --busid $busid   (stop any 'usbipd attach --auto-attach' first)")
    }
    return @()
}

# ---- which ClearCore port? ----
$ports = @(Get-ClearCorePorts)
if (-not $Port) {
    $unique = @($ports | Select-Object -ExpandProperty Com -Unique)
    if ($unique.Count -eq 0) {
        $devs = @(Get-ClearCoreNodes | Where-Object { $_.PNPDeviceID -notmatch '&MI_' })
        if ($devs.Count -gt 0) {
            $usbPid = [regex]::Match($devs[0].PNPDeviceID, 'PID_([0-9A-F]{4})').Groups[1].Value
            Fail 2 @("the ClearCore is on USB (2890:$usbPid) but Windows hasn't given it a COM port yet",
                     "(a first-time driver install can take a while); check Device Manager > Ports and retry")
        }
        Fail 2 (@("no ClearCore COM port found; is the ClearCore connected?") + (Get-UsbipdHint))
    }
    if ($unique.Count -gt 1) {
        Fail 2 @("more than one ClearCore port ($($unique -join ', ')); pass -Port COMx")
    }
    $Port = $unique[0]
}
$Port = $Port.Trim().ToUpperInvariant()
if ($Port -notmatch '^COM\d+$') { Fail 2 @("'$Port' isn't a COM port name (expected e.g. COM7)") }

$entry = $ports | Where-Object { $_.Com -eq $Port } | Select-Object -First 1
if (-not $entry) {
    if ([System.IO.Ports.SerialPort]::GetPortNames() -contains $Port) {
        Fail 2 @("$Port isn't a ClearCore port (no USB 2890:xxxx device owns it)")
    }
    Fail 2 (@("$Port doesn't exist; is the ClearCore connected?") + (Get-UsbipdHint))
}
switch ($entry.Pid) {
    '8022' { Write-Host "boot-app: the application is already running ($Port is 2890:8022)"; exit 0 }
    '0022' { }
    default { Fail 2 @("$Port isn't a ClearCore bootloader (USB ID '2890:$($entry.Pid)')") }
}

# ---- talk to the SAM-BA monitor ----
# The bootloader ignores baud rate and line state. DTR/RTS are raised as
# bossac does on Windows.
$sp = New-Object System.IO.Ports.SerialPort $Port, 921600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.Handshake    = [System.IO.Ports.Handshake]::None
$sp.DtrEnable    = $true
$sp.RtsEnable    = $true
$sp.ReadTimeout  = 2000
$sp.WriteTimeout = 1000
$sp.Encoding     = [System.Text.Encoding]::ASCII
$sp.NewLine      = "`r"

try {
    $sp.Open()
} catch {
    $e = $_.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [System.UnauthorizedAccessException]) {
        Fail 1 @("can't open ${Port}: access denied. Another program (Arduino IDE Serial Monitor,",
                 "PuTTY, a running bossac/flash) has it open; close it first")
    }
    Fail 2 @("can't open $Port ($($e.Message)); did the board re-enumerate? Try again")
}
# The board resets (and its COM port vanishes) while we still hold the
# handle. On .NET Framework the SerialStream finalizer can then throw on the
# finalizer thread and take PowerShell down; this is the usual workaround.
try { [GC]::SuppressFinalize($sp.BaseStream) } catch { }

function Close-Port {
    try { $sp.Close() } catch { }
    try { $sp.Dispose() } catch { }
}

$reply = ''
try {
    try {
        # Drop anything already waiting, then send N# and ask the monitor for
        # its version (V#), which it answers with a line like
        # "v1.1 [Arduino:XYZ] ...\n\r". This bootloader treats N# (bossac's
        # opening command) as a no-op and doesn't answer it, but right after a
        # bossac session a V# sent on its own often went unanswered; with N#
        # first it is answered. One retry, then give up without writing anything.
        # The retry doesn't flush, so a reply already queued is still read.
        Start-Sleep -Milliseconds 200
        $sp.DiscardInBuffer()
        for ($try = 1; $try -le 2; $try++) {
            $sp.Write('N#')
            Start-Sleep -Milliseconds 50
            $sp.Write('V#')
            try {
                $line = $sp.ReadLine()   # NewLine is "`r"
                if ($line -match 'v\d+\.\d+ [^\r\n]*') { $reply = $Matches[0].Trim(); break }
            } catch [System.TimeoutException] { }
        }
    } catch {
        Fail 2 @("lost $Port while talking to it ($($_.Exception.Message)); did the board re-enumerate? Try again")
    }

    if (-not $reply) {
        Fail 1 @("no SAM-BA answer on $Port; nothing written (is another program reading ${Port}?)")
    }
    Write-Verbose "SAM-BA: $reply"

    try {
        $sp.Write("W$QuickBootAddr,$QuickBootMagic#")
        Start-Sleep -Milliseconds 100
    } catch {
        Fail 2 @("lost $Port before the start command was written ($($_.Exception.Message)); try again")
    }
    # The device resets while we're still talking to it, so this write (and the
    # close) may fail; ignore errors, as bossac does.
    try { $sp.Write("W$AircrAddr,$AircrSysReset#") } catch { }
    Start-Sleep -Milliseconds 50
} finally {
    Close-Port
}

Write-Host "boot-app: asked the bootloader to start the application"
exit 0

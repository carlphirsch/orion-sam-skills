<#
.SYNOPSIS
    Watchdog-wrapped SAM PowerShell monitor — in-process runspace pattern.
    Public Release version (sanitized; generic hosts and addressing only).

.DESCRIPTION
    The watchdog-design-patterns reference implementation: the
    orion-windows-powershell-scripting skeleton wrapped per SKILL.md §2-3 —
    watchdog-first layering (runspace + bounded WaitOne, parent owns all
    SAM output), one-string argument tokenization, input sanitization,
    interactive detection, sentinel handling, [SAM-META] on STDERR, and
    Message:/Statistic: on STDOUT for every exit path including timeout.
    Replace the CORE LOGIC section; keep the frame. For checks that wedge
    threads in native code (WMI/RPC, hard mounts), see SKILL.md §3
    Start-Job process isolation.

.NOTES
    Exit codes : 0=Up 1=Down 2=Warning 3=Critical 4=Unknown
    Watchdog   : 40 s (engine kills at ~120 s; we must beat it)
    Sentinel   : sam_xxx.sentinel — pick a unique 3-hex ID per monitor
#>

# =====================================================================
# WATCHDOG INFRASTRUCTURE — the only code that runs unprotected.
# In-process runspace beats Start-Job by ~12 s/poll on modest endpoints
# and is host-independent (works under the agent's script host).
# =====================================================================
$WatchdogTimeout = 40
$ParentStart = [DateTime]::UtcNow

# Parent-scope metadata. The runspace has its own Get-Meta, but the parent
# reaches its degenerate exits (null result, watchdog timeout) with no result
# object to carry a Meta block — so those paths need their own. The contract
# is "every exit path emits the COMPLETE 5-field [SAM-META] block", and that
# includes these guard paths, or an operator triaging a timeout/null gets a
# blank script-output panel. $Note annotates the ExecutionTime line when the
# real start is unknowable (the runspace, not the parent, owns the true start).
function Write-ParentMeta([string]$Note) {
    $Dur = [math]::Round(([DateTime]::UtcNow - $ParentStart).TotalSeconds, 2)
    $Exec = if ($Note) { $Note } else { $ParentStart.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    [Console]::Error.WriteLine("[SAM-META] Hostname:      $($env:COMPUTERNAME)")
    [Console]::Error.WriteLine("[SAM-META] ExecutionTime: $Exec")
    [Console]::Error.WriteLine("[SAM-META] Duration:      $($Dur)s")
    [Console]::Error.WriteLine("[SAM-META] Account:       $($env:USERDOMAIN)\$($env:USERNAME)")
    [Console]::Error.WriteLine("[SAM-META] RuntimeVer:    PowerShell $($PSVersionTable.PSVersion)")
}

$Ps = [powershell]::Create()
[void]$Ps.AddScript({
    param([string[]]$RawArgs)

    # Everything below is watchdog-protected: a hang or crash here still
    # lets the parent emit valid SAM output before the engine's own kill.
    try {
        $StartTime = [DateTime]::UtcNow

        # Metadata built as data and emitted by the parent — defined once,
        # used by every exit path (SKILL.md §6: spend the comment budget,
        # and the code, once).
        function Get-Meta([datetime]$Start) {
            $Dur = [math]::Round(([DateTime]::UtcNow - $Start).TotalSeconds, 2)
            @(
                "[SAM-META] Hostname:      $($env:COMPUTERNAME)"
                "[SAM-META] ExecutionTime: $($Start.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
                "[SAM-META] Duration:      $($Dur)s"
                "[SAM-META] Account:       $($env:USERDOMAIN)\$($env:USERNAME)"
                "[SAM-META] RuntimeVer:    PowerShell $($PSVersionTable.PSVersion)"
            )
        }
        function New-Result([string]$Message, $Statistic, [int]$ExitCode) {
            [PSCustomObject]@{
                Message   = $Message
                Statistic = $Statistic
                ExitCode  = $ExitCode
                Meta      = Get-Meta $StartTime
            }
        }

        # --- Arguments: SAM delivers ScriptArguments as ONE string ------
        $Tokens = @(($RawArgs -join ' ') -split '\s+' | Where-Object { $_ })
        $TargetHost = if ($Tokens.Count -ge 1) { $Tokens[0].Trim() } else { '192.0.2.1' }

        # --- Sanitization: arguments come verbatim from Orion fields and
        #     run under a privileged service account — allowlist first ----
        if ($TargetHost -notmatch '^[a-zA-Z0-9._:-]+$') {
            return New-Result "Invalid target host: contains unexpected characters" 0 2
        }

        # --- Sentinel: first poll reports Up + init, never a false Down --
        $SentinelPath = Join-Path $env:TEMP 'sam_xxx.sentinel'
        if (-not (Test-Path $SentinelPath)) {
            New-Item -Path $SentinelPath -ItemType File -Force | Out-Null
            return New-Result "Monitor initialized — sentinel created, target: $($TargetHost)" 0 0
        }

        # =============================================================
        # CORE LOGIC — replace this block. Rules that survive editing:
        #   * cmdlet parameters, never string-built commands
        #   * $($var) everywhere; dollar-brace tokens are Orion macro syntax
        #     and substitution is textual — comments and strings included, so
        #     no literal dollar-brace may appear anywhere in this file
        #   * guard divisions — NaN silently kills app-wide statistics
        #   * handle PS 5.1/7 property differences (ResponseTime/Latency)
        # =============================================================
        $Ping = Test-Connection -ComputerName $TargetHost -Count 2 -ErrorAction Stop
        $Latency = ($Ping | ForEach-Object {
            if ($null -ne $_.ResponseTime) { $_.ResponseTime } else { $_.Latency }
        } | Measure-Object -Average).Average
        $Latency = [math]::Round($Latency, 1)

        $Code = if ($Latency -gt 200) { 3 } elseif ($Latency -gt 100) { 2 } else { 0 }
        return New-Result "Ping to $($TargetHost) avg $($Latency)ms" $Latency $Code
    }
    catch {
        # Flatten: a multi-line exception value loses its continuation lines
        # in the parsed Message — only explicit Message: lines are joined.
        return New-Result "Monitor error: $(($_.Exception.Message -replace '\s+', ' '))" 0 2
    }
}).AddArgument($args)

# =====================================================================
# PARENT: waits out the runspace, owns all SAM output.
# =====================================================================
$Handle = $Ps.BeginInvoke()

if ($Handle.AsyncWaitHandle.WaitOne($WatchdogTimeout * 1000)) {
    $Result = $Ps.EndInvoke($Handle) | Select-Object -First 1
    $Ps.Dispose()

    if ($null -eq $Result -or $null -eq $Result.Message) {
        # Runspace returned nothing usable — still honor the FULL contract,
        # metadata included, so this guard path is as diagnosable as any other.
        Write-ParentMeta
        Write-Host "Message: Monitor completed but returned no result object"
        Write-Host "Statistic: 0"
        exit 2
    }

    foreach ($Line in $Result.Meta) { [Console]::Error.WriteLine($Line) }
    Write-Host "Message: $($Result.Message)"
    Write-Host "Statistic: $($Result.Statistic)"

    # Interactive testers get a labeled preview of exactly what SAM parses;
    # headless mode must never prompt or pause.
    $Interactive = [Environment]::UserInteractive -and `
                   -not [bool]([Environment]::GetCommandLineArgs() -match '-NonInteractive')
    if ($Interactive) {
        Write-Host ""
        Write-Host "--- SAM preview: exit $($Result.ExitCode), see lines above ---"
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit $Result.ExitCode
}
else {
    # Watchdog fired. The runspace may be stuck in a blocking call; the
    # parent still owns the process and reports the timeout itself, with the
    # same complete metadata block as every other path.
    $Ps.Stop(); $Ps.Dispose()
    Write-ParentMeta '(watchdog fired — runspace start unavailable)'
    Write-Host "Message: Script execution timed out after $($WatchdogTimeout)s"
    Write-Host "Statistic: 0"
    exit 3
}

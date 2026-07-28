<#
.SYNOPSIS
    SAM PowerShell script monitor skeleton (no watchdog).
    Public Release version (sanitized; generic hosts and addressing only).

.DESCRIPTION
    Start every new Windows SAM monitor from this file. It implements the
    structure from SKILL.md §4: one-string argument tokenization, input
    sanitization, interactive detection, sentinel handling, [SAM-META] on
    STDERR, and Message:/Statistic: on STDOUT for every coded exit path.
    Replace the CORE LOGIC section; keep the frame.

    This skeleton has NO watchdog: a check that blocks will sit until the
    engine kills it (~120 s) with nothing captured. If the core logic can
    hang — network calls, WMI/CIM against remote or flaky providers, file
    access on remote mounts — wrap it per the watchdog-design-patterns
    skill (references/watchdog-monitor.ps1 there is this same monitor,
    watchdog-wrapped).

.NOTES
    Exit codes : 0=Up 1=Down 2=Warning 3=Critical 4=Unknown
    Sentinel   : sam_xxx.sentinel — pick a unique 3-hex ID per monitor
#>

$StartTime = [DateTime]::UtcNow

# Metadata built as data and emitted once per run — defined here, used by
# every exit path (SKILL.md §6: spend the comment budget, and the code, once).
function Write-SamMeta {
    # Guarded: losing metadata must never cost the SAM output that follows.
    try {
        $Dur = [math]::Round(([DateTime]::UtcNow - $script:StartTime).TotalSeconds, 2)
        $Meta = @(
            "[SAM-META] Hostname:      $($env:COMPUTERNAME)"
            "[SAM-META] ExecutionTime: $($script:StartTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
            "[SAM-META] Duration:      $($Dur)s"
            "[SAM-META] Account:       $($env:USERDOMAIN)\$($env:USERNAME)"
            "[SAM-META] RuntimeVer:    PowerShell $($PSVersionTable.PSVersion)"
        )
        foreach ($Line in $Meta) { [Console]::Error.WriteLine($Line) }
    } catch { }
}

# Single exit funnel: every path produces metadata, both contract lines,
# an optional interactive preview, and an explicit exit code.
function Exit-Sam([string]$Message, $Statistic, [int]$ExitCode) {
    Write-SamMeta
    Write-Host "Message: $Message"
    Write-Host "Statistic: $Statistic"
    $Interactive = [Environment]::UserInteractive -and `
                   -not [bool]([Environment]::GetCommandLineArgs() -match '-NonInteractive')
    if ($Interactive) {
        Write-Host ""
        Write-Host "--- SAM preview: exit $ExitCode, see lines above ---"
        Write-Host "Press any key to exit..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit $ExitCode
}

try {
    # --- Arguments: SAM delivers ScriptArguments as ONE string ----------
    $Tokens = @(($args -join ' ') -split '\s+' | Where-Object { $_ })
    $TargetHost = if ($Tokens.Count -ge 1) { $Tokens[0].Trim() } else { '192.0.2.1' }

    # --- Sanitization: arguments come verbatim from Orion fields and run
    #     under a privileged service account — allowlist first ------------
    if ($TargetHost -notmatch '^[a-zA-Z0-9._:-]+$') {
        Exit-Sam "Invalid target host: contains unexpected characters" 0 2
    }

    # --- Sentinel: first poll reports Up + init, never a false Down ------
    $SentinelPath = Join-Path $env:TEMP 'sam_xxx.sentinel'
    if (-not (Test-Path $SentinelPath)) {
        New-Item -Path $SentinelPath -ItemType File -Force | Out-Null
        Exit-Sam "Monitor initialized — sentinel created, target: $($TargetHost)" 0 0
    }

    # =====================================================================
    # CORE LOGIC — replace this block. Rules that survive editing:
    #   * cmdlet parameters, never string-built commands
    #   * $($var) everywhere; dollar-brace tokens are Orion macro syntax
    #     and substitution is textual — comments and strings included, so
    #     no literal dollar-brace may appear anywhere in this file
    #   * guard divisions — NaN silently kills app-wide statistics
    #   * handle PS 5.1/7 property differences (ResponseTime/Latency)
    #   * can this block? then add the watchdog wrapper (see .DESCRIPTION)
    # =====================================================================
    $Ping = Test-Connection -ComputerName $TargetHost -Count 2 -ErrorAction Stop
    $Latency = ($Ping | ForEach-Object {
        if ($null -ne $_.ResponseTime) { $_.ResponseTime } else { $_.Latency }
    } | Measure-Object -Average).Average
    $Latency = [math]::Round($Latency, 1)

    $Code = if ($Latency -gt 200) { 3 } elseif ($Latency -gt 100) { 2 } else { 0 }
    Exit-Sam "Ping to $($TargetHost) avg $($Latency)ms" $Latency $Code
}
catch {
    # Flatten: a multi-line exception value loses its continuation lines in
    # the parsed Message — only explicit Message: prefixed lines are joined.
    Exit-Sam "Monitor error: $(($_.Exception.Message -replace '\s+', ' '))" 0 2
}

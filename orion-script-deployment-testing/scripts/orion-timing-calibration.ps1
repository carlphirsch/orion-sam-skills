<#
.SYNOPSIS
    orion-timing-calibration.ps1 -- native-PowerShell port of
    orion-timing-calibration.py for Windows dev boxes without Python.
    Public Release version (sanitized; generic hosts only).

.DESCRIPTION
    Same cache file, same JSON schema, same constants and clamp formulas as
    the Python module -- the two implementations MUST stay in lockstep (the
    clamps are exactly what naive re-implementations get wrong; both files
    were cross-validated on identical inputs at creation). A mixed fleet can
    share one cache: keys are "<host>|<nodeId>|<frequency>".

    Usage (JSON on stdout, exit 0 on success / 2 on usage error):
      .\orion-timing-calibration.ps1 derive <host> <nodeId> <frequency>
      .\orion-timing-calibration.ps1 record <host> <nodeId> <frequency> <latency_s>
      .\orion-timing-calibration.ps1 show   [<host> <nodeId> <frequency>]

    Cache: ~\.claude\orion-timing.json (override: ORION_TIMING_CACHE).
    Schedule semantics (see the deployment skill, section 4): start checking
    at first_check, poll every poll_interval, provisional-fail (iteration
    verdict ONLY) at provisional_fail, formal silent-Unknown verdict at
    hard_cap. Calibration may only TIGHTEN the stock schedule.

    Kept pure ASCII: Windows PowerShell 5.1 reads BOM-less .ps1 as CP1252.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]]$Args_
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Constants -- MUST match orion-timing-calibration.py exactly.
$STALE_SECONDS       = 30 * 86400
$MIN_FIRST_CHECK     = 10
$POLL_INTERVAL       = 10
$PROVISIONAL_FLOOR   = 90
$HARD_CAP            = 600
$COLD_FAST_FREQ      = 90     # first check when a fast __Frequency (<=60) was set
$COLD_DEFAULT        = 150    # T+2.5 min otherwise

function Get-CachePath {
    if ($env:ORION_TIMING_CACHE) { return $env:ORION_TIMING_CACHE }
    return (Join-Path $HOME '.claude/orion-timing.json')
}

function Get-Key([string]$OrionHost, $NodeId, $Frequency) {
    return ('{0}|{1}|{2}' -f $OrionHost, [int]$NodeId, [int]$Frequency)
}

function Load-Cache {
    $p = Get-CachePath
    if (-not (Test-Path $p)) { return @{} }
    # PS 5.1 has no ConvertFrom-Json -AsHashtable; walk properties instead.
    $obj = Get-Content -Raw $p | ConvertFrom-Json
    $h = @{}
    foreach ($prop in $obj.PSObject.Properties) { $h[$prop.Name] = @($prop.Value) }
    return $h
}

function Save-Cache([hashtable]$Data) {
    $p = Get-CachePath
    $dir = Split-Path -Parent $p
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Atomic-ish: write temp then replace, so a crash cannot truncate the cache.
    # WriteAllText with explicit BOM-less UTF8 is load-bearing: under Windows
    # PowerShell 5.1, Set-Content -Encoding UTF8 writes a BOM, which the
    # Python twin's json reader rejects -- poisoning the shared cache.
    $tmp = "$p.tmp"
    [System.IO.File]::WriteAllText($tmp,
        (($Data | ConvertTo-Json -Depth 6) + "`n"),
        [System.Text.UTF8Encoding]::new($false))
    Move-Item -Force $tmp $p
}

function Get-Median([double[]]$Sorted) {
    $n = $Sorted.Count
    if ($n % 2 -eq 1) { return $Sorted[[int][math]::Floor($n / 2)] }
    return ($Sorted[$n / 2 - 1] + $Sorted[$n / 2]) / 2.0
}

function Get-P95NearestRank([double[]]$Sorted) {
    $n = $Sorted.Count
    $rank = [math]::Max(1, [math]::Ceiling(0.95 * $n))
    return $Sorted[$rank - 1]
}

function Get-UnixNow { return [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }

function Invoke-Record([string]$OrionHost, $NodeId, $Frequency, $LatencyS) {
    $data = Load-Cache
    $entry = [ordered]@{
        ts        = Get-UnixNow
        ts_iso    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        node_id   = [int]$NodeId
        frequency = [int]$Frequency
        latency_s = [math]::Round([double]$LatencyS, 1)
    }
    $k = Get-Key $OrionHost $NodeId $Frequency
    if ($data.ContainsKey($k)) { $data[$k] = @($data[$k]) + @([pscustomobject]$entry) }
    else { $data[$k] = @([pscustomobject]$entry) }
    Save-Cache $data
    return [pscustomobject]$entry
}

function Invoke-Derive([string]$OrionHost, $NodeId, $Frequency) {
    $now = Get-UnixNow
    $data = Load-Cache
    $k = Get-Key $OrionHost $NodeId $Frequency
    $records = @(); if ($data.ContainsKey($k)) { $records = @($data[$k]) }
    $fresh = @($records | Where-Object { ($now - [double]$_.ts) -le $STALE_SECONDS } |
               ForEach-Object { [double]$_.latency_s })

    $coldFirst = $COLD_DEFAULT
    if ([int]$Frequency -le 60) { $coldFirst = $COLD_FAST_FREQ }

    if ($fresh.Count -eq 0) {
        return [pscustomobject][ordered]@{
            source           = 'cold'
            samples          = 0
            stale_ignored    = $records.Count
            first_check      = $coldFirst
            poll_interval    = $POLL_INTERVAL
            provisional_fail = $HARD_CAP      # cold runs get no fast-fail
            hard_cap         = $HARD_CAP
        }
    }

    $vals = @($fresh | Sort-Object)
    $median = Get-Median $vals
    $p95 = Get-P95NearestRank $vals
    # Calibration may only TIGHTEN the stock schedule (see .py for rationale).
    return [pscustomobject][ordered]@{
        source           = 'calibrated'
        samples          = $vals.Count
        stale_ignored    = $records.Count - $vals.Count
        median           = $median
        p95              = $p95
        # [double] casts are load-bearing: with a mixed int/double pair,
        # PowerShell can bind [math]::Max to the int overload and silently
        # ROUND the double argument (23.6 -> 24), diverging from the .py.
        first_check      = [math]::Max([double]$MIN_FIRST_CHECK, [math]::Min([double](0.5 * $median), [double]$coldFirst))
        poll_interval    = $POLL_INTERVAL
        provisional_fail = [math]::Min([math]::Max([double](2.0 * $p95), [double]$PROVISIONAL_FLOOR), [double]$HARD_CAP)
        hard_cap         = $HARD_CAP
    }
}

# Usage failures must exit 2 like the .py; Write-Error would throw under
# ErrorActionPreference=Stop and exit 1 before reaching our exit code.
function Fail-Usage([string]$Msg) { [Console]::Error.WriteLine($Msg); exit 2 }

switch ($Command) {
    'derive' {
        if (-not $Args_ -or $Args_.Count -lt 3) { Fail-Usage 'usage: derive <host> <nodeId> <frequency>' }
        Invoke-Derive $Args_[0] $Args_[1] $Args_[2] | ConvertTo-Json
    }
    'record' {
        if (-not $Args_ -or $Args_.Count -lt 4) { Fail-Usage 'usage: record <host> <nodeId> <frequency> <latency_s>' }
        Invoke-Record $Args_[0] $Args_[1] $Args_[2] $Args_[3] | ConvertTo-Json
    }
    'show' {
        $data = Load-Cache
        if ($Args_ -and $Args_.Count -ge 3) {
            $k = Get-Key $Args_[0] $Args_[1] $Args_[2]
            $filtered = @{}
            if ($data.ContainsKey($k)) { $filtered[$k] = $data[$k] }
            $data = $filtered
        }
        $data | ConvertTo-Json -Depth 6
    }
    default {
        Fail-Usage ('usage: orion-timing-calibration.ps1 derive|record|show ... (cache: {0})' -f (Get-CachePath))
    }
}

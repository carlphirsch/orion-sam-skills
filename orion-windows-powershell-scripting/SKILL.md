---
name: orion-windows-powershell-scripting
description: >
  Write SolarWinds Orion SAM custom script monitors and Windows-side Orion
  scripts in PowerShell. Use this skill whenever the user wants to create,
  debug, modify, or review a SAM Windows script monitor, a PowerShell monitor
  for Orion, or any monitoring script for Windows endpoints that reports
  status/statistics to a polling engine — trigger on mentions of SAM
  PowerShell monitors, Orion Windows scripting, Message:/Statistic: output,
  exit-code status mapping (0/1/2/3), or SAM component scripts, even if
  SolarWinds is not named explicitly. Pairs with
  orion-script-deployment-testing (getting the script into Orion),
  watchdog-design-patterns (watchdog/timeout implementation), and
  orion-linux-python-scripting (Linux targets).
---

# Orion Windows PowerShell Scripting — Public Release

*Public Release version: fully sanitized for publication — all examples use
generic hosts and documentation addressing; the §9 gate enforces it.*

SAM script monitors run inside a headless polling engine (Orion poller or the
SolarWinds agent on the node). The engine spawns the script on a timed
interval, captures STDOUT/STDERR, records the exit code, and kills the process
at its timeout (~120 s default). Whatever output exists at exit is all the
operator will ever see. Every rule here exists so the operator always finds
something actionable in the Orion console — on every poll, on every code path.

All behavior below was verified empirically on SolarWinds Observability
Self-Hosted 2026.2 (SAM 2026.2), agent-managed and poller-executed Windows
nodes. Deployment, verification timing, and template mechanics live in the
**orion-script-deployment-testing** skill — read it before pushing anything
to Orion.

## 1. Language selection on Windows

**PowerShell is the language for Windows monitors.** Two runtimes exist —
Windows PowerShell 5.1 and PowerShell 7+ (pwsh) — with different module
availability and different object shapes (e.g. `Test-Connection` returns
`ResponseTime` on 5.1 but `Latency` on 7+). Write for 5.1 as the floor,
handle both property names where they differ, and report the runtime version
in the metadata block (§4) so version mismatches are visible from the console.

Also available, **but deprecated — maintenance of existing monitors only**:

- **Batch (.bat/.cmd)** — no structured error handling, no watchdog
  primitives; do not write new monitors in it.
- **ECMA JScript and VBScript (Windows Script Host)** — legacy WSH runtimes;
  only justified for pre-existing monitors or narrow WSH COM automation.

**Do not design monitors around non-standard runtimes** (Python, Perl,
Node, etc. on Windows). Managed corporate PCs commonly enforce Windows
Script Host and application-control restrictions that block or omit those
interpreters. A monitor that targets a runtime absent from the node never
executes: the engine gets "missing executable", and the component shows
**Down** with no message and no statistic — a script-deployment failure that
masquerades as a service outage.

## 2. SAM output contract

Three channels, all required on **every** exit path — success, error,
sanitization rejection, watchdog timeout, unhandled exception.

**Exit code → component status** (measured; undefined codes → Unknown):

| Exit | Status | Exit | Status |
|---|---|---|---|
| 0 | Up | 3 | Critical |
| 1 | Down | 4 | Unknown |
| 2 | Warning | | |

Always exit explicitly. An unhandled error's OS-level exit code (often 1)
maps to Down — a script bug then masquerades as an outage. Exit codes and
server-side statistic thresholds compose: **worst wins** — so if your
monitor exits 0 yet Orion shows Warning/Critical, suspect the component's
*inherited column thresholds* (a template repurposed from a factory skeleton
carries them; see the deployment skill §2), not your script.

**STDOUT** — the only thing the engine parses:

```
Message: Human-readable status with key values
Statistic: 42
```

- Only the bare numeric `Statistic:` is mandatory; a poll without a parseable
  one fails ("'Statistic' missing"). `Message:` is optional but always emit
  it — it is the operator's status line.
- Values must be bare numbers. Units or text (`42 ms`, `N/A`) make the line
  invisible to the parser and fail the whole poll. **Never emit `NaN`** — it
  parses as valid, the component goes Up, and it silently poisons statistic
  storage for *every component in the application* from then on. Guard every
  division.
- Named stats (`Statistic.MyStat: 7`) each need a matching Numeric column in
  the component's DynamicColumnSettings or they are silently dropped. Names
  strictly `[A-Za-z0-9_]` — dots, spaces, hyphens in the name are dropped
  even with matching columns. Column mechanics are deployment-side: see the
  deployment skill §2 (step 4) and §3.
- A component that reports Down/Unknown gets its Message wrapped in Orion's
  red "Testing on node ... failed" banner. Write failure Messages that read
  sensibly inside that wrapper: state *what* is down and *why*.

**STDERR** — never parsed, but captured in full and shown in the component's
script output panel. Put all diagnostics, metadata, and verbose logging here.
Use `[Console]::Error.WriteLine(...)` — `Write-Error` adds PowerShell
formatting noise. Never put `Message:`/`Statistic:` lines on STDERR.

## 3. Three PowerShell-specific traps

- **`${...}` is Orion macro territory.** Any `${token}` in a script body is
  substituted at poll time as an Orion macro (`${IP}`, `${CREDENTIAL}`).
  PowerShell's `${var}` interpolation is indistinguishable from a macro —
  always write `$($var)` instead. The substitution is **textual across the
  entire ScriptBody — comments and string literals included** — so no
  literal dollar-brace may appear anywhere in the file, not even in a
  comment explaining this rule. Verify with a grep before delivery.
- **A colon right after `$Var` in a double-quoted string is parsed as a
  scope qualifier.** `"$State:"` makes PowerShell look for a variable named
  `State` in a scope/drive called whatever-follows (the `$scope:name`
  syntax, as in `$env:PATH`), so it expands to empty and the status text
  silently loses the value. This bites `Message:` strings that place a
  variable immediately before a colon. Write `"$($State):"` to end the
  variable explicitly. (Same family as the macro trap: PowerShell's parser
  reading more than you meant after a `$`.)
- **ScriptArguments arrives as ONE string.** Configure `80 95` and the
  script receives a single `$args[0]` of `"80 95"`. Re-tokenize at the top:
  `$RawArgs = @(($RawArgs -join ' ') -split '\s+' | Where-Object { $_ })`.
  Consequence: individual argument values cannot contain spaces.

## 4. Script structure

In order: capture UTC start time → tokenize and parse arguments →
**sanitize inputs** → detect interactive vs headless → sentinel check →
core logic in a top-level try/catch → map result to exit code. On every
path — success, sanitization rejection, exception — emit the `[SAM-META]`
block to STDERR, then `Message:`/`Statistic:` to STDOUT, then exit with an
explicit code.

**Metadata block** (STDERR, every run) — Hostname, ExecutionTime (UTC ISO
8601), Duration (s), Account, RuntimeVer, each prefixed `[SAM-META]`. This is
what lets an operator answer "which machine ran this, as whom, on which
runtime, and how close to timeout" without remoting in.

**Input sanitization** — the engine passes arguments verbatim from Orion
custom properties, node fields, macros, and operator-typed values; none are
validated upstream, and the script runs under a privileged service account.
Validate every argument against an explicit format/range before it touches a
command or query; reject failures with a clear Message and exit 2. Never
interpolate arguments into command strings — use cmdlet parameters
(`Test-Connection -ComputerName $TargetHost`, never
`Invoke-Expression "ping $TargetHost"`).

**Interactive detection** — `[Environment]::UserInteractive` plus a check for
`-NonInteractive` in the command line. Headless mode must never prompt (a
prompt blocks until the engine kills the process); interactive mode may show
a labeled SAM-output preview and pause for the tester.

**Sentinel file** — for monitors with multi-step initialization, a marker
file (`sam_<3-hex>.sentinel` in `$env:TEMP`) makes the first poll report Up
with an init message instead of a possibly-false Down that fires an alert
before any baseline exists. Note `$env:TEMP` differs between the service
account and an interactive tester — sentinels created hand-testing are
invisible to the engine, and vice versa.

The full annotated skeleton implementing all of this is
**`references/monitor-skeleton.ps1`** — start from it rather than from
memory.

## 5. Watchdog timers — the benefit, and when to add one

The skeleton above has no watchdog, and the try/catch only protects against
*crashes*. A **hang** is a different failure class: a stuck DNS lookup, WMI
query against a flaky provider, or file access on a dead remote mount plays
out as — the script blocks with no SAM output written; the engine's own
~120 s timeout fires and kills the process (`TerminateProcess` — no chance
to write anything); Orion shows Unknown with a blank message and a null
statistic; the operator opens the console and learns nothing about which
machine ran the check or what hung. A 40-second watchdog converts that
entire class into a self-reported, diagnosable result: the script exits
under its own control with a timeout Message, a valid Statistic, metadata,
and a deliberate exit code — minutes sooner, on every poll.

A watchdog is not mandatory for every monitor. Decide by whether the core
logic can block:

- **Add one** when the check touches anything without a guaranteed internal
  timeout — network calls, remote/flaky WMI-CIM providers, remote
  filesystems, spawned processes, credential/directory lookups.
- **Reasonable to skip** for trivial local checks (reading a local perf
  counter, arithmetic on Get-CimInstance against stable local classes)
  where a hang is implausible and the 120 s engine kill is an acceptable
  worst case.

When adding one, do not write watchdog code from memory — read the
**watchdog-design-patterns** skill. It carries the design principles
(outermost layer, parent owns output, timeout path emits every defined
column, cancel-on-success), the in-process runspace pattern vs `Start-Job`
trade-offs and traps, and `references/watchdog-monitor.ps1` — this
skeleton's watchdog-wrapped twin.

## 6. Windows environment facts that cost real debugging time

- The agent runs as **LocalSystem**. Files it writes under `C:\Windows\Temp`
  are unreadable to normal users — for execution breadcrumbs use a
  world-readable path like `C:\Users\Public\`.
- LocalHost-targeted scripts on an agent see the target node as `127.0.0.1`.
- Use `Get-CimInstance`, not the deprecated `Get-WmiObject`; wrap
  environment probes (`w32tm`, `Get-NetFirewallProfile`) in try/catch with a
  readable fallback — minimal installs lack them.
- Multiple explicit `Message:` lines are newline-joined and all kept —
  but a multi-line *value* inside one `Message:` is not: only the prefixed
  first line survives, the continuation lines are lost. Flatten exception
  and diagnostic text to a single line before emitting it
  (`-replace '\s+', ' '`). Duplicate `Statistic:` lines — last wins. Parser
  accepts case-insensitive prefixes, leading whitespace, any line order.
  Both `Write-Host` and `Write-Output` reach STDOUT equally.
- Measured channel capacity: messages of 10,000 chars store untruncated
  (quotes, pipes, angle brackets, ampersands survive); statistics accept
  negatives, high-precision decimals (kept exactly), 14-digit integers, and
  scientific notation (`1.5E3` → 1500). Message and Statistic are stored in
  **every** state including Down/Unknown — carry diagnostics into failure
  states. Ceiling: 70 named stats + the bare pair verified stored on one
  component (the 72-column import limit; see deployment skill §2).

## 7. Deploy-verify timing (summary)

Once a monitor deploys, verification is fast if you let it be: on a settled
agent a full deploy→verify→teardown iteration runs in **~45–55 s** when the
verify loop polls stored statistics every ~10 s and **exits the moment data
appears** — never sit out a fixed wait. A fast `__Frequency` (verified to a
10 s floor) densifies steady-state polls but does **not** shorten the first
poll (~30–90 s settled; 7–12 min after an agent reconnect — check agent
connectivity before deploying). T+10 min is a formal-failure bound, not a
wait. The full timing model, exit-on-first-data recipe, and the
latency-calibration script live in the **orion-script-deployment-testing**
skill.

## 8. Commenting standard

Comment thoroughly, but spend the budget once:

- Comments explain **why** — the operator consequence or the trap being
  avoided ("UTC avoids timezone ambiguity across regions", "`$($var)` because
  `${var}` is macro territory"). Never narrate what the next line does.
- Document each helper **once, at its definition** (what it guarantees and
  when to call it). Call sites get no repeated comment blocks — a five-times
  repeated metadata comment is noise that hides the one comment that matters.
- One block comment per structural section, not per statement.
- No changelog-voice comments ("fixed", "per review", "new in v2").

## 9. Public-release gate

These scripts are published publicly. Before a script or document leaves the
machine, run the sanitization checker from the
**orion-script-deployment-testing** skill (`scripts/check-public-safe.sh`)
and resolve every hit. No employer, business-unit, hostname, or internal
addressing data may appear in a deliverable — use `example.com`,
documentation IPs (192.0.2.x), and generic account names in all examples.

---
name: watchdog-design-patterns
description: >
  Watchdog timer design patterns and reference implementations for PowerShell
  and Python scripts — monitor-side watchdogs for SolarWinds SAM script
  monitors and client-side call watchdogs for API automation. Use this skill
  when the task is to add, implement, harden, or debug a watchdog/timeout
  mechanism: a script that hangs or times out, a SAM component stuck in
  Unknown because a check blocked, self-reporting timeouts, runspace vs
  Start-Job wrappers, SIGALRM handlers, or hard deadlines on REST/API calls.
  The orion-windows-powershell-scripting and orion-linux-python-scripting
  skills reference this one for all watchdog implementation detail.
---

# Watchdog Design Patterns (PowerShell and Python) — Public Release

*Public Release version: fully sanitized for publication — all examples use
generic hosts and documentation addressing.*

A watchdog timer guarantees that a script which hangs still ends with useful
output, under its own control, before its host environment kills it blindly.
Everything here was verified empirically against SolarWinds SAM polling
engines (Observability Self-Hosted 2026.2, Windows and Linux agents), but the
patterns apply to any headless script host that captures output and enforces
its own kill timeout.

## 1. Why a watchdog — the failure it prevents

Without one, a blocking call (DNS lookup, WMI query, dead NFS mount, hung
socket) plays out like this:

1. The script blocks. No output has been written, or ever will be.
2. The host's own timeout fires — for SAM, ~120 s of the component sitting
   in limbo — and kills the process (`TerminateProcess` / SIGKILL). The
   process gets no chance to write anything.
3. The engine captured whatever existed at the kill: usually nothing, or a
   partial stack trace.
4. The operator sees **Unknown**, a blank status message, a null statistic —
   and has no way to learn which machine ran the check, what hung, or why,
   without logging into the node.

A watchdog converts that entire failure class into a self-reported,
diagnosable result: the script exits deliberately at its own deadline with a
timeout message, a valid statistic, execution metadata, and a chosen exit
code — minutes sooner than the host's kill.

## 2. Design principles (language-independent)

- **The watchdog is the outermost layer.** Only the watchdog's own
  infrastructure (timeout constant, output helpers, timer arming) runs
  unprotected. Argument parsing, imports, sanitization, and core logic all
  run inside the protected zone — any of them can hang or throw, and an
  unprotected failure there reproduces the exact blank-Unknown outcome the
  watchdog exists to prevent.
- **The controlling context owns the output.** In wrapper patterns
  (runspace, job, subshell) the worker returns *data*; the parent — which
  can never hang on the worker thanks to a bounded wait — writes the final
  output and exit code on every path, including timeout.
- **Budget well under the host's kill.** Use **40 s** against SAM's ~120 s
  default: comfortable margin, and early enough to be useful. Report
  duration in metadata every run — a script trending toward its deadline is
  one bad network day from timing out, and the trend is only visible if
  every poll records it.
- **The timeout path honors the full output contract.** Emit execution
  metadata, a Message explaining what timed out, a Statistic (0 or a
  sentinel), and a deliberate exit code (3 Critical, or 2 per policy). If
  the component defines named statistic columns, the timeout path must emit
  **every** defined column — a poll missing a defined column is rejected
  wholesale, so a lazy timeout handler fails the very poll that most needs
  to get through.
- **So do the *degenerate* guard paths.** In a wrapper pattern the parent
  reaches exits the worker never planned — a null or malformed result
  object, a deserialization miss — and it is tempting to emit only
  `Message:`/`Statistic:` there and skip the metadata. Don't: emit the
  **complete** metadata block on those paths too. They are precisely the
  states an operator opens the script-output panel to understand, and a
  half-populated block (say, just hostname and duration) tells them nothing
  about which account or runtime was in play. Route every parent exit
  through one metadata helper rather than hand-writing blocks per path,
  which is how fields silently go missing. Know the audience, though:
  **STDERR reaches only the web console's script-output panel — it is not
  retrievable over SWIS** — so metadata serves the human operator; anything
  automation must see (e.g. the watchdog's Duration as a trend) has to
  travel as a named statistic instead.
- **Cancel the watchdog on every handled path.** A timer that outlives a
  successful run can fire late and print a second Message — and the parser
  keeps the *last* Message it sees, so stale timeout text overwrites the
  real result.

## 3. PowerShell — monitor-side patterns

### In-process runspace (preferred)

```powershell
$WatchdogTimeout = 40
$Ps = [powershell]::Create()
[void]$Ps.AddScript({ param([string[]]$RawArgs)
    try { <# parse, sanitize, core logic — return a result object #> }
    catch { <# return an error result object #> }
}).AddArgument($args)
$Handle = $Ps.BeginInvoke()
if ($Handle.AsyncWaitHandle.WaitOne($WatchdogTimeout * 1000)) {
    $Result = $Ps.EndInvoke($Handle) | Select-Object -First 1
    # parent emits output from $Result, exits $Result.ExitCode
} else {
    $Ps.Stop(); # parent emits timeout output, exit 3
}
$Ps.Dispose()
```

Host-independent (works in any PowerShell host, including agent script
hosts) and roughly **12 s faster per poll** than `Start-Job` on modest
endpoints — meaningful when the script runs every 5 minutes forever. If the
runspace is stuck in a blocking call, `Stop()` may not unstick it, but the
parent still owns the process: it writes the timeout output and exits, and
process teardown takes the stuck thread with it.

The complete monitor built on this pattern is
**`references/watchdog-monitor.ps1`**.

### Start-Job (process isolation, when you need it)

`Start-Job` runs the work in a separate child process that can be forcibly
terminated — stronger isolation, at ~12–14 s spin-up per poll. Choose it
when the check can wedge a thread in *native* code (WMI/RPC provider
deadlocks, hard-mount I/O) where a runspace `Stop()` has nothing to grab —
process termination is the one abort native code cannot ignore. It works
under the SAM agent's script host. Its traps:

- The job scope sees **no parent variables, functions, or modules**. Pass
  raw arguments explicitly — `-ArgumentList @(, $args)` (the leading comma
  keeps the array intact) — and parse them inside the block.
- `Receive-Job` **deserializes** results across the process boundary: a
  hashtable arrives as a `PSCustomObject`. Use property access and null
  checks, never hashtable methods like `.ContainsKey()` — a method call on
  the deserialized object throws, and an uncaught throw in the parent costs
  the SAM output.
- On timeout: `Stop-Job`, brief grace (~500 ms), then `Remove-Job -Force`
  — Force kills a child that ignored Stop.
- Guard against a null/malformed job result in the parent (an uncovered
  edge case in the block returns nothing) — emit a "returned no results"
  Warning rather than letting a null dereference escape.

### PowerShell 5.1 nuance

`Wait-Job`/`WaitOne` returning cleanly at the deadline has no race — a
worker finishing exactly at timeout is simply received. Prefer
`[Console]::Error.WriteLine` for the metadata block on both paths;
`Write-Error` adds formatting noise.

## 4. Python — monitor-side patterns

### SIGALRM (Unix/Linux — the agent path)

```python
WATCHDOG_TIMEOUT = 40

def _watchdog_handler(*_args):
    sam_exit_hard(f"Script execution timed out after {WATCHDOG_TIMEOUT}s", 0, 3)

if hasattr(signal, "SIGALRM"):
    signal.signal(signal.SIGALRM, _watchdog_handler)
    signal.alarm(WATCHDOG_TIMEOUT)
else:
    _timer = threading.Timer(WATCHDOG_TIMEOUT, _watchdog_handler)
    _timer.daemon = True
    _timer.start()
```

`signal.alarm` interrupts the main thread even inside most blocking
syscalls, and fires correctly under the SolarWinds Linux agent's bundled
Python — as do `multiprocessing.get_context("fork")` + `Pipe`, which the
D-state pattern below relies on; the PowerShell runspace and Start-Job
wrappers run equally well under the Windows agent. The `threading.Timer`
branch is the non-Unix fallback: it runs the handler in a *separate thread*
and cannot interrupt the blocked main thread — which is exactly why the
handler must force-terminate (next point).

**D-state caveat — when SIGALRM is not enough.** A process stuck in
*uninterruptible* disk sleep (D state) — classically a read against a dead
hard-mounted NFS export — cannot be interrupted by any signal. The SIGALRM
pattern still saves the poll (the handler runs on the main thread's next
schedulable moment and `os._exit` abandons the process), but if the hang
risk is specifically hard-mount I/O, the stronger design is **sacrificial
process isolation**: do the filesystem access in a forked child
(`multiprocessing`, explicit `fork` context), have the parent wait on a
pipe/queue with a deadline, and on timeout report the hang and exit via
`os._exit` without waiting for the wedged child. Only process abandonment
is guaranteed against D-state; the same reasoning applies to PowerShell —
a runspace `Stop()` cannot abort a thread wedged in native WMI/RPC code,
which is when `Start-Job`'s process isolation earns its spin-up cost (§3).

### The two exits

- `sam_exit(...)` → `sys.exit(code)` for every normal path. `sys.exit`
  raises `SystemExit`, so `finally` blocks run — correct for clean exits.
- `sam_exit_hard(...)` → `os._exit(code)` for the watchdog handler only.
  The main thread may be stuck; `sys.exit()` raised in a handler or timer
  thread would never unwind it. `os._exit` terminates unconditionally — and
  because it skips all cleanup, **every output write needs `flush=True`**
  or the engine captures an empty buffer despite the handler having
  "printed" the output.

### Companion traps (each produced a real blank-status component)

- **Intercept `SystemExit`**: `argparse` calls `sys.exit(2)` on bad
  arguments — indistinguishable from your own Warning exit, with only usage
  text on STDERR. Either subclass `ArgumentParser` and override `error()`
  to raise, or catch `SystemExit` and distinguish your own exits from
  library ones before re-emitting a clean message.
- **Catch `KeyboardInterrupt`** so Ctrl+C during hand-testing still shows
  what the engine would have recorded.
- **Cancel on success** — `signal.alarm(0)` / `_timer.cancel()` on every
  handled path (§2, late-fire duplicate-Message trap).
- Output-shape constants (bare vs named statistic names) must be top-level
  constants, not CLI args: the watchdog can fire before argparse runs, and
  the timeout path must emit the exact columns the component defines.

The complete monitor built on this pattern is
**`references/watchdog-monitor.py`**.

## 5. Client-side call watchdogs (API automation scripts)

The same discipline applies to scripts *calling* APIs: against a slow batch
system, a hung call with no logging is indistinguishable from normal
slowness. Two rules make them distinguishable — a **hard per-call
deadline**, and a **timestamped start/finish line per call**.

- **PowerShell 5.1**: `Invoke-RestMethod -TimeoutSec` is **not a hard
  deadline** — some request phases ignore it, which once left a deployment
  hung for minutes with zero output. The working pattern: `HttpClient` with
  a per-call `CancellationTokenSource(timeout)`, plus a second ceiling —
  `$task.Wait((timeout+5)*1000)` — so even if cancellation is swallowed
  somewhere in the stack, control returns and the script fails loudly.
- **Python**: `socket.setdefaulttimeout(60)` before creating API clients
  puts a hard floor under every socket operation, including libraries that
  expose no timeout parameter of their own.
- **Module gap to plan for**: the SwisPowerShell cmdlets expose no timeout
  parameters at all (WCF binding defaults) — adopting such a client means
  deciding where the deadline/logging layer lives before the first hang,
  not after.

## 6. Deploy-verify timing (summary)

When a watchdog-wrapped monitor goes to a live SAM engine, verify it the
fast way: on a settled agent a full deploy→verify→teardown iteration runs
in **~45–55 s** when the verify loop polls stored statistics every ~10 s
and **exits the moment data appears** — never sit out a fixed wait. A fast
`__Frequency` (verified to a 10 s floor) densifies steady-state polls but
does **not** shorten the first poll (~30–90 s settled; 7–12 min after an
agent reconnect — check agent connectivity before deploying). T+10 min is a
formal-failure bound, not a wait. The full timing model, exit-on-first-data
recipe, and the latency-calibration script live in the
**orion-script-deployment-testing** skill.

## 7. Bash and Perl equivalents (for completeness)

- **Bash**: run *all* logic in a background child subshell; a parallel
  timer subshell `sleep $TIMEOUT; kill -TERM $CHILD` enforces the deadline;
  results pass through a `mktemp` file written atomically (staging file +
  `mv`, so the parent never reads a half-written result); parent `wait`s,
  kills the timer, treats child exit >128 with an empty result file as a
  signal kill, and always writes the final output itself. `trap cleanup
  EXIT` for the temp files.
- **Perl**: `alarm(40)` + `$SIG{ALRM}` with everything in `eval {}`; the
  handler calls an output helper ending in `exit()`, which eval does *not*
  catch, so timeouts never fall into the error path; `$| = 1` at the top
  (the flush rule again); safe signals (5.8+) interrupt blocking syscalls.

## 8. Public-release gate

Deliverables built with this skill are published publicly: run the checker
from the **orion-script-deployment-testing** skill
(`scripts/check-public-safe.sh`) before anything leaves the machine, and
keep all examples on `example.com` / documentation-range addressing.

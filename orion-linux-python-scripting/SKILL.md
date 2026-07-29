---
name: orion-linux-python-scripting
description: >
  Write SolarWinds Orion SAM custom script monitors and application scripts
  for Linux/Unix targets, primarily in Python. Use this skill whenever the
  user wants to create, debug, modify, or review a Linux SAM script monitor,
  a LinuxScript component, a Python/bash/Perl monitor for Orion, or any
  Linux-side monitoring script that reports status/statistics to a polling
  engine — trigger on mentions of SAM Linux monitors, Orion Linux scripting,
  Message:/Statistic: output, agent vs agentless (SSH) monitoring, or
  exit-code status mapping, even if SolarWinds is not named explicitly.
  Pairs with orion-script-deployment-testing (getting the script into
  Orion), watchdog-design-patterns (watchdog/timeout implementation), and
  orion-windows-powershell-scripting (Windows targets).
---

# Orion Linux Python Application Scripting — Public Release

*Public Release version: fully sanitized for publication — all examples use
generic hosts and documentation addressing; the §8 gate enforces it.*

SAM script monitors run headless: the SolarWinds agent (or, agentless, an
SSH session from the poller) executes the script on a timed interval,
captures STDOUT/STDERR, records the exit code, and kills the process at its
timeout (~120 s default). Whatever output exists at exit is all the operator
will ever see. Every rule here exists so the operator always finds something
actionable in the Orion console — on every poll, on every code path.

All behavior below was verified empirically on SolarWinds Observability
Self-Hosted 2026.2 (SAM 2026.2) against an agent-managed Ubuntu node running
Python monitors. Deployment, verification timing, and template mechanics
live in the **orion-script-deployment-testing** skill — read it before
pushing anything to Orion.

## 1. Language selection on Linux

**Agent-based nodes: Python is the preferred language.** The SolarWinds
agent delivers **its own Python environment**, so Python presence is
guaranteed wherever the agent runs — no fleet survey needed. **Bash and Perl
are also thoroughly tested, fully supported options** on this path; use them
when the check is a natural fit (bash for coreutils one-liners, Perl for
text-heavy parsing on minimal hosts).

**Agentless (SSH) nodes: you cannot assume Python exists.** The poller
copies the script over SSH and runs it remotely. A Python shebang on a node
without Python exits 127 and the component shows **Down** forever with no
message — a deployment failure masquerading as an outage. Priority: bash
first (present everywhere), Perl second, Python only if confirmed on the
target.

Either way: **standard library only** on the target. Never assume pip
packages on monitored nodes. Shebangs: `#!/usr/bin/env python3`,
`#!/bin/bash`, `#!/usr/bin/perl`.

## 2. SAM output contract

Three channels, all required on **every** exit path — success, error,
sanitization rejection, watchdog timeout, unhandled exception.

**Exit code → component status** (measured; undefined codes → Unknown):

| Exit | Status | Exit | Status |
|---|---|---|---|
| 0 | Up | 3 | Critical |
| 1 | Down | 4 | Unknown |
| 2 | Warning | | |

Always `sys.exit(code)` explicitly. An unhandled traceback's exit code 1
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
- Named stats (`Statistic.MyStat: 7`) each need a matching **Numeric** column
  in the component's DynamicColumnSettings or they are silently dropped
  (factory Linux templates ship Numeric-only named columns; a String twin is
  only needed if you want `Message.MyStat:` stored). Names strictly
  `[A-Za-z0-9_]`. Column mechanics are deployment-side: see the deployment
  skill §2 (step 4) and §3.
- On the Linux agent path a successful poll's Message also lands in
  `CurrentComponentStatus.ErrorMessage` — a populated ErrorMessage is not by
  itself a failure signal here.
- Parser tolerance (measured): case-insensitive prefixes, whitespace before
  the colon, any line order; multiple explicit `Message:` lines
  newline-joined and kept; duplicate `Statistic:` — last wins. But a
  multi-line *value* inside one `Message:` loses its continuation lines —
  flatten exception/diagnostic text to a single line
  (`" ".join(text.split())`) before emitting it.
- Measured channel capacity: messages of 10,000 chars store untruncated;
  statistics accept negatives, high-precision decimals, and scientific
  notation. Message and Statistic are stored in **every** state including
  Down/Unknown — carry diagnostics into failure states. Ceiling: 70 named
  stats + the bare pair verified stored on one component (the 72-column
  import limit; see deployment skill §2).

**STDERR** — never parsed, but captured in full and shown in the component's
script output panel. Put all diagnostics, metadata, and verbose logging
here; keep STDOUT clean for the parsed lines only.

## 3. Execution environment facts

- The Linux script executor is ComponentType 21 (`LinuxScript`; in the
  template XML it appears as the string element `<Type>LinuxScript</Type>`,
  not a numeric field). Its `CommandLineToPass` setting (e.g. `python3
  ${SCRIPT}`, or `/bin/bash ${SCRIPT}` — the interpreter is chosen by
  `CommandLineToPass` regardless of the skeleton's original language)
  controls the interpreter; the `${SCRIPT}` macro materializes the
  template's ScriptBody into `ScriptDirectory` (default `/tmp`) at poll time.
- The agent's bundled Python is a real environment: `multiprocessing` fork
  contexts and `signal.alarm` both work in a deployed monitor, so the
  watchdog patterns run as written under the agent.
- **Arguments after `${SCRIPT}` arrive as real argv** on the Linux agent —
  unlike Windows, where ScriptArguments is one blob. Tokenize defensively
  anyway (re-join and re-split `sys.argv[1:]`) so the script behaves
  identically under a human tester, the Linux agent, and any path that
  delivers a single string. Values still cannot safely contain spaces.
- Any `${token}` in the script body is Orion macro territory, and the
  substitution is **textual across the entire ScriptBody — comments and
  string literals included**. Python rarely collides, but bash `${var}`
  expansions in an embedded ScriptBody do — use `$var` forms only, keep
  literal dollar-braces out of comments too, and verify with a grep before
  delivery.

## 4. Script structure

In order: capture start time (both `time.monotonic()` for duration and UTC
wall clock) → tokenize/parse arguments → **sanitize inputs** → detect
interactive vs headless (`sys.stdin.isatty() and
os.isatty(sys.stdout.fileno())`) → core logic in a top-level try → map
result to exit code. On every path — success, argument rejection,
exception — emit the `[SAM-META]` block to STDERR (Hostname, ExecutionTime
UTC, Duration, Account, RuntimeVer), then `Message:`/`Statistic:` to
STDOUT, then exit explicitly.

Python-specific traps, each of which produced a real blank-status component:

- **`flush=True` on every SAM print.** The agent can capture an empty buffer
  if the process exits before stdio flushes.
- **`getpass.getuser()`, not `os.getlogin()`.** `os.getlogin()` raises
  `OSError` under a service account with no controlling terminal — which is
  exactly the agent case. Guard it anyway and fall back to `"unknown"`.
- **Subclass `argparse.ArgumentParser` and override `error()`.** The default
  calls `sys.exit(2)` — indistinguishable from your own Warning exit — and
  prints only usage to STDERR, leaving a blank status in Orion. Raise
  instead, and convert every argument error into a clean SAM Warning with a
  Message.
- **Output-shape constants (bare vs named stat name) are top-level
  constants, not CLI args** — every path, including failures before
  argparse finishes, must emit the exact columns the component defines.
- Sanitize with allowlist regexes before any value reaches a command; use
  `subprocess.run([...], shell=False)` — never `shell=True` or `os.system`
  with external input (arguments arrive verbatim from Orion fields, and the
  script runs under a service account).

The full annotated skeleton implementing all of this is
**`references/monitor-skeleton.py`** — start from it rather than from
memory.

**Bash/Perl structural notes** (same contract, different primitives): bash —
`[ -t 0 ]` for interactivity, always quote and `--`-terminate command
arguments. Perl — `$| = 1` to unbuffer, list-form
`system('ping','-c1','--',$host)` to bypass the shell, `-t STDIN` for
interactivity.

## 5. Watchdog timers — the benefit, and when to add one

The skeleton above has no watchdog, and the try/except only protects
against *crashes*. A **hang** is a different failure class: a blocking call
(dead NFS mount, unresponsive socket, stuck subprocess) plays out as — the
script blocks with no SAM output written; the engine's ~120 s timeout fires
and SIGKILLs the process, no chance to write anything; Orion shows Unknown
with a blank message and a null statistic; the operator learns nothing. A
40-second watchdog converts that entire class into a self-reported,
diagnosable result: the script exits under its own control with a timeout
Message, a valid Statistic, metadata, and a deliberate exit code — minutes
sooner, on every poll.

A watchdog is not mandatory for every monitor. Decide by whether the core
logic can block:

- **Add one** when the check touches anything without a guaranteed internal
  timeout — network calls, NFS or remote filesystems, spawned subprocesses,
  DNS/directory lookups.
- **Reasonable to skip** for trivial local checks (`os.getloadavg()`,
  reading `/proc`) where a hang is implausible and the 120 s engine kill is
  an acceptable worst case.

When adding one, do not write watchdog code from memory — read the
**watchdog-design-patterns** skill. It carries the design principles
(outermost layer, timeout path emits every defined column,
cancel-on-success), the SIGALRM pattern (verified under the agent) with the
`os._exit` handler rule and `SystemExit` interception, the bash/Perl
equivalents, and `references/watchdog-monitor.py` — this skeleton's
watchdog-wrapped twin.

## 6. Deploy-verify timing (summary)

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

## 7. Commenting standard

Comment thoroughly, but spend the budget once:

- Comments explain **why** — the operator consequence or the trap being
  avoided ("`os._exit` because the main thread may be stuck",
  "`getpass.getuser()` because `getlogin()` raises headless"). Never narrate
  what the next line does.
- Document each helper **once, at its definition** (what it guarantees and
  when to call it). Call sites get no repeated comment blocks.
- One block comment per structural section, not per statement.
- No changelog-voice comments ("fixed", "per review", "new in v2").

## 8. Public-release gate

These scripts are published publicly. Before a script or document leaves the
machine, run the sanitization checker from the
**orion-script-deployment-testing** skill (`scripts/check-public-safe.sh`)
and resolve every hit. No employer, business-unit, hostname, or internal
addressing data may appear in a deliverable — use `example.com`,
documentation IPs (192.0.2.x), and generic account names in all examples.

## Data handling for shareable outputs (DLP by minimization)

When this skill produces artifacts that may leave their original environment
(reports, examples, documentation, published recipes): **minimize sensitive
content by substitution rather than withholding the artifact.** DLP filtering
should not win out over building a useful, shareable workflow.

- Substitute identifiers with bracketed placeholders: **[InternalOrg]** for
  the organization, **[OpCo-A]**/**[Site-A]** for business units and
  locations, **[host-1]**/**[scanner-1]** for systems, and generalized or
  RFC 5737 example addresses for real ranges.
- Name lessons and sections by their **content**, never by internal site or
  host names ("witness-blind user subnet", not "the [Site] lesson").
- After substitution, run a **leak-check sweep** (grep the org's names, sites,
  hostnames, domains, address prefixes) against the final text before
  publishing. Substitution without verification is a guess.
- Keep a full-fidelity twin locally (e.g., `NOTES-local.md`, gitignored) when
  the real identifiers matter operationally.

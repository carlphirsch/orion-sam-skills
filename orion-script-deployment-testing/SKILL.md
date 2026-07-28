---
name: orion-script-deployment-testing
description: >
  Deploy, test, and verify SolarWinds Orion SAM script monitors end-to-end
  through the SWIS API, cross-platform (Windows and Linux, agent and
  poller). Use this skill whenever the task involves getting a monitor
  script into Orion or proving it works: importing/exporting application
  templates, template XML editing, ImportTemplate/CreateApplication verbs,
  assigning apps to nodes, reading component status or statistics over
  SWIS/SWQL, debugging a component stuck in Unknown, dev/test/prod
  promotion of monitor scripts, or preparing monitor scripts for public
  release — even if the user just says "push this monitor to Orion" or
  "why isn't my SAM app reporting". For writing the monitor script itself,
  use orion-windows-powershell-scripting or orion-linux-python-scripting.
---

# Orion Script Deployment and Testing (Cross-Platform) — Public Release

*Public Release version: fully sanitized for publication — all examples use
generic hosts and documentation addressing; the §7 gate enforces it.*

Everything here was established empirically against SolarWinds Observability
Self-Hosted 2026.2 (SAM 2026.2) — agent-managed Windows and Linux (Ubuntu)
nodes plus a poller-executed agentless node — and validated end-to-end with
real deploy→poll→teardown cycles against a live environment (2026-07-14).
Version-specific quirks are flagged; when in doubt on a new environment,
re-run the control experiments in §5 rather than assume. Script authoring
rules (output contract, sanitization) live in the two companion scripting
skills; watchdog/timeout implementation lives in watchdog-design-patterns.

## 1. SWIS API contract

REST base: `https://<orion-host>:17774/SolarWinds/InformationService/v3/Json`.
Ports drift between builds — the WCF/net.tcp endpoint is 17777, and 17778 is a
different service (returns 405 to a POST here); if 17774 fails, probe the
others. **Unauthenticated requests get a normal `401` Basic challenge** on
this build (other builds have been reported to 404 instead — re-verify per
environment); both preemptive-Basic clients (orionsdk) and challenge-response
clients work. Self-signed certs are typical — pin the server PEM or disable
verification deliberately.

| Operation | Method + path | Body |
|---|---|---|
| SWQL query | POST `/Query` | `{"query":"SELECT ...","parameters":{"p":1}}` |
| Invoke verb | POST `/Invoke/<Entity>/<Verb>` | JSON **array** of positional args |
| Create row | POST `/Create/<EntityType>` | JSON object |
| Update row | POST `/<swis-uri>` | JSON object of changed properties |

Clients: Python `orionsdk.SwisClient` (REST); the SwisPowerShell module
(Gallery) for greenfield Windows work — but it speaks net.tcp 17777, exposes
no timeout parameters, and returns raw `XmlElement` verb results, so gate
adoption on 17777 reachability and add your own deadline/logging layer.

Rules that each prevented hours of lost time:

- **One SWIS action per step, hard client timeout (30–60 s), timestamped
  start/finish logging.** Against a slow batch system, a hung call with no
  logging is indistinguishable from normal slowness. Python:
  `socket.setdefaulttimeout(60)`.
- **Never serialize large script/XML strings with a reflective JSON
  serializer.** Windows PowerShell 5.1 `ConvertTo-Json` stalls for minutes
  on a 16 KB multi-line string and masquerades as "SWIS hanging" — the
  actual ImportTemplate takes ~1 s. Build bodies with plain string escaping
  (`jq -Rs`, `json.dumps`, manual `.Replace()`).
- **Verbs are not idempotent and failed verbs still mutate.** A retried
  import duplicates the template; a 400-rejected import can still leave a
  template row behind. Never auto-retry a verb — re-query server state first.
- **SWQL: no `SELECT *`, and column names differ between look-alike
  entities.** Discover columns via
  `SELECT Name, Type FROM Metadata.Property WHERE EntityName='...' AND IsNavigable=false`
  and verbs via `Metadata.Verb` / `Metadata.VerbArgument` (`Metadata.Verb`'s
  column is `Name`, not `VerbName`; only `Metadata.VerbArgument` has
  `VerbName`, and it keys on `EntityName`+`VerbName` — no `VerbID`). Known
  traps: `Orion.APM.Application` keys on `ApplicationTemplateID` (no
  `TemplateID`); `Orion.APM.ComponentStatus` (history) has no `ErrorMessage`;
  `Orion.Nodes` has no `AgentID` (join `Orion.AgentManagement.Agent.NodeID`).

## 2. Template lifecycle

There is no "create template" API. The working loop:

1. **Export a factory template as the skeleton**:
   `Invoke/Orion.APM.ApplicationTemplate/ExportTemplate [<id>]` → XML.
   **Factory templates are usually MULTI-component** ("Server Clock
   Drift (PowerShell)" = 2 components; "ClamAV" = 3, incl. Process/TCP
   monitors alongside the one LinuxScript). There is no genuinely
   "single-script" stock template — so either splice your script into every
   ScriptBody you keep, or excise the components you don't want and ship one.
   The Linux script executor is identified in the XML by
   `<Type>LinuxScript</Type>` (a string element — there is no numeric
   `<ComponentType>21</ComponentType>` field), plus `ScriptBody` /
   `CommandLineToPass` (e.g. `python3 ${SCRIPT}` or `/bin/bash ${SCRIPT}`;
   `CommandLineToPass` alone selects the interpreter regardless of the
   skeleton's original language).
2. **Edit by byte-preserving string surgery on the RAW export string,
   in-process — never round-trip through an XML library, and never even
   through a text-mode file read.** Poisons: serializers
   collapse empty Settings values to self-closed `<Value/>`, which the
   importer rejects (`<Value></Value>` imports fine); stripping inter-element
   newlines imports "successfully" with a **blank template name**; and a
   plain **text-mode file round-trip silently rewrites `\r\n`→`\n`**
   (universal-newline), breaking byte-preservation before you edit — operate
   on the `ExportTemplate` return string directly, or persist in binary. Also:
   **derive anchors from the raw bytes, not the Read-tool display** (its
   whitespace/indentation differs from the actual export). The export
   XML-escapes only `& < >`; **quotes are left literal** — never write
   `&quot;` into a spliced body. `ScriptBody`/`ScriptArguments` are not
   top-level elements; they are `<...:Key>ScriptBody</...:Key>` KeyValues
   inside each component's Settings block — and the template-level
   `<Id>`/`<Name>`/`<UniqueId>` sit **after** the components in the export,
   so don't assume header-first ordering when anchoring. Use anchored
   exact-match replaces that assert occurrence counts; parser read-only for
   well-formedness.
3. Change: template `Id`→0, `Name`, `UniqueId`→new GUID; per component
   `Id`→0, `ApplicationTemplateId`→0, `UniqueId`→new GUID, **and its
   `<Name>`** (else the component shows under the factory name in the
   console); the `ScriptBody`/`ScriptArguments` values; zero each
   DynamicColumnSettings column's `ID`/`ComponentTemplateID` (importer
   remaps). **Neutralize the skeleton's inherited column thresholds** (next).
   Cosmetics worth sweeping too: factory `__UserDescription` values and
   template/component Description text survive surgery and describe the
   *old* monitor in the console — blank them (`<Value></Value>`, never
   self-closed) or rewrite. Skeleton Numeric columns may also carry
   `<MaxValue>100</MaxValue>`; behavior for statistics above it is
   unverified, so mind it when your statistic can exceed 100.
4. **Keep `DynamicColumnSettings` — the column schemas ARE the output
   contract — but neutralize the skeleton's thresholds.** A repurposed
   Numeric column carries the factory's `WarnLevel`/`CriticalLevel`/
   `ComputeBaseline`, which evaluate against *your* statistic and compose
   worst-wins server-side: `exit 0` scripts have polled Warning and Critical
   this way, and baseline computation can fire even with "unset" levels. Set
   each kept Numeric column's levels to the sentinel
   `1.7976931348623157E+308` **and** `ComputeBaseline` to false (unless you
   want those levels), then verify **post-import** via
   `Orion.APM.DynamicEvidenceColumnSchema` — queryable columns are
   `ThresholdWarning`/`ThresholdCritical`/`ComputeBaseline` (the XML
   KeyValue names are not SWQL columns); `Type 0`=String, `Type 1`=Numeric;
   rows pair template-level (`ComponentID IS NULL`) with per-component
   children keyed by `ParentID`. `ComputeBaseline` can read back `True`
   despite the XML write — the sentinel levels are the load-bearing part.
   Pair mechanics: the String+Numeric pair named `Statistic` maps the bare
   `Message:`/`Statistic:` lines; each named stat needs its own Numeric
   column (String twin only to store its named message); unmatched output
   lines are dropped; a missing defined `Statistic` fails the poll; removing
   the block → "Script output values are not defined or improperly defined".
   Ceiling: **72 column schemas per component** — need more, split
   components, or use several components with one bare pair each.
5. **Import**: `Invoke/Orion.APM.ApplicationTemplate/ImportTemplate [<xml>]`
   → returns the new ApplicationTemplateID — use it directly; verify the
   imported Name afterward (blank-name failure mode above).
6. **Assign**: `Invoke/Orion.APM.Application/CreateApplication`
   `[nodeId, applicationTemplateId, credentialSetId, skipIfDuplicate]` →
   ApplicationID (−1 = duplicate skipped; `credentialSetId: 0` = component
   defaults, fine for LocalHost scripts; an optional 5th
   `applicationSettings: IDictionary<String,String>` exists — the 4-arg form
   works). **Fast-poll setup**: give the component `__Frequency=60` in the
   template XML at import time — edit the KeyValue in place if the skeleton
   ships one (ClamAV's LinuxScript carries `__Frequency=300`), else splice a
   new Integer KeyValue **mirroring wherever the skeleton's `__Timeout`
   sits** (per-component in LinuxScript skeletons, template-level in
   204-style Windows skeletons). Timing expectations: §4. (Setting frequency
   on an already-created app over SWIS is unreliable: the entity is
   `Orion.APM.ApplicationSettings` — plural; singular 400s — the row doesn't
   pre-exist so it must be Created with `Required=true`/`ValueType=2`, and
   in practice the first poll beats the write. Prefer the template-XML
   route.)
7. **Iterate by teardown, not edit**: `DeleteApplication` → `DeleteTemplate`
   → re-import → re-create is ~4 calls ≈ 4 s. Creating
   `Orion.APM.ComponentSetting` rows via SWIS **never propagates to
   agent-managed nodes** (the GUI triggers a job redeploy that a raw row
   insert doesn't) — teardown/recreate is the only reliable SWIS-only loop.
   (To *read* a deployed component's script body on an agent node, query
   `Orion.APM.ComponentTemplateSetting`, not `Orion.APM.ComponentSetting`
   — the latter holds only `__CredentialSetId`. And `ScriptBody` there is a
   numeric **pointer** (`ValueType=4`): dereference it into
   `Orion.APM.ExternalSetting`, whose columns are `ID`/`Setting` — the
   `Setting` column holds the actual script text.)

## 3. Cross-platform differences

| Behavior | Windows agent | Linux agent | Poller (agentless) |
|---|---|---|---|
| Arguments | ScriptArguments = ONE string; tokenize in-script | argv after `${SCRIPT}` is real argv; tokenize anyway | as Windows |
| Named-stat columns | Numeric column suffices | Numeric column suffices | untested |
| Missing `Statistic` | silent Unknown | silent Unknown | explicit "'Statistic' missing" error |
| `PollNow` verb | ignored | ignored | works |
| Up-poll `ErrorMessage` | empty (Up/Warning) — read the message from `MultipleStatisticData.StringData` instead | bare Message lands in ErrorMessage even when Up | boilerplate on Down/Unknown |
| Breadcrumb path | `C:\Users\Public\` (agent is LocalSystem; `C:\Windows\Temp` unreadable to users) | `/tmp` | poller filesystem |

Universal: `${token}` in ScriptBody is macro territory (`${IP}`,
`${CREDENTIAL}` substituted at poll time); exit codes 0/1/2/3/4 →
Up/Down/Warning/Critical/Unknown (undefined codes, including `exit -1` →
Unknown, data still stored); thresholds in column schemas evaluate
server-side and compose worst-wins with the exit code; Message and Statistic
are stored in every state including Down/Unknown; a `NaN` statistic parses
"valid" and silently kills statistic storage for the whole application.
Column `DataTransform`/`TransformExpression` **never alters stored values**
(three syntaxes tested, all stored raw) — do unit conversion in the script.
Named stats land in `Orion.APM.MultipleStatisticData` alongside a row named
`Statistic` for the bare pair, so rows there don't by themselves prove
named-stat support.

## 4. Testing and verification — Orion is a slow batch system

Test locally first: run the script interactively, confirm the labeled SAM
preview, then run it headless (`pwsh -NonInteractive`, or piped stdin) and
confirm STDOUT carries only contract lines. Then deploy and verify with the
timing model — never a fixed sleep:

| Event | Measured latency |
|---|---|
| Query / verb / create / delete | 0.3–1.4 s |
| ImportTemplate (17–20 KB) | ~1 s |
| Fixed API cost of a full deploy→teardown iteration | **~3 s** (the poll wait is everything else) |
| First poll, default cadence | up to ~6 min (Windows); **2.6–8.7 min** (Linux) |
| First poll, fast `__Frequency`, settled agent | **~30–90 s** typical (occasionally 2–5 min) |
| First poll after an agent reconnect/reboot | **7–12 min** — the tail the T+10 min cap exists for |
| Steady-state cadence | 5 min default; `__Frequency` honored **exactly** down to a verified **10 s floor** (stats stored every cycle, ≤14 ms jitter) |

> **These are SINGLE-SERVER figures. Do not carry them into a distributed
> production deployment.** Every number above was measured against an all-in-one
> Orion server with a local database and a handful of agents. Re-measured on a
> large multi-engine production estate — tens of thousands of component monitors,
> agents behind a heavily loaded master engine — **first poll after assignment
> ran 22 to 75 minutes**, and a `__Frequency` change took 21 to 34 minutes to
> reach a running agent job. That is 10–50× these figures, and it is a property
> of the *topology*, not of the deployment method: a controlled 2×2 (GUI wizard
> vs `ImportTemplate`+`CreateApplication`, across two nodes, same hour) found
> **no advantage for the API** — all four arms took the better part of an hour,
> while the API calls themselves totalled ~6 s.
>
> Two consequences for this skill's recipes:
> - **The exit-on-first-data recipe and the T+10 min "silent Unknown" bound below
>   are single-server tuning.** On a distributed estate T+10 min misclassifies
>   healthy deployments as failed. Calibrate per environment (the timing scripts
>   exist for exactly this) and treat the first deployment to a new topology as
>   the calibration run.
> - **Deployments may land on a batch cycle rather than a fixed delay.** Four
>   apps created across a 26-minute spread all surfaced within the same ~5-minute
>   window, which fits a periodic distribution cycle far better than a constant
>   per-deployment latency — and explains scattered-looking measurements.
>
> Diagnostic that separates "slow" from "broken": confirm an *already-established*
> component on the same node is still polling on cadence. If it is, the agent,
> the engine and the script are all exonerated and the wait is distribution.
> See `orion-gui-script-deployment` §4 for the full breakdown.

Two separate levers — don't conflate them: a fast `__Frequency` (placed per
§2 step 6; 10/15/30/60 all verified) gives dense *steady-state* cycles, but
**does not shorten the first poll**, which has its own distribution.
Pre-flight `Orion.AgentManagement.Agent.ConnectionStatus=1` before
deploying — a reconnecting agent puts you in the 7–12 min tail regardless
of frequency. (Measure cadence from `Orion.APM.ComponentStatus` history
rows; `MultipleStatisticData` has no TimeStamp column.)

**Recipe — exit on first data, never sit out a budget.** Poll
`MultipleStatisticData` every ~10 s from T+10 s (each check is two sub-second
queries — tight cadence is free) and **return the moment a statistic row
exists**: on a settled agent a full iteration (import→create→verify→teardown)
completes in **~45–55 s**, and a fixed 9-min wait wastes ~90% of it. The
stored stat is the *data-pipeline* verdict; status rolls up ~one poll cycle
later, so only when the thing under test is the status/threshold mapping
itself, wait one extra `__Frequency` cycle. Reserve **T+10 min** strictly for
declaring a *formal* "silent Unknown" — it is a failure bound, not a wait.
For repeated lab iterations, calibrate instead of guessing:
**`scripts/orion-timing-calibration.py`** (Python library + JSON CLI:
`derive`/`record`/`show`) — or its cross-validated twin
**`orion-timing-calibration.ps1`** for Python-less Windows boxes; both share
one cache and must stay in lockstep — keeps per-(host, node, frequency)
observed-latency history and derives the schedule — start checking at 0.5×
observed median, provisional fast-fail (iteration verdict only) at
max(2× p95, 90 s) — converging healthy-node verification to ~45–50 s and
cutting dead-node iterations from 10 min to ~3. Its clamps matter:
calibration may only *tighten* the stock schedule, or one outlier sample
(an agent reboot) poisons the cache into slowness — use the script, don't
re-derive the formulas. Log transitions, not snapshots. Run independent
experiments as **parallel apps on the same node**. Server clocks can skew
minutes from your workstation; never join cross-machine timestamps tightly.

Verification queries, cheapest first:

```sql
SELECT ComponentID, StatusDescription FROM Orion.APM.Component WHERE ApplicationID=@a
SELECT Name, NumericData, StringData FROM Orion.APM.MultipleStatisticData WHERE ComponentID=@c
SELECT Availability, ErrorMessage, TimeStamp FROM Orion.APM.CurrentComponentStatus WHERE ComponentID=@c
SELECT TOP 5 TimeStamp, Availability FROM Orion.APM.ComponentStatus WHERE ComponentID=@c ORDER BY TimeStamp DESC
```

Status semantics: Down/Warning/Critical = the script **ran** (read
ErrorMessage and stats). Unknown + populated ErrorMessage + advancing
timestamps = job runs, output/config rejected each poll. Unknown + empty
ErrorMessage + history rows every cycle = output discarded silently (e.g.
named-only stats with no columns). Unknown with no history rows = job never
built/dispatched. **Availability numeric codes: 1=Up, 2=Down, 5=Warning,
6=Critical, 0=Unknown.**

**Rollup-lag trap:** `MultipleStatisticData` is written a full poll
cycle BEFORE `StatusDescription`/`Availability` update. So right after the
first poll you can see `Unknown`/`Availability=0` while the Statistic row
already holds the value — which looks exactly like the "output discarded
silently" failure above. Before declaring silent-discard, check whether a
Statistic is already stored for the component: **Unknown WITH a stored stat is
a transient pre-rollup state that resolves to the real status one cycle
later**, not a failure. Verify on the stored statistic, not on status alone.

**STDERR is invisible to SWIS.** A script's STDERR (including the
`[SAM-META]` diagnostics block) appears only in the web console's script
output details panel — no SWIS entity returns it, and on Windows a
Warning/Up poll leaves `ErrorMessage` empty too. Automated verification can
observe only STDOUT-derived data (statistics, StringData, status); anything
you need machine-readable must ride the statistic/message channels.

## 5. Diagnosis playbook for a dead component

Ordered, cheapest first; each step is one or two SWIS calls:

1. `MultipleStatisticData` for the component — **a stored statistic means the
   pipeline works**, whatever the status says (§4 rollup lag: status can trail
   the stat by a full cycle). Only with no stored stat do you have a real
   problem — continue.
2. `StatusDescription` + `CurrentComponentStatus.ErrorMessage` — classify
   with §4 semantics.
3. `ComponentStatus` history — "never dispatched" vs "runs and gets
   discarded".
4. **Breadcrumb probe**: first script line appends a timestamp to a
   world-readable path (§3 table). File appears → script executes; problem
   is output/parsing.
5. **Control A (environment)**: assign a *factory* script template to the
   same node — if it also sits Unknown, the node/agent is the problem, not
   your template.
6. **Control B (pipeline)**: export a factory template, re-import verbatim
   (new name/GUIDs), assign — separates "my import surgery broke it" from
   "my script content broke it".
7. **Bisection ladder**: parallel apps differing by ONE feature each (bare
   vs named output, with/without watchdog, with/without stderr writes) —
   one wait window returns the whole verdict matrix.
8. `Orion.Events WHERE NetworkNode=@n` — audit trail of app/node events.

Alert-layer notes: `Orion.AlertConfigurations` supports the same
export→surgery→import loop; components alert via `Orion.APM.ComponentAlert`
(`StatisticData`, `MultiValueStatistics`, `ComponentAvailability`); deleting
and recreating an app re-fires its alerts fresh and unacknowledged; stock
SAM alerts ship with email actions — strip Email ActionDefinitions from lab
alerts before a failure-state experiment generates mail.

## 6. Promotion workflow

Scripts move `dev/` → `test/` → `prod/`, per language
(`bash/`, `perl/`, `powershell/`, `python/`):

- All new work starts in `dev/`. Promotion to `test/` requires the local
  interactive + headless runs (§4) and a manual review. Promotion to `prod/`
  requires a verified deployment: component reached its expected state on a
  real poll cycle with statistics stored (§4 queries as evidence).
- Never write directly to `prod/`; never edit in place — promote by copy so
  each stage stays reproducible.
- Credentials never live in scripts at any stage: environment variables or
  env-files outside the repo (`ORION_HOST`/`ORION_USER`/`ORION_PASS`
  convention), or the Orion credential store for monitor-side secrets.

## 7. Public-release data check (mandatory gate)

Deliverables produced with these skills are published publicly. Nothing may
identify the operating organization: no company or business-unit names, no
internal hostnames/FQDNs or IP addressing, no service-account or personnel
names, no ticket/system identifiers. Examples use `example.com`,
documentation IPs (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24), and
generic account names.

**Before any script, skill, or document is committed to a public repo or
otherwise leaves the machine, run:**

```bash
scripts/check-public-safe.sh <file-or-dir> [...]
```

The checker hard-fails on any term in a locally maintained private wordlist
(`~/.claude/private/public-release-wordlist.txt` by default — override with
`PUBLIC_SAFE_WORDLIST`; the wordlist itself is private data and must never
be committed anywhere), and warns on heuristic patterns: non-documentation
IP literals, real-looking FQDNs, email addresses, and UNC paths. A missing
wordlist is a **hard failure**, not a pass — the gate fails closed. Resolve
every hit and re-run until clean; treat warnings as review items, not noise.

This gate is mandatory for every deliverable until the skill owner
explicitly removes or modifies it.

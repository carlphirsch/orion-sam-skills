---
name: orion-gui-script-deployment
description: >
  Deploy, edit and verify SolarWinds Orion SAM script monitors through the Orion
  web GUI instead of the SWIS write API — the COPY-a-skeleton recipe, why a
  "Create a New Template" script component can never poll, the script-output
  column model and its GUI limits, the tens-of-minutes agent job-config lag that
  makes new monitors sit grey, and an ordered diagnosis ladder. Use this
  skill whenever a SAM script monitor is being created, edited, assigned or
  debugged through the Orion web console rather than via
  ImportTemplate/CreateApplication — including when a component sits
  grey/Unknown after a GUI assignment, when a script test returns "Unknown"
  despite correct Message/Statistic output, or when SWIS write verbs are
  disallowed by policy. If the work is being done with SWIS write verbs, use
  orion-script-deployment-testing instead. For authoring the script itself use
  orion-windows-powershell-scripting or orion-linux-python-scripting, and
  watchdog-design-patterns for timeout structure.
---

# Deploying SAM Script Monitors Through the Orion GUI — Public Release

*Public Release version: fully sanitized for publication — generic hosts,
documentation addressing, no organizational data; the §10 gate enforces it.*

Established empirically on SolarWinds Observability Self-Hosted 2026.2.1
(Advanced Enterprise Scale), Windows PowerShell script monitors on
agent-managed nodes of agent `Type=2` (**Remote Collector**) in a large
multi-engine production deployment, 2026-07-27. Expect a slow console — and see
§4 before trusting any timing figure from a lab.

**Which skill to use for a grey component.** Three skills mention "component
stuck in Unknown". Pick by *how the monitor was created*: if it was created or
last edited in the **web console**, use this one — the dominant cause here
(missing script-output columns) is invisible from the API side and is not
covered elsewhere. If it was deployed by SWIS verbs, use
`orion-script-deployment-testing`. If you don't know, the §7 ladder identifies
it in two queries.

**Scope note.** This path exists when SWIS *write* verbs are unavailable or
disallowed. **Read-only SWQL is still assumed and is the primary verification
tool** — reads cannot mutate anything. §6 gives the mechanism. A GUI-only
fallback is noted there.

## 1. The one thing that will waste your afternoon

**A script component created by "Create a New Template" has ZERO script-output
columns, and it can never store a statistic.** Measured symptom set:

- **The decisive evidence is the server's own error string.** Once the job
  finally deploys, `Orion.APM.CurrentComponentStatus.ErrorMessage` reads exactly:
  **`Script output values are not defined or improperly defined.`**
  If you see that, stop looking at the script — the component has no columns.
- The component then polls forever without ever storing anything: `Unknown`,
  `Availability=0`, `ComponentStatus` history rows **advancing every cycle**, and
  **zero `MultipleStatisticData` rows**. Observed 13 consecutive 5-minute polls
  in this state.
- **Before** the job deploys (which can take an hour — §4) the same component
  shows `Unknown` with an **empty** ErrorMessage and **zero** history rows. That
  earlier, emptier symptom set is indistinguishable from "still propagating", so
  do not diagnose from it — wait for history rows or use the TEST below.
- The template editor's TEST reports `Test failed with "Unknown" status` while
  displaying **completely correct** `Message:` / `Statistic:` output from the
  real target node. **Correct output plus Unknown status means missing columns,
  not a broken script** — and TEST gives you this in ~50 s instead of an hour.

The GUI offers an operator **no way to add a column**. The editor exists in the
DOM only as a `display:none` prototype row
(`#column-edit-container-template-<id>`, cloned into `.dynamic-settings` rows);
there is no "add" control anywhere on the page.

**So: never build a GUI script monitor from "Create a New Template".**

## 2. The column model

Script-output columns live in `Orion.APM.DynamicEvidenceColumnSchema` in two
layers:

| Layer | `ComponentTemplateID` | `ComponentID` |
|---|---|---|
| Template-level (the contract) | set | **NULL** |
| Per-assigned-component clone | **also set** | the component id |

Orion clones the template rows onto each component at assignment, and **the
clones keep the `ComponentTemplateID` link**. Two consequences:

- Filtering only on `ComponentID` misses every template-level row. That mistake
  was made here and produced a confidently wrong "no columns" diagnosis.
- Filtering only on `ComponentTemplateID` returns **both layers**, so a
  4-row result for a one-statistic monitor is correct, not duplication. Add
  `ComponentID IS NULL` to see just the contract. (Estate-wide: 2395 rows are
  template-layer, 685 are clones.)

`Type 0` = String (stores `Message.<name>`), `Type 1` = Numeric (stores
`Statistic.<name>` and carries the threshold — all non-sentinel thresholds in
this estate sit on Type 1 rows). The group named `Statistic` maps the bare
`Message:`/`Statistic:` lines.

**A pair is the common case, not a rule.** Estate-wide at the template layer:
961 named groups are paired, **440 are Numeric-only**, and **29 are String-only**
(all named `Statistic`, all on Linux-script templates) — so "a named stat needs
at least its Numeric row" holds for the Windows path in practice but has real
counterexamples. Numeric-only is the normal shape for a stat you only want
charted; add the String twin only to store a per-stat message.

### GUI capability boundary — this decides your whole approach

| Action | GUI | Notes |
|---|---|---|
| Delete a column | ✅ | Per-block **Delete**; in-page confirm warns it deletes historical data |
| Disable / Enable | ✅ | |
| Relabel | ✅ | **Display Name** only |
| Thresholds, baseline, Convert Value | ✅ | |
| **Add a column** | ❌ | No control exists |
| **Rename a column's `Unique ID`** | ❌ | Read-only text — and it is the key the parser matches output against |

**Decision rule.** You can only ever *subtract* columns in the GUI, so:

- **Your script's stat names can be a subset of some existing template's names →
  use COPY (§3).** Simplest, no XML.
- **You need named stats no existing template has → use
  Manage Templates → `»` → Import/Export → Import**, with template XML you
  author. The GUI's own importer accepts the same DataContract XML as the API's
  `ImportTemplate`, so the XML-surgery rules in
  `orion-script-deployment-testing` §2 apply unchanged. This is the only GUI-legal
  route to arbitrary column names.
- **Only the bare pair is needed → COPY anything with a `Statistic` pair** and
  delete the rest. This is the cheapest working monitor.

## 3. The COPY recipe

1. **Find a skeleton** — a single-component template of the right script type
   whose component already carries the pairs you want. Use the discovery query
   in §6; do not click through hundreds of templates.
2. **Copy it.** Manage Templates → search → tick the row → overflow **`»` →
   Copy** → creates "Copy of <name>" with **all column rows cloned**. If the
   source is a live monitor, confirm its assigned-node count is unchanged
   afterwards — you must not edit the original.
3. **Edit the copy** (`EditTemplate.aspx?id=<new>`): rename; clear the inherited
   Tags and Description; replace **Script Body** and **Script Arguments**;
   **Delete** unwanted script-output columns.
   **Naming:** template and application names surface estate-wide — in audit
   trails, alerts, and reports. Use a neutral functional name plus a version —
   `Disk Latency Probe v1` — so any operator can tell at a glance what it does
   and which revision is deployed. Keep the Description accurate, and mark
   test/lab artifacts as temporary so they get cleaned up rather than
   inherited. A COPY inherits the *source* monitor's Description and Tags, so
   sweep both or your new monitor will describe someone else's.
4. **Neutralize inherited thresholds — do not skip this.** COPY clones the
   skeleton's `Warning`/`Critical` levels and `ComputeBaseline` onto columns that
   now carry *your* statistic, and they compose worst-wins server-side, so an
   `exit 0` script can poll Warning or Critical. In each surviving Script Output
   block, clear the Warning/Critical values (or set them to the disable
   sentinel — full double precision `1.7976931348623157E+308`; SWQL *displays*
   it rounded as `1.79769313486232E+308`, which is the same value) and uncheck
   "Use thresholds calculated from baseline data". Verify post-save via
   `ThresholdWarning`/`ThresholdCritical`/`ComputeBaseline` in §6.
   **Read the sentinel as "threshold disabled", not "healthy default".** Roughly
   two-thirds of estate rows carry it, but 247 rows carry deliberate real
   thresholds on live monitors — so seeing a real number is not evidence of a
   mistake, and seeing the sentinel is not evidence anyone checked.
5. **Submit**, then verify over SWQL that the name, surviving columns, thresholds
   and `ScriptArguments` all persisted before going further.
6. **Assign**: Manage Templates → tick → **ASSIGN TO NODE**. Three steps:
   1. *Select Nodes* — use **SEARCH FOR**, then tick the **group** checkbox and
      the green **→** arrow to move it to Selected Nodes; **NEXT**.
   2. *Select Credentials & Test* — for an agent node keep the default
      **Inherit credentials from node**, which its own tips state means the
      **Local System** account. Run **TEST** here: with columns present it
      returns `finished successfully with 'Up' status`. **Always do this — it is
      the cheapest confirmation that the output contract is right, and it costs
      ~50 s instead of a 20-minute wait.**
   3. Click **ASSIGN APPLICATION MONITORS** → *Finish* confirms
      "1 assigned application has been created".
7. **Then wait out §4.** Verify asynchronously; never block on it.
8. Delete any orphan "New Template (1)" rows you created (§8).

## 4. Timing: job-config lag is a TOPOLOGY property, not a GUI property

**Do not attribute this lag to the GUI — this was measured, not assumed.** A 2×2
was run on one estate: the same template deployed by **GUI wizard** and by
**`ImportTemplate` + `CreateApplication`**, to the same two Remote Collector
nodes, within the same hour. At 21.7 minutes *both API arms were still dark*,
alongside both GUI arms — against a documented "under 5 minutes" on a plain
agent in an all-in-one lab. The API deployment calls themselves were trivially
fast (ExportTemplate 1.6 s, ImportTemplate ~1 s, CreateApplication ~1.5-2.5 s —
about **6 s** of API work versus ~10 min of console clicking), so the API is
worth having for *effort*, but **it buys nothing on poll latency.** The agent
cannot tell how a job config arrived; what drives the delay is how many hops the
config makes and how loaded they are.

**Isolate the slow stage before blaming anything.** In the same window, an
already-established component on one of those very nodes polled like a metronome
— 22:33:57, 22:34:57, 22:35:57, exact 60 s. Everything is fast *except*
distributing a new or changed job:

| Stage | Measured |
|---|---|
| Script execution on the target (wizard TEST) | ~50 s |
| Agent cold start after a reboot → first poll | 56 s |
| Established job cadence | exact, <100 ms drift |
| API deployment calls | ~6 s total |
| **New/changed job config reaching the agent** | **22 to 58+ min** |

So this is one pipeline stage — server → master engine → collector engine →
agent. If you are waiting, confirm an *existing* component on the same node is
still polling normally; if it is, the agent, the engine and the script are all
exonerated and no amount of redeploying will help.

**Topology is the variable that matters.** The figures below come from a large
multi-engine production deployment (tens of thousands of component monitors), on
nodes that sit unusually deep in the topology: agents of
`Orion.AgentManagement.Agent.Type = 2` (**Remote Collector** — a rare type,
single-digit counts among four figures of agents) which are *themselves* polling
engines, appearing in `Orion.Engines` with a `MasterEngineID` pointing at the
deployment's busiest engine — roughly six times the element count of the next
busiest. Config therefore traverses main server → master engine →
remote-collector engine → agent, three hops with contention at the middle one.

By contrast a plain `Type=0` agent on a lightly loaded engine, or a single-server
all-in-one lab with a local database, has been seen to go green in **under
5 minutes**. The gap between those two is the whole story: **this is a
distributed-system distance problem, not an Orion-is-slow problem.**

So: **measure the lag on the topology you are actually deploying to, and never
quote these numbers as "how long Orion takes".** Before predicting anything,
check `Orion.AgentManagement.Agent.Type` and whether the node itself appears in
`Orion.Engines` with a `MasterEngineID`; then compare the master engine's
`Elements` against its peers.

With that framing, here is what was measured on the deep-topology node.

| Event | Measured |
|---|---|
| Template/app save, column edits | land in the DB in ~1 s |
| Wizard TEST (runs the script on the real target) | ~50 s |
| **First poll after assignment** | **~22 min** on one app; **58 min** on another (created 18:16:50Z, first history row 19:14:54Z) |
| **A `__Frequency` change reaching the running agent job** | **21 min 38 s** on one change; **34 min 6 s** on another (submit 20:34:01Z → new cadence 21:08:07Z) |
| Steady-state cadence once running | exact — 12+ consecutive polls at 60 s, ~90 ms total drift |
| **Recovery after a node reboot** | **56 s** — boot 21:34:00Z, first SAM poll 21:34:56Z, cadence and config intact |

**The lag is in *delivering a change*, not in the agent.** That 56 s recovery is
the key contrast: a cold agent starts polling its existing job inside a minute,
while a *changed* config takes tens of minutes to reach it. So the bottleneck is
the server→engine→collector→agent distribution path, not agent startup, and not
script execution (the wizard TEST runs the real script on the real node in
~50 s). Design around the distribution delay; nothing else here is slow.

So the agent's job config lags the database by **tens of minutes, and the delay
is highly variable — 22, 34 and 58 minutes all observed on the same node.** The
DB updates instantly every time; only dispatch lags. **Do not treat ~20 min as a
ceiling, and do not quote a single figure as "the" refresh period.**

**Job-restart signature.** A config reload shows up as a *phase re-anchor*: one
odd-length gap, then the schedule resumes on a new phase (e.g. `:56.6x` →
`:42.2x` via a 105.6 s gap; later `:42.2x` → `:07.9x` via an 86 s gap). Watch for
that rather than only watching the interval — but note a re-anchor does **not**
guarantee new config arrived: one observed re-anchor kept the old 120 s cadence
while the DB already said 60.

**No GUI lever found so far accelerates it.** Tested against a pending
`__Frequency` change (120→60) on a live, polling component, watching for the new
cadence to appear early:

| Lever | Result |
|---|---|
| Node **Poll Now** (node details → Management) | **Null.** No off-cadence poll, no config pickup. It is node-scoped and does not reach an agent-scheduled SAM job |
| App rename + Submit | **Null** |
| Template rename + Submit | **Null** |
| Component **Disable** + Submit | **Inconclusive — the disable did not persist.** Reopening the editor showed `Enabled` and `Orion.APM.Component.Disabled` stayed `False`, so the toolbar toggle plus Submit did not take. Retest before trusting either way |
| Unmanage → Remanage | Not yet tested |
| Node **Reboot** (node details → Management → Reboot) | **Works, but is queued and hugely delayed — do not read silence as failure.** Three attempts appeared to do nothing for over half an hour: `LastBoot` unchanged, `SystemUpTime` climbing, SAM polls unbroken, and **zero events logged**. I wrongly concluded the action was a no-op on agent nodes. It then executed: reboot at 21:34:00Z, roughly **35 minutes** after the command, with events type 14 / 5000 appearing normally. Same message-bus latency as everything else here. **Treat the success banner as "command queued", verify against `LastBoot`, and give it tens of minutes before calling it failed.** |
| Agent service restart | Untested as a *lever*, but see the reboot recovery figure below — restart is fast on the agent side |

One real signal did appear: **~3 min 41 s after the frequency Submit the poll
schedule re-anchored** — phase shifted from `:56.6x` to `:42.2x` with a single
105.6 s gap, then resumed exact 120 s. That is a job-restart signature, but it
came back on the **old** cadence, and three later Submits produced no further
re-anchor. So a Submit can bounce the job quickly *without* delivering the new
config. That also explains the 239 s first poll I originally misread as the
override "working".

Do not tell anyone an override forces a redeploy. Remaining candidates are in §9.

Practical consequences:

- **Do not wait to find out whether it works — TEST instead.** The assign-wizard
  TEST settles the output contract in ~50 s. Waiting on a poll to learn what a
  50-second test would tell you is the single biggest time sink on this path.
- Budget **up to an hour** for first data, and **never** read pre-dispatch
  silence as failure. A component with zero history rows is uninformative, not
  broken. Only `ErrorMessage` (§1) or a TEST result is diagnostic.
- **Never block on the wait.** Poll asynchronously with a bounded, backgrounded
  watcher and a hard cap. A 5-minute question must not consume half an hour.
- **Make watchers report observations, not conclusions.** A watcher here was
  written to break on "cadence changed" and print a hardcoded line asserting
  *why* — it fired on the natural refresh and confidently claimed a reboot had
  caused it, when the reboot had never happened. Log the timestamps and gaps;
  derive causation afterwards, against independent evidence (`LastBoot`, event
  rows), never inside the break condition.
- **Better: let the monitor measure itself.** Deploy a watchdog-wrapped probe
  whose statistic is the observed interval since its own previous run (breadcrumb
  under `C:\Users\Public\` — the agent is LocalSystem and its
  `C:\Windows\Temp` writes are unreadable to users). Then the console alone shows
  real cadence and when a frequency change landed, with no external polling. See
  `watchdog-design-patterns` for the runspace wrapper.
- **GUI enforces a 60-second minimum polling frequency.** Less produces
  `FAILED TO SAVE — Polling Frequency: Please enter a value greater than or equal
  to 60`. The template-XML path reaches a verified 10 s floor, so **sub-60 s
  polling is unreachable through the GUI** — size GUI-deployed sentinels
  accordingly.
- **Rollup lag looks like failure.** The statistic row is written a full cycle
  before `StatusDescription` updates, so `Unknown` *with a stored statistic* is
  transient pre-rollup, not a fault. **Verify on the stored statistic, never on
  status alone.**

## 5. Where things live in the GUI

- SAM settings: `/Orion/APM/Admin/Default.aspx`
- Templates list: `/Orion/APM/Admin/ApplicationTemplates.aspx`
- Template editor: `/Orion/APM/Admin/Edit/EditTemplate.aspx?id=<templateId>`
- Assigned-app editor: `/Orion/APM/Admin/Edit/EditApplication.aspx?id=<appId>` —
  this is where **Polling Frequency / Polling Timeout** sit, each with an
  **OVERRIDE TEMPLATE** button on the right of its row; clicking it turns the
  value into an editable field and the button becomes **INHERIT FROM TEMPLATE**.
  Per-component settings get their own OVERRIDE TEMPLATE buttons further down.
- Guessing `/Orion/APM/Admin/Templates/Default.aspx` returns a platform error.

## 6. Verification with read-only SWQL

**Mechanism.** POST SWQL to
`https://<orion-host>:17774/SolarWinds/InformationService/v3/Json/Query` with
body `{"query":"SELECT ..."}` and **preemptive** Basic auth (this build does not
reliably challenge, so clients that wait for a 401 hang). TLS 1.2 must be
asserted on PowerShell 5.1. `orion-script-deployment-testing` §1 documents the
full API contract, client options (`orionsdk`'s `SwisClient`, SwisPowerShell),
and the hard-timeout/logging rules any query wrapper should follow. **GUI-only
fallback** if no SWQL access exists at all: the component's own
**Script Output** details panel plus the assign-wizard TEST result, and the
per-block column list in the template editor — enough for §7 steps 1-3, but you
lose history-row evidence.

```sql
-- SKELETON DISCOVERY: type-45 components and their column counts.
-- SWQL rejects scalar subqueries in a SELECT list - pull these two sets and
-- join client-side, counting rows per ComponentTemplateID.
SELECT ID, Name, ApplicationTemplateID FROM Orion.APM.ComponentTemplate WHERE ComponentType=45
SELECT ComponentTemplateID, Name, Type FROM Orion.APM.DynamicEvidenceColumnSchema
SELECT ApplicationTemplateID, Name FROM Orion.APM.ApplicationTemplate
-- prefer a template whose ApplicationTemplateID appears exactly once in
-- ComponentTemplate (single-component) and whose component has the pairs wanted

-- THE OUTPUT CONTRACT. Clones keep ComponentTemplateID, so this returns BOTH
-- layers; add "AND ComponentID IS NULL" for just the template contract.
SELECT ColumnSchemaID, ComponentTemplateID, ComponentID, Name, Type,
       ThresholdWarning, ThresholdCritical, ComputeBaseline
  FROM Orion.APM.DynamicEvidenceColumnSchema WHERE ComponentTemplateID=@ct

-- START HERE ON ANY GREY COMPONENT - usually decisive in one query
SELECT Availability, ErrorCode, ErrorMessage FROM Orion.APM.CurrentComponentStatus WHERE ComponentID=@c
--   ErrorCode 51 / "Script output values are not defined or improperly defined." = no columns

-- DID IT POLL?
SELECT Name, NumericData, StringData FROM Orion.APM.MultipleStatisticData WHERE ComponentID=@c
SELECT TOP 10 TimeStamp, Availability FROM Orion.APM.ComponentStatus WHERE ComponentID=@c ORDER BY TimeStamp DESC
SELECT Key, Value FROM Orion.APM.ApplicationSettings WHERE ApplicationID=@a   -- __Frequency override
```

`ComponentType` **45** = Windows PowerShell Monitor, **21** = Linux script.
No `ComponentType` lookup entity is exposed over SWIS, so these are inferred
from template names and settings (type 45 carries `WrmPort`/`WrmUrlPrefix`/
`ExecutionMode`), not read from a name table.
Availability: 1 Up, 2 Down, 5 Warning, 6 Critical, 0 Unknown. Discover unknown
entity columns with
`SELECT Name, Type FROM Metadata.Property WHERE EntityName='...' AND IsNavigable=false`.
**Beware local-vs-UTC when differencing timestamps** — SWIS returns UTC, and
comparing it against a locally-parsed literal produced a 4-hour error here.

## 7. Diagnosis ladder (cheapest first)

1. **`CurrentComponentStatus.ErrorMessage`** — one query, and it is usually
   decisive. `Script output values are not defined or improperly defined.` →
   the component has **no columns** (§1); rebuild by COPY or Import. Any other
   text → the script ran and Orion is telling you what went wrong. Empty →
   continue.
2. **Stored statistic?** `MultipleStatisticData` for the component. Present →
   the pipeline works; if status still says Unknown that is rollup lag (§4).
   Stop.
3. **Columns defined?** `DynamicEvidenceColumnSchema` on **both** keys (§6).
   Zero rows → §1, regardless of what anything else says. This is the most
   common cause and it also tells you the monitor was GUI-created.
4. **History rows?** `ComponentStatus` count.
   - Zero → the job has not been dispatched yet. **This is not evidence of
     anything** (§4: 22-58 min observed). Do not "fix" it; run a TEST if you
     need an answer now.
   - Advancing every cycle but no stat → output rejected each poll. Either no
     columns (step 1's error string) or a **defined column is not being
     emitted** — compare the component's column names against the names the
     script actually prints; every defined column must appear on every exit path.
5. **Status Down/Warning/Critical** → the script *ran*; read
   `CurrentComponentStatus.ErrorMessage` and the Message. If exit 0 yet
   Warning/Critical, suspect inherited column thresholds (§3 step 4), not the
   script.
6. **Run the assign-wizard or template TEST** against the node. Correct output +
   `Unknown` → missing columns (§1). Error text → a real script or credential
   fault. Nothing at all → node/agent reachability, not this template.
7. Check the agent is Connected (Manage Agents) before blaming the template.

## 8. Driving the console (it will fight you)

Heavy console; on a memory-constrained workstation Chrome renderers wedge and
can be killed outright, losing the whole tab group.

- **Never expand a vendor group in a node tree.** Expanding "Windows" on a
  1,400-agent estate wedged the renderer ~30 s and later crashed the tab. In the
  assign wizard, search first and tick the **group** checkbox — it selects the
  filtered node without expanding anything.
- CDP screenshot capture (`Page.captureScreenshot`) times out often; 20-30 s
  waits usually recover. Prefer DOM inspection and text extraction over
  screenshots wherever a check can be made without rendering.
- **Clicks on elements below the viewport are silently swallowed.** The template
  editor's `#submitBtn` / `#applyBtn` sit at y≈644 on a 607 px viewport. Scroll
  to the bottom and confirm position before clicking.
- **But check for validation before re-clicking.** A `FAILED TO SAVE` dialog plus
  a red field message is a *rejected value*, not a lost click. Screenshot first;
  the two look identical from the outside (nothing happened).
- Layout shifts between capture and click, so blind batched coordinate clicks
  fail. Verify between steps and target elements by selector/reference, not
  coordinates.
- Confirm prompts are in-page dialogs, not native `confirm()`, so they do not
  freeze CDP.
- **Opening "Create a New Template" persists an orphan template row
  immediately**, named "New Template (1)", before any save. Abandoning the editor
  leaves it behind. Clean it up.

## 9. Open questions worth closing

1. Is the ~21 minute refresh a fixed agent config-poll period, and is it tunable
   (agent setting, or `SolarWindsAgent64` service restart)? Biggest possible win.
2. Do **Poll Now**, component disable→enable, or unmanage→remanage reach an
   agent-scheduled job? (`PollNow` over SWIS is known to be ignored on agent
   jobs.) These are the untested candidate accelerators.
3. Does **any** app-level Submit trigger a redeploy, or nothing? Needs a fresh
   app plus a control that changes no setting.
4. Does a template-level edit propagate to already-assigned apps as the UI
   claims ("all of the assigned applications ... will inherit the change"), and
   on what latency? Until answered, prefer fixing the template then reassigning
   for a correctness-critical change.

## 10. Public-release gate

Deliverables built with this skill are published publicly: run the checker
from the **orion-script-deployment-testing** skill
(`scripts/check-public-safe.sh`) before this file or anything derived from it
leaves the machine, and keep all examples on `example.com` /
documentation-range addressing. Resolve every hit; the gate fails closed.

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

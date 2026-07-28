"""orion_timing_calibration.py — observed-latency calibration for SAM verify loops.

Problem this solves: the deployment-testing recipe uses fixed, worst-case
verification timing (first check T+90s with a fast __Frequency, formal
silent-Unknown verdict only after T+10min). In a lab where the same node is
exercised repeatedly, first-poll latency is an observable property of the
environment. This module keeps a small per-(host, node, frequency) history of
observed first-poll latencies and derives a calibrated check schedule from it:

  - start checking at 0.5 x observed median (never below MIN_FIRST_CHECK)
  - poll every POLL_INTERVAL seconds
  - PROVISIONAL fast-fail (iteration verdict only) at max(2 x observed p95,
    PROVISIONAL_FLOOR seconds)
  - the 10-minute hard cap is retained unchanged for FORMAL failure verdicts;
    a provisional fail only means "stop burning lab time on this iteration",
    never "the component is broken".

Cache: a JSON file. Canonical location ~/.claude/orion-timing.json (override
with ORION_TIMING_CACHE env var, or pass path= explicitly). Keys are
"<host>|<nodeId>|<frequency>" because latency is a property of the polling
engine + target node + configured frequency, not of any one template.

Intended use inside a verify script:

    import orion_timing_calibration as cal
    sched = cal.derive_schedule(host, node_id, frequency)
    # ... sleep sched["first_check"], poll every sched["poll_interval"],
    #     provisional-fail at sched["provisional_fail"] ...
    cal.record(host, node_id, frequency, observed_latency_seconds)

Design notes / edge cases (deliberate):
  - Empty cache (or no fresh samples for the key) -> the stock recipe
    schedule, flagged source="cold". The mechanism degrades to exactly the
    documented conservative behavior; it never guesses.
  - Stale cache: samples older than STALE_SECONDS (default 30 days) are
    ignored at derive time (kept on disk for history). An environment left
    alone for a month re-earns its calibration.
  - Environment change: record() is called on every run, including cold
    ones, so drift (SAM upgrade, agent move, loaded poller) feeds back in
    within a few runs; p95 over the window absorbs one-off spikes. If a
    calibrated run blows through its provisional bound, the caller should
    fall back to the stock schedule/cap for that run and still record the
    eventual latency — a slow truth is more valuable than a fast guess.
  - Small samples: p95 uses the nearest-rank method, so with n=1 the single
    sample is both median and p95. That is intentionally aggressive on the
    first calibrated run and is why the provisional bound has a hard floor
    (PROVISIONAL_FLOOR) and a 2x multiplier on p95, not on the median.
  - Writes are atomic (temp file + os.replace) so a crashed run cannot
    truncate the cache.
"""

import json
import math
import os
import time

DEFAULT_CACHE = os.path.expanduser("~/.claude/orion-timing.json")
CACHE_ENV = "ORION_TIMING_CACHE"

STALE_SECONDS = 30 * 86400      # samples older than this are ignored
MIN_FIRST_CHECK = 10            # never start checking earlier than this
POLL_INTERVAL = 10              # calibration-mode poll cadence
PROVISIONAL_FLOOR = 90          # provisional fast-fail never earlier than this
HARD_CAP = 600                  # formal silent-Unknown verdict cap (unchanged)

# Stock recipe values (deployment-testing skill section 4), used cold:
COLD_FIRST_CHECK_FAST_FREQ = 90     # when a fast __Frequency was set
COLD_FIRST_CHECK_DEFAULT = 150      # T+2.5 min otherwise


def cache_path(path=None):
    return path or os.environ.get(CACHE_ENV) or DEFAULT_CACHE


def _key(host, node_id, frequency):
    return "%s|%s|%s" % (host, int(node_id), int(frequency))


def load(path=None):
    p = cache_path(path)
    if not os.path.exists(p):
        return {}
    # utf-8-sig tolerates a BOM (a cache once touched by Windows PowerShell
    # 5.1's Set-Content could carry one) and reads plain UTF-8 identically.
    with open(p, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def _save(data, path=None):
    p = cache_path(path)
    d = os.path.dirname(p)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, p)


def record(host, node_id, frequency, latency_s, path=None, meta=None):
    """Append one observed first-poll latency sample and persist."""
    data = load(path)
    entry = {
        "ts": time.time(),
        "ts_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "node_id": int(node_id),
        "frequency": int(frequency),
        "latency_s": round(float(latency_s), 1),
    }
    if meta:
        entry["meta"] = meta
    data.setdefault(_key(host, node_id, frequency), []).append(entry)
    _save(data, path)
    return entry


def _p95_nearest_rank(sorted_vals):
    n = len(sorted_vals)
    rank = max(1, math.ceil(0.95 * n))
    return sorted_vals[rank - 1]


def derive_schedule(host, node_id, frequency, path=None, now=None):
    """Return the check schedule for this (host, node, frequency).

    Result dict always contains: source ("cold"|"calibrated"), first_check,
    poll_interval, provisional_fail, hard_cap. Calibrated results add
    samples, median, p95.
    """
    now = now if now is not None else time.time()
    data = load(path)
    records = data.get(_key(host, node_id, frequency), [])
    fresh = [r["latency_s"] for r in records if now - r["ts"] <= STALE_SECONDS]

    if not fresh:
        first_check = (COLD_FIRST_CHECK_FAST_FREQ if int(frequency) <= 60
                       else COLD_FIRST_CHECK_DEFAULT)
        return {
            "source": "cold",
            "samples": 0,
            "stale_ignored": len(records),
            "first_check": first_check,
            "poll_interval": POLL_INTERVAL,
            "provisional_fail": HARD_CAP,   # cold runs get no fast-fail
            "hard_cap": HARD_CAP,
        }

    vals = sorted(fresh)
    n = len(vals)
    median = (vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2.0)
    p95 = _p95_nearest_rank(vals)
    # Calibration may only TIGHTEN the stock schedule, never loosen it:
    # - never start checking later than the stock first check (a slow
    #   observed median must not delay detection of a fast poll), and
    # - a provisional bound at or past the hard cap is meaningless, so
    #   clamp it there; it stays a fast-*fail* only when it is genuinely
    #   earlier than the formal verdict cap.
    cold_first = (COLD_FIRST_CHECK_FAST_FREQ if int(frequency) <= 60
                  else COLD_FIRST_CHECK_DEFAULT)
    return {
        "source": "calibrated",
        "samples": n,
        "stale_ignored": len(records) - n,
        "median": median,
        "p95": p95,
        "first_check": max(MIN_FIRST_CHECK, min(0.5 * median, cold_first)),
        "poll_interval": POLL_INTERVAL,
        "provisional_fail": min(max(2.0 * p95, PROVISIONAL_FLOOR), HARD_CAP),
        "hard_cap": HARD_CAP,
    }


# ---------------------------------------------------------------------------
# CLI — so bash/PowerShell verify loops can use the cache without writing
# Python. Output is JSON on stdout (jq-friendly); exit 0 on success.
#
#   orion-timing-calibration.py derive <host> <nodeId> <frequency>
#   orion-timing-calibration.py record <host> <nodeId> <frequency> <latency_s>
#   orion-timing-calibration.py show  [<host> <nodeId> <frequency>]
#
# Typical bash loop:
#   sched=$(python3 orion-timing-calibration.py derive orion.example.com 42 30)
#   first=$(echo "$sched" | python3 -c 'import json,sys;print(int(json.load(sys.stdin)["first_check"]))')
#   ... sleep "$first", poll, on success:
#   python3 orion-timing-calibration.py record orion.example.com 42 30 47.2
# ---------------------------------------------------------------------------

def _cli(argv):
    import sys
    usage = ("usage: orion-timing-calibration.py derive <host> <nodeId> <frequency>\n"
             "       orion-timing-calibration.py record <host> <nodeId> <frequency> <latency_s>\n"
             "       orion-timing-calibration.py show [<host> <nodeId> <frequency>]\n"
             "cache: %s (override with %s)" % (cache_path(), CACHE_ENV))
    if len(argv) >= 4 and argv[0] == "derive":
        print(json.dumps(derive_schedule(argv[1], argv[2], argv[3]), indent=2))
        return 0
    if len(argv) >= 5 and argv[0] == "record":
        print(json.dumps(record(argv[1], argv[2], argv[3], argv[4]), indent=2))
        return 0
    if argv and argv[0] == "show":
        data = load()
        if len(argv) >= 4:
            data = {k: v for k, v in data.items()
                    if k == _key(argv[1], argv[2], argv[3])}
        print(json.dumps(data, indent=2))
        return 0
    print(usage, file=sys.stderr)
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(_cli(sys.argv[1:]))

#!/usr/bin/env python3
"""
SAM Linux script monitor skeleton (no watchdog).
Public Release version (sanitized; generic hosts and addressing only).

Start every new Linux SAM monitor from this file. It implements the
structure from SKILL.md §4: defensive argument tokenization, an argparse
subclass that cannot silently exit, input sanitization, interactive
detection, [SAM-META] on STDERR, and Message:/Statistic: on STDOUT for
every coded exit path. Replace the CORE LOGIC section; keep the frame.

This skeleton has NO watchdog: a check that blocks will sit until the
engine kills it (~120 s) with nothing captured. If the core logic can hang
— network calls, dead NFS mounts, slow subprocesses — wrap it per the
watchdog-design-patterns skill (references/watchdog-monitor.py there is
this same monitor, watchdog-wrapped with SIGALRM).

Exit codes : 0=Up 1=Down 2=Warning 3=Critical 4=Unknown
"""
import datetime
import os
import platform
import socket
import sys
import time

# Output-contract name. "" => bare `Message:`/`Statistic:` lines (the default
# String+Numeric column pair named "Statistic"). Non-empty => named lines
# `Statistic.<NAME>:`, which need a matching Numeric column on the component.
STAT_NAME = ""

_start = time.monotonic()
_start_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sam_lines(message, statistic):
    if STAT_NAME:
        return f"Message.{STAT_NAME}: {message}", f"Statistic.{STAT_NAME}: {statistic}"
    return f"Message: {message}", f"Statistic: {statistic}"


def _account():
    # getpass resolves via LOGNAME/USER/pwd and is headless-safe;
    # os.getlogin() raises OSError with no controlling terminal — the agent case.
    try:
        import getpass
        return getpass.getuser()
    except Exception:
        return "unknown"


def emit_metadata():
    """[SAM-META] block to STDERR on every exit path: which machine ran the
    check, as whom, on which runtime, and how long it took — without anyone
    needing SSH access. Never raises; every field is guarded."""
    try:
        dur = round(time.monotonic() - _start, 2)
    except Exception:
        dur = "?"
    lines = [
        f"[SAM-META] Hostname:      {socket.gethostname()}",
        f"[SAM-META] ExecutionTime: {_start_utc}",
        f"[SAM-META] Duration:      {dur}s",
        f"[SAM-META] Account:       {_account()}",
        f"[SAM-META] RuntimeVer:    Python {platform.python_version()}",
    ]
    print("\n".join(lines), file=sys.stderr, flush=True)


def sam_exit(message, statistic, code):
    """Single exit funnel: metadata, then the parsed SAM lines. flush=True is
    mandatory — the agent can capture an empty buffer if the process exits
    unflushed."""
    emit_metadata()
    m, s = _sam_lines(message, statistic)
    print(m, flush=True)
    print(s, flush=True)
    sys.exit(code)


try:
    import argparse
    import re

    # The Linux agent delivers real argv, Windows-style paths deliver one
    # blob — re-join+split makes the script identical under both, and under
    # a human tester. Consequence: values cannot contain spaces.
    argv = [t for t in re.split(r"\s+", " ".join(sys.argv[1:])) if t]

    class _SamArgError(Exception):
        pass

    class _Parser(argparse.ArgumentParser):
        # Default error() calls sys.exit(2) — indistinguishable from our own
        # Warning exit, with only usage text on STDERR (blank status in
        # Orion). Raising lets every arg error become a clean SAM Warning.
        def error(self, message):
            raise _SamArgError(message)

    parser = _Parser(add_help=True)
    parser.add_argument("--warn", type=float, default=8.0)
    parser.add_argument("--crit", type=float, default=16.0)
    try:
        args = parser.parse_args(argv)
    except _SamArgError as ae:
        sam_exit(f"Invalid arguments: {ae}", 0, 2)

    # Sanitization: arguments arrive verbatim from Orion fields and this
    # process runs under a service account — allowlist before any use.
    if not (args.warn > 0 and args.crit >= args.warn):
        sam_exit(f"Invalid thresholds warn={args.warn} crit={args.crit}", 0, 2)

    interactive = sys.stdin.isatty() and os.isatty(sys.stdout.fileno())

    # =================================================================
    # CORE LOGIC — replace this block. Rules that survive editing:
    #   * stdlib only; subprocess.run([...], shell=False), never shell=True
    #   * guard divisions — NaN silently kills app-wide statistics
    #   * bare numbers only in Statistic values (no units, no text)
    #   * can this block? then add the watchdog wrapper (see docstring)
    # =================================================================
    load1 = round(os.getloadavg()[0], 2)
    host = socket.gethostname()

    if load1 >= args.crit:
        msg, code = f"CRITICAL 1m load {load1} on {host}", 3
    elif load1 >= args.warn:
        msg, code = f"WARNING 1m load {load1} on {host}", 2
    else:
        msg, code = f"OK 1m load {load1} on {host}", 0

    if interactive:
        # Labeled preview of exactly what SAM will parse; headless mode
        # must never print extra STDOUT beyond the contract lines.
        print(f"--- SAM preview: exit {code} ---", file=sys.stderr, flush=True)

    sam_exit(msg, load1, code)

except SystemExit:
    raise
except KeyboardInterrupt:
    sam_exit("Monitor interrupted by operator (Ctrl+C)", 0, 2)
except Exception as exc:  # noqa: BLE001 — contract: no path escapes without SAM output
    # Flatten: a multi-line exception value loses its continuation lines in
    # the parsed Message — only explicit Message:-prefixed lines are joined.
    sam_exit(" ".join(f"Monitor error: {type(exc).__name__}: {exc}".split()), 0, 2)

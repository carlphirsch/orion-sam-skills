#!/usr/bin/env bash
# check-public-safe.sh — gate deliverables against private/organizational
# data before public release (orion-script-deployment-testing skill §7).
# Public Release version: the script itself carries no organizational data;
# the enforcement terms live only in the local, never-committed wordlist.
#
# Usage:   check-public-safe.sh <file-or-dir> [...]
# Exit:    0 clean (warnings allowed) · 1 wordlist hit · 2 usage/config error
#
# Two layers:
#   HARD FAIL — case-insensitive match of any term in the private wordlist
#     ($PUBLIC_SAFE_WORDLIST, default ~/.claude/private/public-release-wordlist.txt).
#     The wordlist holds the actual organizational terms and therefore must
#     never be committed to any repo; a missing wordlist fails closed because
#     running without it silently guts the gate.
#   WARN — heuristics for data the wordlist can't enumerate: IP literals
#     outside the documentation ranges, real-looking FQDNs, email addresses,
#     UNC paths. Warnings need eyeball review, not automatic rejection —
#     public examples legitimately use example.com and 192.0.2.x.
set -euo pipefail

WORDLIST="${PUBLIC_SAFE_WORDLIST:-$HOME/.claude/private/public-release-wordlist.txt}"

if [ "$#" -lt 1 ]; then
    echo "usage: $(basename "$0") <file-or-dir> [...]" >&2
    exit 2
fi
if [ ! -r "$WORDLIST" ]; then
    echo "FAIL: wordlist not found: $WORDLIST" >&2
    echo "      The gate fails closed. Create the wordlist (one term per line," >&2
    echo "      '#' comments allowed) or set PUBLIC_SAFE_WORDLIST." >&2
    exit 2
fi

# Collect target files (skip binaries, VCS internals, and this gate's own
# machinery so the checker can live in the same repo it protects).
FILES=()
for target in "$@"; do
    if [ -d "$target" ]; then
        while IFS= read -r -d '' f; do FILES+=("$f"); done \
            < <(find "$target" -type f ! -path '*/.git/*' ! -name '*.png' \
                ! -name '*.jpg' ! -name '*.gif' ! -name '*.zip' ! -name '*.skill' \
                ! -name "$(basename "$0")" -print0)
    elif [ -f "$target" ]; then
        FILES+=("$target")
    else
        echo "FAIL: no such file or directory: $target" >&2
        exit 2
    fi
done

fail=0
warn=0

# --- Layer 1: wordlist (hard fail) -----------------------------------
# grep -iF per term keeps matches strictly literal; a regex wordlist would
# make an innocent '.' match everything and erode trust in the gate.
while IFS= read -r term; do
    case "$term" in ''|'#'*) continue ;; esac
    for f in "${FILES[@]}"; do
        if hits=$(grep -inF -- "$term" "$f" 2>/dev/null); then
            # Show location but never echo the private term into logs that
            # might themselves be shared — mask all but the first character.
            masked="${term:0:1}$(printf '%*s' $((${#term}-1)) '' | tr ' ' '*')"
            while IFS= read -r line; do
                echo "FAIL [$masked] $f:${line%%:*}"
                fail=$((fail+1))
            done <<< "$hits"
        fi
    done
done < "$WORDLIST"

# --- Layer 2: heuristics (warn) ---------------------------------------
# IPs outside documentation/loopback/broadcast ranges; FQDN-shaped tokens
# not on the allowlist; emails; UNC paths.
IP_RE='([0-9]{1,3}\.){3}[0-9]{1,3}'
IP_OK='^(192\.0\.2|198\.51\.100|203\.0\.113|127\.0|0\.0\.0|255\.255)\.'
FQDN_RE='[a-zA-Z0-9][a-zA-Z0-9-]*\.[a-zA-Z0-9.-]+\.(com|net|org|io|local|corp|internal)\b'
FQDN_OK='(^|\.)example\.(com|net|org)$'

for f in "${FILES[@]}"; do
    while IFS= read -r m; do
        ip=$(echo "$m" | grep -oE "$IP_RE" | head -1)
        echo "$ip" | grep -qE "$IP_OK" || { echo "WARN [ip] $f: $m"; warn=$((warn+1)); }
    done < <(grep -noE "$IP_RE" "$f" 2>/dev/null || true)

    while IFS= read -r m; do
        host=$(echo "$m" | cut -d: -f2-)
        echo "$host" | grep -qiE "$FQDN_OK" || { echo "WARN [fqdn] $f: $m"; warn=$((warn+1)); }
    done < <(grep -nioE "$FQDN_RE" "$f" 2>/dev/null || true)

    while IFS= read -r m; do
        echo "WARN [email] $f: $m"; warn=$((warn+1))
    done < <(grep -nioE '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' "$f" 2>/dev/null \
                 | grep -viE '@example\.(com|net|org)' || true)

    # UNC \\host\share only. Require a real boundary before the leading pair
    # (start-of-line, or a char that isn't an alnum/colon/backslash) so an
    # escaped Windows drive path in a source literal does not masquerade as a
    # UNC hostname: C:\\Users\\Public reads to the naive regex as \\Users, but
    # its backslashes are preceded by ':' (drive) and an alnum (mid-path), so
    # neither is a UNC boundary. A genuine \\server\share at a quote/space/
    # line start still fires.
    while IFS= read -r m; do
        echo "WARN [unc] $f: $m"; warn=$((warn+1))
    done < <(grep -noE '(^|[^A-Za-z0-9:\])\\\\[a-zA-Z0-9._$-]+\\[a-zA-Z0-9._$\\-]+' "$f" 2>/dev/null || true)
done

echo "----"
echo "checked ${#FILES[@]} file(s): $fail hard failure(s), $warn warning(s) shown above"
if [ "$fail" -gt 0 ]; then
    echo "RESULT: FAIL — resolve every wordlist hit and re-run."
    exit 1
fi
echo "RESULT: PASS — review any warnings before release."
exit 0

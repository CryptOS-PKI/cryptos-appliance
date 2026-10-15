#!/usr/bin/env bash
# Unit test for notes.sh: renders the "How <tag> was tested" section from the
# gate's step summary and release/pins.yaml, reads the release's current body
# on stdin, and prints the updated body (replacing a prior run's section, if
# any) on stdout. It never calls `gh`.
# Usage: build/release/notes_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/notes.sh"
root="$(cd "$here/../.." && pwd)"

fail=0

assert_status() {
  name="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL $name: want exit $want got $got" >&2
    fail=1
  else
    echo "ok   $name (exit $got)"
  fi
}

assert_contains() {
  name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "ok   $name" ;;
    *)
      echo "FAIL $name: missing '$needle' in: $haystack" >&2
      fail=1
      ;;
  esac
}

assert_not_contains() {
  name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL $name: unexpectedly found '$needle'" >&2
      fail=1
      ;;
    *) echo "ok   $name" ;;
  esac
}

assert_count() {
  name="$1" needle="$2" want="$3" haystack="$4"
  got="$(grep -o -F -- "$needle" <<<"$haystack" | wc -l)"
  if [ "$got" -ne "$want" ]; then
    echo "FAIL $name: want $want occurrences of '$needle', got $got" >&2
    fail=1
  else
    echo "ok   $name"
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pins="$work/pins.yaml"
cat > "$pins" <<'EOF'
version: 1
release: v0.1.0-rc.1
repos:
  cryptos-node:     {commit: 6bd5eaeda7242110482f74210f01212f00741f30}
  cryptos-manager:  {commit: 13c1b8ca02e1f09c234a6366f042c0a4a0e29467}
  cryptos-web:      {commit: f0d466dd8d430155b3c38f76439d061241f78554}
  cryptos-release:  {commit: 045d92a3a435c5ceb02199ccff289782108443d7}
  docs:             {commit: ecb0de8e71ddac0cb6e5b11b2519a9af3dc8eaa2}
upgrade_from:
  - {repo: cryptos-node, commit: a77ae5bf55737dec83188fe61fb615fd2fe839e1}
EOF

summary="$work/summary.md"
cat > "$summary" <<'EOF'
| # | Step | Result |
|---|---|---|
| B | Build | ok |
| 1 | Install | ok |
EOF

run_notes() {
  local body="$1"
  NOTES_RUN_URL="https://example.org/runs/123" NOTES_TAG="v0.1.0-rc.1" \
    bash "$script" "$summary" "$pins" <<<"$body"
}

# Case 1: no previous section -- the existing body is kept and the new
# section is appended once, with the commit set and the gate summary.
body1="Pre-1.0 warning.

## Changes
- a change"
out=""
status=0
out="$(run_notes "$body1")" || status=$?
assert_status "first run" 0 "$status"
assert_contains "first run keeps existing body" "Pre-1.0 warning." "$out"
assert_contains "first run keeps changes section" "## Changes" "$out"
assert_contains "first run heading" "## How v0.1.0-rc.1 was tested" "$out"
assert_contains "first run commit set" "cryptos-manager" "$out"
assert_contains "first run commit set sha" "13c1b8ca02e1f09c234a6366f042c0a4a0e29467" "$out"
assert_contains "first run appliance commit" "cryptos-appliance" "$out"
assert_contains "first run gate summary" "| B | Build | ok |" "$out"
assert_contains "first run link" "https://example.org/runs/123" "$out"
assert_count "first run one heading" "## How v0.1.0-rc.1 was tested" 1 "$out"

# Case 2: a re-run on the same tag replaces the old section instead of
# piling up a second one.
body2="Pre-1.0 warning.

## How v0.1.0-rc.1 was tested

stale content from a failed run

## Changes
- a change"
out=""
status=0
out="$(run_notes "$body2")" || status=$?
assert_status "re-run" 0 "$status"
assert_not_contains "re-run drops stale content" "stale content from a failed run" "$out"
assert_contains "re-run keeps changes section" "## Changes" "$out"
assert_count "re-run one heading" "## How v0.1.0-rc.1 was tested" 1 "$out"

# Case 3: missing NOTES_RUN_URL.
out=""
status=0
out="$(NOTES_TAG="v0.1.0-rc.1" bash "$script" "$summary" "$pins" <<<"$body1" 2>&1)" || status=$?
assert_status "missing run url" 1 "$status"

# Case 4: missing gate summary file.
out=""
status=0
out="$(NOTES_RUN_URL="https://example.org/runs/123" NOTES_TAG="v0.1.0-rc.1" \
  bash "$script" "$work/no-such-summary.md" "$pins" <<<"$body1" 2>&1)" || status=$?
assert_status "missing summary file" 1 "$status"
assert_contains "missing summary file message" "no such gate summary file" "$out"

if [ "$fail" -ne 0 ]; then
  echo "notes_test: FAILED" >&2
  exit 1
fi
echo "notes_test: all cases passed"

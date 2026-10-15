#!/usr/bin/env bash
# Unit test for pin.sh: prints the pinned commit for a named repo out of
# release/pins.yaml, and fails clearly for an unknown repo or a missing file.
# Usage: build/release/pin_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/pin.sh"

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

assert_eq() {
  name="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL $name: want '$want' got '$got'" >&2
    fail=1
  else
    echo "ok   $name"
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

# Case 1: a repo in the repos block.
out=""
status=0
out="$(bash "$script" cryptos-manager "$pins" 2>&1)" || status=$?
assert_status "cryptos-manager" 0 "$status"
assert_eq "cryptos-manager commit" "13c1b8ca02e1f09c234a6366f042c0a4a0e29467" "$out"

# Case 2: another repo in the repos block.
out=""
status=0
out="$(bash "$script" cryptos-web "$pins" 2>&1)" || status=$?
assert_status "cryptos-web" 0 "$status"
assert_eq "cryptos-web commit" "f0d466dd8d430155b3c38f76439d061241f78554" "$out"

# Case 3: a repo not in the repos block (upgrade_from is a different section
# and is never returned by a repo lookup).
out=""
status=0
out="$(bash "$script" upgrade_from "$pins" 2>&1)" || status=$?
assert_status "section, not a repo" 1 "$status"
assert_contains "section, not a repo message" "no pin for upgrade_from" "$out"

# Case 4: an unknown repo.
out=""
status=0
out="$(bash "$script" cryptos-nope "$pins" 2>&1)" || status=$?
assert_status "unknown repo" 1 "$status"
assert_contains "unknown repo message" "no pin for cryptos-nope" "$out"

# Case 5: no pins file at all.
out=""
status=0
out="$(bash "$script" cryptos-manager "$work/does-not-exist.yaml" 2>&1)" || status=$?
assert_status "missing pins file" 1 "$status"
assert_contains "missing pins file message" "no such pins file" "$out"

if [ "$fail" -ne 0 ]; then
  echo "pin_test: FAILED" >&2
  exit 1
fi
echo "pin_test: all cases passed"

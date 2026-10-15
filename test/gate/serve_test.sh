#!/usr/bin/env bash
# Unit test for gate_lab_addr (test/gate/lib.sh) and gate_serve_start/
# gate_serve_stop (test/gate/run.sh): the candidate image server binds the
# runner's own address (never loopback in the real path), serves
# candidate.uki for real, records its URL in state for step 14 to read, and
# is gone once stopped. A fake `ip` (set through GATE_IP, never
# testdata/bin/ip, which a sibling network fix also adds) stands in for the
# runner's routing table.
#
# Usage: test/gate/serve_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
assert_eq() {
  name="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    printf 'FAIL %s:\n  want: %s\n  got:  %s\n' "$name" "$want" "$got" >&2
    fail=1
  else
    echo "ok   $name"
  fi
}
assert_status() {
  name="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL $name: want exit $want got $got" >&2
    fail=1
  else
    echo "ok   $name (exit $got)"
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A fake `ip` reporting the runner reaches 203.0.113.9 (a stand-in ESXi host
# address) with source address 198.51.100.5 on a fake lab interface.
cat > "$work/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2 $3 $4" in
  "-4 route get 203.0.113.9")
    echo "203.0.113.9 dev gatenet0 src 198.51.100.5 uid 1000"
    ;;
  *)
    echo "fake ip: unexpected invocation: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$work/ip"

# --- gate_lab_addr -------------------------------------------------------------

GATE_TEST_SOURCE_ONLY=1 source "$here/run.sh"
export GATE_IP="$work/ip"

addr="$(gate_lab_addr 203.0.113.9)"
assert_eq "gate_lab_addr reads src from the connected route" "198.51.100.5" "$addr"

status=0
out="$(gate_lab_addr 203.0.113.250 2>&1)" || status=$?
assert_status "gate_lab_addr fails for an address the fake ip does not know" 1 "$status"

# --- gate_serve_start / gate_serve_stop -----------------------------------------

GATE_WORK="$(mktemp -d)"
mkdir -p "$GATE_WORK/candidate"
printf 'candidate-uki-bytes\n' > "$GATE_WORK/candidate/candidate.uki"
export GATE_WORK
export GATE_ESXI_URL="https://esx-lab.example.org/sdk"

# Loopback stands in for "the runner's lab address" in this test; the real
# path (gate_lab_addr, exercised above) is what picks a real one.
gate_lab_addr() { printf '127.0.0.1\n'; }
GATE_SERVE_PORT=18099

gate_serve_start
url="$(gate_state_get serve-url)"
assert_eq "gate_serve_start records the served URL" "http://127.0.0.1:18099/candidate.uki" "$url"

fetched="$(curl -s "$url")"
assert_eq "the server serves the candidate's real bytes" "candidate-uki-bytes" "$fetched"

pid="$(cat "$GATE_WORK/serve.pid")"
gate_serve_stop
status=0
kill -0 "$pid" 2>/dev/null && status=1
assert_status "gate_serve_stop ends the server process" 0 "$status"
status=0
curl -s --max-time 1 "$url" >/dev/null 2>&1 || status=$?
assert_status "the port no longer answers once stopped" 7 "$status"

# A second call with no serve.pid left is a no-op, not an error.
status=0
gate_serve_stop || status=$?
assert_status "gate_serve_stop is a no-op when nothing is running" 0 "$status"

# --- gate_serve_start with nothing built ----------------------------------------

work2="$(mktemp -d)"
GATE_WORK="$work2"
status=0
gate_serve_start || status=$?
assert_status "gate_serve_start is a no-op when step B never ran" 0 "$status"
assert_eq "nothing is recorded to serve" "" "$(gate_state_get serve-url)"
rm -rf "$work2"

rm -rf "$GATE_WORK"

if [ "$fail" -ne 0 ]; then
  echo "serve_test: FAILED" >&2
  exit 1
fi
echo "serve_test: all cases passed"

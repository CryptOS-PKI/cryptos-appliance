#!/usr/bin/env bash
# Unit test for gate_network_for (test/gate/lib.sh): the gate reads the real
# network prefix and gateway for a node's DHCP address from the runner's own
# routing table (the runner sits on the same lab network as the gate VMs),
# instead of assuming a /24 and a synthetic first-host-address gateway. A
# fake `ip` (test/gate/testdata/bin) stands in for the runner's routing
# table.
#
# Usage: test/gate/network_test.sh
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

# shellcheck source=test/gate/lib.sh
source "$here/lib.sh"
export GATE_IP="$here/testdata/bin/ip"

# --- gate_addr_in_cidr --------------------------------------------------------

if gate_addr_in_cidr 198.51.100.42 198.51.100.0/24; then
  echo "ok   address inside the /24 matches"
else
  echo "FAIL address inside the /24 should match" >&2
  fail=1
fi
if gate_addr_in_cidr 198.51.100.42 203.0.113.0/24; then
  echo "FAIL address outside the /24 should not match" >&2
  fail=1
else
  echo "ok   address outside the /24 does not match"
fi
if gate_addr_in_cidr 198.51.100.200 198.51.100.128/26; then
  echo "FAIL address outside a narrower prefix should not match" >&2
  fail=1
else
  echo "ok   address outside a narrower prefix does not match"
fi

# --- gate_network_for: the happy path -----------------------------------------

out=""
status=0
out="$(gate_network_for 198.51.100.11 gate-root)" || status=$?
assert_status "resolves prefix and gateway" 0 "$status"
assert_eq "prefix and gateway" "24 198.51.100.1" "$out"

out="$(gate_network_for 198.51.100.13 gate-fresh)"
assert_eq "resolves for another address on the same network" "24 198.51.100.1" "$out"

# The second interface's default route (otherlink0) must never be picked:
# the gateway has to come from the connected route's own interface.
assert_not_contains "never picks another interface's default route" "203.0.113.1" "$out"

# --- gate_network_for: not on a directly connected network --------------------

out=""
status=0
out="$(FAKE_IP_NO_CONNECTED=1 gate_network_for 203.0.113.9 gate-offlink 2>&1)" || status=$?
assert_status "no connected route: fails" 1 "$status"
assert_contains "no connected route: names the VM" "gate-offlink" "$out"
assert_not_contains "no connected route: never names the address" "203.0.113.9" "$out"

# --- gate_network_for: a connected network with no default route -------------

out=""
status=0
out="$(FAKE_IP_NO_DEFAULT=1 gate_network_for 198.51.100.11 gate-root 2>&1)" || status=$?
assert_status "no default route: fails" 1 "$status"
assert_contains "no default route: names the VM" "gate-root" "$out"
assert_not_contains "no default route: never names the address" "198.51.100.11" "$out"

# --- gate_root_config / gate_int_config: the real prefix and gateway ----------

export GATE_NTP="ntp.example.org"
gate_keys_init
printf 'cert\n' > "$GATE_KEYDIR/admin.crt"
cfg="$(gate_root_config gate-root 198.51.100.11 "CryptOS Gate Root")"
assert_contains "root config carries the real prefix" "address: 198.51.100.11/24" "$cfg"
assert_contains "root config carries the real gateway" "gateway: 198.51.100.1" "$cfg"

cfg="$(gate_int_config gate-intermediate 198.51.100.12 "CryptOS Gate Intermediate" "$GATE_KEYDIR/admin.crt")"
assert_contains "intermediate config carries the real prefix" "address: 198.51.100.12/24" "$cfg"
assert_contains "intermediate config carries the real gateway" "gateway: 198.51.100.1" "$cfg"

status=0
FAKE_IP_NO_CONNECTED=1 gate_root_config gate-root 203.0.113.9 "CryptOS Gate Root" >/tmp/network_test.$$ 2>&1 || status=$?
out="$(cat /tmp/network_test.$$)"
rm -f /tmp/network_test.$$
assert_status "root config fails when the gateway can't be resolved" 1 "$status"
assert_not_contains "root config failure never names the address" "203.0.113.9" "$out"

gate_keys_shred

if [ "$fail" -ne 0 ]; then
  echo "network_test: FAILED" >&2
  exit 1
fi
echo "network_test: all cases passed"

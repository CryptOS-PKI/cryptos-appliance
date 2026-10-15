#!/usr/bin/env bash
# Unit test for gate_root_config and gate_int_config (test/gate/lib.sh): the
# Intermediate's MachineConfig carries a pki.scep block with require_approval
# on tls-server from install (pki.scep only takes effect at the next boot, so
# the e2e SCEP step needs it there rather than pushed live), and the Root's
# never does.
#
# Usage: test/gate/config_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
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
# The fake runner routing table that gate_int_config reads for the node's
# prefix and gateway since the real-gateway change (#55).
export GATE_IP="$here/testdata/bin/ip"

export GATE_NTP="ntp.example.org"
gate_keys_init
printf 'cert\n' > "$GATE_KEYDIR/admin.crt"
trap gate_keys_shred EXIT

root_cfg="$(gate_root_config gate-root 198.51.100.11 "CryptOS Gate Root")"
assert_not_contains "the Root's config carries no pki.scep block" "scep:" "$root_cfg"

int_cfg="$(gate_int_config gate-intermediate 198.51.100.12 "CryptOS Gate Intermediate" "$GATE_KEYDIR/admin.crt")"
assert_contains "the Intermediate's config carries a pki.scep block" "scep:" "$int_cfg"
assert_contains "the scep profile names tls-server" "profile: tls-server" "$int_cfg"
assert_contains "the scep profile requires approval" "require_approval: true" "$int_cfg"
assert_contains "the scep profile allows gate.example.org" "allowed_identifier_suffixes: [gate.example.org]" "$int_cfg"

if [ "$fail" -ne 0 ]; then
  echo "config_test: FAILED" >&2
  exit 1
fi
echo "config_test: all cases passed"

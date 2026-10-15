#!/usr/bin/env bash
# Unit test for gate_redact (test/gate/lib.sh): every GATE_* setting, the ESXi
# account, the host inside GATE_ESXI_URL, each address in GATE_ADDRS and any
# other IPv4 address are replaced before a line leaves the gate, and ordinary
# text (versions, OIDs, step names) passes through untouched.
#
# Usage: test/gate/redact_test.sh
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
assert_not_contains() {
  name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL $name: '$needle' leaked" >&2
      fail=1
      ;;
    *) echo "ok   $name" ;;
  esac
}

# shellcheck source=test/gate/lib.sh
source "$here/lib.sh"

export GATE_ESXI_URL="https://esx-lab.example.org/sdk"
export GATE_ESXI_THUMBPRINT="AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD"
export GATE_ESXI_DATASTORE="gate-nfs-example"
export GATE_ESXI_POOL="/ha-datacenter/host/esx-lab.example.org/Resources/cryptos-gate"
export GATE_ESXI_NETWORK="Gate Net (example)"
export GATE_CIDR="192.0.2.0/24"
export GATE_GATEWAY="192.0.2.1"
export GATE_ADDRS="192.0.2.21 192.0.2.22 192.0.2.23 192.0.2.24 192.0.2.25 192.0.2.26 192.0.2.27 192.0.2.28"
export GATE_NTP="ntp.example.org"
export GATE_SNEAKERS_SECRET="example-gate-account"
export GATE_ESXI_USERNAME="gate-svc"
export GATE_ESXI_PASSWORD='p@ss.w0rd$/\[x]*'

r() { printf '%s\n' "$1" | gate_redact; }

assert_eq "URL" "govc: [GATE_ESXI_URL] ok" "$(r "govc: https://esx-lab.example.org/sdk ok")"
assert_eq "host from the URL" "host [GATE_ESXI_HOST] answered" "$(r "host esx-lab.example.org answered")"
assert_eq "thumbprint" "thumbprint [GATE_ESXI_THUMBPRINT]" "$(r "thumbprint $GATE_ESXI_THUMBPRINT")"
assert_eq "datastore" "[[GATE_ESXI_DATASTORE]] cryptos-gate-1/x.iso" "$(r "[gate-nfs-example] cryptos-gate-1/x.iso")"
assert_eq "pool" "pool [GATE_ESXI_POOL]" "$(r "pool $GATE_ESXI_POOL")"
assert_eq "network with spaces and brackets" "net [GATE_ESXI_NETWORK]" "$(r "net Gate Net (example)")"
assert_eq "CIDR" "cidr [GATE_CIDR]" "$(r "cidr 192.0.2.0/24")"
assert_eq "gateway" "gw [GATE_GATEWAY]" "$(r "gw 192.0.2.1")"
assert_eq "each gate address by index" "root [GATE_ADDR_1]:443 int [GATE_ADDR_2] last [GATE_ADDR_8]" \
  "$(r "root 192.0.2.21:443 int 192.0.2.22 last 192.0.2.28")"
assert_eq "NTP" "ntp [GATE_NTP]" "$(r "ntp ntp.example.org")"
assert_eq "secret name" "secret [GATE_SNEAKERS_SECRET]" "$(r "secret example-gate-account")"
assert_eq "username" "user [GATE_ESXI_USERNAME]" "$(r "user gate-svc")"
assert_eq "password with regex metacharacters" "pw [GATE_ESXI_PASSWORD] end" "$(r "pw $GATE_ESXI_PASSWORD end")"
assert_eq "a DHCP address outside GATE_ADDRS" "maintenance at [ipv4]" "$(r "maintenance at 198.51.100.77")"
assert_eq "an address in a URL" "fetch http://[GATE_ADDR_2]/crl" "$(r "fetch http://192.0.2.22/crl")"

assert_eq "versions pass through" "kernel 6.12.94 go1.26.1 v0.1.0-rc.1" "$(r "kernel 6.12.94 go1.26.1 v0.1.0-rc.1")"
assert_eq "OIDs pass through" "policy 1.3.6.1.4.1.55555.1.2" "$(r "policy 1.3.6.1.4.1.55555.1.2")"
assert_eq "step text passes through" "| 4 | power loss during the ESP write | pass |" "$(r "| 4 | power loss during the ESP write | pass |")"

# Many lines, mixed stdout/stderr text: nothing of any value survives.
all="$(printf '%s\n' "$GATE_ESXI_URL" "$GATE_ESXI_DATASTORE" "$GATE_ESXI_NETWORK" "$GATE_ESXI_PASSWORD" "$GATE_ADDRS" "esx-lab.example.org" | gate_redact)"
for v in esx-lab.example.org gate-nfs-example "Gate Net" "p@ss" 192.0.2.2 ; do
  assert_not_contains "nothing survives: $v" "$v" "$all"
done

# Unset or empty settings are skipped rather than matching everything.
out="$(GATE_NTP="" bash -c "source '$here/lib.sh'; printf 'plain text\n' | gate_redact")"
assert_eq "an empty setting matches nothing" "plain text" "$out"

# The redacted stream is line-buffered: a line comes out before the input ends.
fifo_dir="$(mktemp -d)"
mkfifo "$fifo_dir/in"
( gate_redact < "$fifo_dir/in" > "$fifo_dir/out" ) &
redact_pid=$!
exec 7>"$fifo_dir/in"
printf 'first line gate-svc\n' >&7
for _ in $(seq 1 50); do
  [ -s "$fifo_dir/out" ] && break
  sleep 0.1
done
assert_eq "line-buffered" "first line [GATE_ESXI_USERNAME]" "$(cat "$fifo_dir/out")"
exec 7>&-
wait "$redact_pid"
rm -rf "$fifo_dir"

if [ "$fail" -ne 0 ]; then
  echo "redact_test: FAILED" >&2
  exit 1
fi
echo "redact_test: all cases passed"

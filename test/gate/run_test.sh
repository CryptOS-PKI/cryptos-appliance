#!/usr/bin/env bash
# Offline test for the ESXi gate driver (run.sh, lib.sh, steps/). A fake
# govc on PATH and a fake cryptosctl (test/gate/testdata/bin) stand in for
# the lab ESXi box and the nodes; the image builds are replaced by small
# marker files, and the network probes (TCP, the TLS chain, CRL and OCSP) by
# functions that read the fake nodes' state. Everything else runs for real:
# the settings check, the per-run keys on /dev/shm (made with the real
# cryptos-sbkey) and their shredding, the redaction of every output line, the
# step runner and its dependencies, the order of the upgrade, power-cut and
# rollback steps, and the teardown.
#
# Usage: test/gate/run_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
      echo "FAIL $name: missing '$needle'" >&2
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

lab_env() {
  export GATE_ENV_FILE="$work/no-such-file"
  export GATE_ESXI_URL="https://esx-lab.example.org/sdk"
  export GATE_ESXI_THUMBPRINT="AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD"
  export GATE_ESXI_DATASTORE="gate-nfs-example"
  export GATE_ESXI_POOL="/ha-datacenter/host/esx-lab.example.org/Resources/cryptos-gate"
  export GATE_ESXI_NETWORK="Gate Net Example"
  export GATE_CIDR="192.0.2.0/24"
  export GATE_GATEWAY="192.0.2.1"
  export GATE_ADDRS="192.0.2.21 192.0.2.22 192.0.2.23 192.0.2.24 192.0.2.25 192.0.2.26 192.0.2.27 192.0.2.28"
  export GATE_NTP="ntp.example.org"
  export GATE_SNEAKERS_SECRET="example-gate-account"
  export GATE_ESXI_USERNAME="gate-svc"
  export GATE_ESXI_PASSWORD="example-Passw0rd-xyz"
}

# run_gate <state dir> [env assignments...]: one gate run against fresh fakes.
run_gate() {
  local state="$1"
  shift
  mkdir -p "$state"
  cat > "$state/addrmap" <<EOF
198.51.100.11 root
198.51.100.12 intermediate
198.51.100.13 fresh
192.0.2.21 root
192.0.2.22 intermediate
192.0.2.23 fresh
EOF
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -keyout "$state/selfsigned.key" -out "$state/selfsigned.pem" -subj /CN=localhost 2>/dev/null
  printf 'baseline-uki' | sha256sum | cut -d' ' -f1 > "$state/iso-baseline.iso"
  printf 'candidate-uki' | sha256sum | cut -d' ' -f1 > "$state/iso-candidate.iso"
  env FAKE_STATE="$state" PATH="$here/testdata/bin:$PATH" "$@" bash -c '
    set -euo pipefail
    GATE_TEST_SOURCE_ONLY=1 source "'"$here"'/run.sh"
    GATE_CRYPTOSCTL="'"$here"'/testdata/bin/cryptosctl"
    GATE_CUT_AFTER=1
    gate_preflight() { :; }
    gate_build_baseline() {
      mkdir -p "$GATE_WORK/baseline"
      printf baseline-uki > "$GATE_WORK/baseline/baseline.uki"
      printf baseline-iso > "$GATE_WORK/baseline/baseline.iso"
    }
    gate_build_candidate() {
      local c="$GATE_WORK/candidate"
      mkdir -p "$c"
      printf candidate-uki > "$c/candidate.uki"
      printf candidate-sig-K > "$c/candidate.uki.sig"
      printf unsigned-uki > "$c/candidate.uki.unsigned"
      printf candidate-iso > "$c/candidate.iso"
    }
    gate_build_negative() {
      printf negative-uki > "$GATE_WORK/candidate/negative.uki"
      printf negative-sig-W > "$GATE_WORK/candidate/negative.uki.sig"
    }
    gate_check_builds() {
      gate_state_set baseline-sha "$(sha256sum "$GATE_WORK/baseline/baseline.uki" | cut -d" " -f1)"
      gate_state_set candidate-sha "$(sha256sum "$GATE_WORK/candidate/candidate.uki" | cut -d" " -f1)"
      # Record where the keys went, for the test to check afterwards.
      printf "%s\n" "$GATE_KEYDIR" > "$FAKE_STATE/keydir"
      ls "$GATE_KEYDIR/K" "$GATE_KEYDIR/W" > "$FAKE_STATE/keyfiles"
      printf "%s\n" "$GATE_WORK" > "$FAKE_STATE/workdir"
    }
    gate_role_of_addr() { awk -v a="$1" "\$1 == a {print \$2}" "$FAKE_STATE/addrmap"; }
    gate_tcp_up() {
      local d="$FAKE_STATE/node-$(gate_role_of_addr "$1")"
      if [ -f "$FAKE_STATE/down-once-$1" ]; then rm -f "$FAKE_STATE/down-once-$1"; return 1; fi
      [ ! -f "$d/off" ]
    }
    gate_server_chain() {
      local d="$FAKE_STATE/node-$(gate_role_of_addr "$1")"
      cat "$d/ca.crt"
      if [ -f "$d/parent.crt" ]; then cat "$d/parent.crt"; else cat "$d/ca.crt"; fi
    }
    gate_crl_lists() {
      grep -qix "$(gate_cert_serial "$1")" "$FAKE_STATE/node-intermediate/revoked"
    }
    gate_ocsp_status() {
      if grep -qix "$(gate_cert_serial "$1")" "$FAKE_STATE/node-intermediate/revoked"; then echo revoked; else echo good; fi
    }
    gate_main
  '
}

shm_before="$(find /dev/shm -maxdepth 1 -name 'cryptos-gate-key.*' 2>/dev/null | sort)"

# ---- case 1: a full passing run ---------------------------------------------------
lab_env
state="$work/pass"
out=""
status=0
out="$(run_gate "$state" GATE_RUN_ID=t1 GATE_SUMMARY_OUT="$work/summary.md" 2>&1)" || status=$?
assert_status "full run passes" 0 "$status"
summary="$(cat "$work/summary.md" 2>/dev/null || true)"
for row in "| B | build" "| 1 | baseline" "| 2 | candidate cryptosctl" "| 3 | image signed by another key" \
  "| 4 | power cut during the ESP write" "| 5 | power cut after stage" "| 6 | power cut during the candidate" \
  "| 7 | state kept" "| 8 | rollback" "| 9 | Root" "| 10 | Intermediate re-key" "| 11 | fresh install" "| 13 | teardown"; do
  assert_contains "summary row: $row" "$row" "$summary"
done
assert_not_contains "no step failed" "| fail |" "$summary"
assert_contains "step 12 is reported as a manual skip" "| 12 | Secure Boot on with K in db, W refused at boot | skip |" "$summary"
assert_contains "step 7 passed" "| 7 | state kept: CA serial and key, issued leaf, CRL, OCSP, audit chain, new leaf | pass |" "$summary"

assert_contains "step 10 (Intermediate re-key) passed" "| 10 | Intermediate re-key: new key chains to the Root, issues, revocations and audit chain kept | pass |" "$summary"
rekey_calls="$(grep -oE '^NODE [a-z]+ ARGS .*<ca> <(rotate-key|sign-subordinate|submit-rotation)>' "$state/cryptosctl.log" | grep -oE '^NODE [a-z]+|<(rotate-key|sign-subordinate|submit-rotation)>' | tr -d '<>' | sed 's/^NODE //' | paste -sd, -)"
assert_contains "the re-key runs rotate-key, the Root's sign-subordinate, submit-rotation" \
  "intermediate,rotate-key,root,sign-subordinate,intermediate,submit-rotation" "$rekey_calls"

# Redaction: no lab value in the output or the summary.
for v in esx-lab.example.org gate-nfs-example "Gate Net Example" "$GATE_ESXI_POOL" 192.0.2.2 198.51.100. \
  gate-svc example-Passw0rd-xyz example-gate-account ntp.example.org "$GATE_ESXI_THUMBPRINT"; do
  assert_not_contains "output redacts $v" "$v" "$out"
  assert_not_contains "summary redacts $v" "$v" "$summary"
done

# govc: every datastore, pool and network argument is the gate's own, every
# VM is this run's and destroyed, the run's folder is removed, the account
# never reaches the arguments and TLS is verified against the thumbprint.
govc_log="$(cat "$state/govc.log")"
ds_args="$(grep -o -- '<-ds> <[^>]*>' "$state/govc.log" | sort -u)"
assert_status "govc -ds is always the gate datastore" "<-ds> <gate-nfs-example>" "$ds_args"
pool_args="$(grep -o -- '<-pool> <[^>]*>' "$state/govc.log" | sort -u)"
assert_status "govc -pool is always the gate pool" "<-pool> <$GATE_ESXI_POOL>" "$pool_args"
assert_contains "VMs are created on the gate network" "<-net> <Gate Net Example>" "$govc_log"
created="$(grep -c '^ARGS <vm.create>' "$state/govc.log")"
assert_status "three VMs created (Root, Intermediate, fresh)" 3 "$created"
assert_status "every VM destroyed" "$(sort "$state/vms" | paste -sd' ' -)" "$(sort -u "$state/destroyed" | paste -sd' ' -)"
others="$(grep '^ARGS <vm.create>' "$state/govc.log" | grep -vc '<cryptos-gate-t1-[a-z]*>$' || true)"
assert_status "every VM carries this run's name" 0 "$others"
assert_contains "the run's datastore folder is removed" "<datastore.rm> <-f> <-ds> <gate-nfs-example> <cryptos-gate-t1>" "$govc_log"
assert_not_contains "the password never reaches govc's arguments" "example-Passw0rd-xyz" "$govc_log"
assert_not_contains "govc never runs insecure" "insecure=true" "$govc_log"
assert_contains "govc gets the account through its environment" "user_set=yes pass_set=yes insecure=false" "$govc_log"
assert_contains "power cuts are hard power-offs" "<vm.power> <-off> <-force>" "$govc_log"

# The order of the Intermediate's upgrade: two refused stages, the cut
# stage, stage, rollback and activate, the stage and activate of step 6,
# then step 8's rollback, activate, stage, activate (design 3.3).
int_calls="$(grep '^NODE intermediate ' "$state/cryptosctl.log" | grep -oE '<image> <(stage|rollback|activate)>' | sed -E 's/<image> <([a-z]+)>/\1/' | paste -sd, -)"
assert_status "the Intermediate's image calls follow the design" \
  "stage,stage,stage,stage,rollback,activate,stage,activate,rollback,activate,stage,activate" "$int_calls"

# Keys: on /dev/shm while the run lasted, gone afterwards, as is the work dir.
keydir="$(cat "$state/keydir")"
case "$keydir" in
  /dev/shm/cryptos-gate-key.*) echo "ok   keys lived on /dev/shm" ;;
  *) echo "FAIL keys lived outside /dev/shm: $keydir" >&2; fail=1 ;;
esac
assert_contains "K and W were made" "sb.key" "$(cat "$state/keyfiles")"
if [ -e "$keydir" ]; then echo "FAIL the key dir survived the run" >&2; fail=1; else echo "ok   the key dir is shredded at exit"; fi
if [ -e "$(cat "$state/workdir")" ]; then echo "FAIL the work dir survived the run" >&2; fail=1; else echo "ok   the work dir is removed at exit"; fi

# ---- case 2: a node that accepts any image fails step 3, skips what depends on it, still tears down
state="$work/accept-all"
out=""
status=0
out="$(run_gate "$state" GATE_RUN_ID=t2 FAKE_ACCEPT_ALL=1 GATE_SUMMARY_OUT="$work/summary2.md" 2>&1)" || status=$?
assert_status "a node that stages a W-signed image fails the gate" 1 "$status"
summary="$(cat "$work/summary2.md" 2>/dev/null || true)"
assert_contains "step 3 fails" "| 3 | image signed by another key and unsigned image refused, nothing written | fail |" "$summary"
assert_contains "step 3 says why" "staged an image signed by W" "$summary"
assert_contains "step 4 is skipped" "| 4 | power cut during the ESP write: boots the baseline, state intact | skip |" "$summary"
assert_contains "step 8 is skipped" "| 8 | rollback to the baseline, state kept, still signs, upgrade again | skip |" "$summary"
assert_contains "step 9 still runs" "| 9 | Root: stage, activate, state kept, still signs | pass |" "$summary"
assert_status "every VM destroyed after a failure" "$(sort "$state/vms" | paste -sd' ' -)" "$(sort -u "$state/destroyed" | paste -sd' ' -)"
assert_contains "the output says the gate failed" "gate FAILED" "$out"

# ---- case 2b: a re-key that keeps the old key fails step 10 -----------------------
state="$work/rekey-same"
out=""
status=0
out="$(run_gate "$state" GATE_RUN_ID=t2b FAKE_REKEY_SAME_KEY=1 GATE_SUMMARY_OUT="$work/summary2b.md" 2>&1)" || status=$?
assert_status "a re-key that keeps the key fails the gate" 1 "$status"
summary="$(cat "$work/summary2b.md" 2>/dev/null || true)"
assert_contains "step 10 fails" "| 10 | Intermediate re-key: new key chains to the Root, issues, revocations and audit chain kept | fail |" "$summary"
assert_contains "step 10 says why" "the Intermediate's key did not change" "$summary"

# ---- case 3: GATE_ONLY runs a subset and reports the rest as skipped ------------------
state="$work/only"
out=""
status=0
out="$(run_gate "$state" GATE_RUN_ID=t3 GATE_ONLY=B,11,13 GATE_SUMMARY_OUT="$work/summary3.md" 2>&1)" || status=$?
assert_status "GATE_ONLY run passes" 0 "$status"
summary="$(cat "$work/summary3.md" 2>/dev/null || true)"
assert_contains "step 1 skipped by GATE_ONLY" "| 1 | baseline Root and Intermediate from the ISO, ceremonies, leaf issued, one revoked | skip |" "$summary"
assert_contains "step 11 runs alone" "| 11 | fresh install of the candidate (nodeid) and its ceremony | pass |" "$summary"
assert_status "one VM created" 1 "$(grep -c '^ARGS <vm.create>' "$state/govc.log")"

# ---- case 4: a missing setting stops the gate before anything runs, naming only the setting
lab_env
unset GATE_ESXI_DATASTORE
state="$work/missing"
out=""
status=0
out="$(run_gate "$state" GATE_RUN_ID=t4 2>&1)" || status=$?
assert_status "a missing setting exits 2" 2 "$status"
assert_contains "the missing setting is named" "missing settings: GATE_ESXI_DATASTORE" "$out"
assert_not_contains "nothing reached govc" "vm.create" "$(cat "$state/govc.log" 2>/dev/null || true)"

# ---- case 5: no account from the runner wrapper -------------------------------------
lab_env
unset GATE_ESXI_PASSWORD
state="$work/no-account"
out=""
status=0
out="$(run_gate "$state" GATE_RUN_ID=t5 2>&1)" || status=$?
assert_status "a missing account exits 2" 2 "$status"
assert_contains "the missing account is named" "missing GATE_ESXI_PASSWORD" "$out"
assert_not_contains "the user name is not printed" "gate-svc" "$out"

# ---- case 6: too few addresses ------------------------------------------------------
lab_env
export GATE_ADDRS="192.0.2.21 192.0.2.22"
state="$work/few-addrs"
out=""
status=0
out="$(run_gate "$state" GATE_RUN_ID=t6 2>&1)" || status=$?
assert_status "too few addresses exits 2" 2 "$status"
assert_contains "the address count is explained" "GATE_ADDRS: the gate needs 3 addresses, got 2" "$out"
assert_not_contains "the addresses are not printed" "192.0.2.2" "$out"

shm_after="$(find /dev/shm -maxdepth 1 -name 'cryptos-gate-key.*' 2>/dev/null | sort)"
assert_status "no key dir left on /dev/shm" "$shm_before" "$shm_after"

if [ "$fail" -ne 0 ]; then
  echo "run_test: FAILED" >&2
  exit 1
fi
echo "run_test: all cases passed"

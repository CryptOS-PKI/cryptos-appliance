# shellcheck shell=bash
# Step 13: nothing outlives the run. Every VM the run made is destroyed and
# its datastore folder removed; the keys are shredded when the gate exits,
# whatever happened before.

step_teardown() {
  local left
  gate_teardown
  left="$(gate_govc find / -type m -name "cryptos-gate-$GATE_RUN_ID-*" 2>/dev/null || true)"
  [ -z "$left" ] || gate_fail "VMs from this run are still registered"
  gate_note "VMs destroyed, datastore folder removed, keys shredded at exit"
}

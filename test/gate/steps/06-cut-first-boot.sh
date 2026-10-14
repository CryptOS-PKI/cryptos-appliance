# shellcheck shell=bash
# Step 6: stage and activate, then a hard power-off during the candidate's
# first boot. The node comes up on the candidate with its state intact.

step_cut_first_boot() {
  local c="$GATE_WORK/candidate" addr
  addr="$(cat "$(gate_node_dir intermediate)/addr")"
  gate_ctl intermediate image stage --image "$c/candidate.uki" > "$GATE_WORK/stage-6.out"
  gate_ctl intermediate image activate --confirm "$GATE_INT_CN" >/dev/null
  # The orderly shutdown closes the listener; the first boot starts after.
  gate_wait_tcp_down "$addr" 443
  sleep "${GATE_FIRSTBOOT_CUT_AFTER:-3}"
  gate_vm_power_cut intermediate
  gate_vm_power_on intermediate
  gate_wait_up intermediate
  gate_expect_image intermediate candidate
  gate_check_identity intermediate
  gate_note "cut ${GATE_FIRSTBOOT_CUT_AFTER:-3}s into the first boot; came up on the candidate"
}

gate_wait_tcp_down() {
  local deadline=$((SECONDS + 300))
  while [ "$SECONDS" -lt "$deadline" ]; do
    gate_tcp_up "$1" "$2" || return 0
    sleep 1
  done
  gate_fail "the node kept answering for 300s after activate"
}

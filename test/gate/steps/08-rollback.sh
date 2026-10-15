# shellcheck shell=bash
# Step 8: roll the Intermediate back to the baseline (`image rollback` then
# `activate`); it keeps its state and still signs. Then upgrade it again.

step_rollback() {
  local c="$GATE_WORK/candidate" before
  gate_ctl intermediate image rollback >/dev/null
  before="$(gate_boot_count intermediate)"
  gate_ctl intermediate image activate --confirm "$GATE_INT_CN" >/dev/null
  gate_wait_up intermediate "$before"
  gate_expect_image intermediate baseline
  gate_check_identity intermediate
  gate_check_issues leaf-after-rollback

  gate_ctl intermediate image stage --image "$c/candidate.uki" > "$GATE_WORK/stage-8.out"
  before="$(gate_boot_count intermediate)"
  gate_ctl intermediate image activate --confirm "$GATE_INT_CN" >/dev/null
  gate_wait_up intermediate "$before"
  gate_expect_image intermediate candidate
  gate_check_identity intermediate
  gate_note "back on the baseline with state and signing, then on the candidate again"
}

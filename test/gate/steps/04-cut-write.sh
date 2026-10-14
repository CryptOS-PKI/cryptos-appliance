# shellcheck shell=bash
# Step 4: a hard power-off while the Intermediate writes the candidate to its
# ESP. It must boot the baseline with its state intact, and stage again
# afterwards (step 5 does).

step_cut_write() {
  local c="$GATE_WORK/candidate" pid stage_done=0
  gate_ctl intermediate image stage --image "$c/candidate.uki" > "$GATE_WORK/stage-cut.out" 2>&1 &
  pid=$!
  sleep "${GATE_CUT_AFTER:-3}"
  gate_vm_power_cut intermediate
  if wait "$pid"; then stage_done=1; fi
  gate_vm_power_on intermediate
  gate_wait_up intermediate
  if [ "$stage_done" = 1 ]; then
    gate_fail "image stage finished before the power cut at ${GATE_CUT_AFTER:-3}s; lower GATE_CUT_AFTER"
  fi
  gate_expect_image intermediate baseline
  gate_check_identity intermediate
  gate_note "cut ${GATE_CUT_AFTER:-3}s into the stage; booted the baseline, identity unchanged"
}

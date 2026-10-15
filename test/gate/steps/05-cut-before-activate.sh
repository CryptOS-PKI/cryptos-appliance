# shellcheck shell=bash
# Step 5: stage completes, then a hard power-off before `activate`. Stage
# already put the candidate on the boot path, so the node boots the
# candidate with its state intact. The step then rolls back to the baseline
# so step 6 starts from the field's state again.

step_cut_before_activate() {
  local c="$GATE_WORK/candidate" before
  gate_ctl intermediate image stage --image "$c/candidate.uki" > "$GATE_WORK/stage-5.out"
  case "$(gate_status_field "$(gate_ctl intermediate image status)" "Reboot pending")" in
    yes*) ;;
    *) gate_fail "no reboot pending after a completed stage" ;;
  esac
  gate_vm_power_cut intermediate
  gate_vm_power_on intermediate
  gate_wait_up intermediate
  gate_expect_image intermediate candidate
  gate_check_identity intermediate

  gate_ctl intermediate image rollback >/dev/null
  before="$(gate_boot_count intermediate)"
  gate_ctl intermediate image activate --confirm "$GATE_INT_CN" >/dev/null
  gate_wait_up intermediate "$before"
  gate_expect_image intermediate baseline
  gate_note "booted the candidate after the cut; rolled back to the baseline for step 6"
}

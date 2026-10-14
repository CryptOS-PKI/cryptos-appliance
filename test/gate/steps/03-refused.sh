# shellcheck shell=bash
# Step 3: the node refuses an image signed by a key it does not trust (W)
# and an unsigned image, and writes nothing for either.

step_refused() {
  local c="$GATE_WORK/candidate" next_before
  next_before="$(gate_next_image intermediate)"

  if gate_ctl intermediate image stage --image "$c/negative.uki" --signature "$c/negative.uki.sig" > "$GATE_WORK/stage-negative.out" 2>&1; then
    gate_fail "the Intermediate staged an image signed by W"
  fi
  # The unsigned UKI travels with the candidate's real signature, which is
  # over other bytes: the node, not cryptosctl, has to refuse it.
  if gate_ctl intermediate image stage --image "$c/candidate.uki.unsigned" --signature "$c/candidate.uki.sig" > "$GATE_WORK/stage-unsigned.out" 2>&1; then
    gate_fail "the Intermediate staged an unsigned image"
  fi

  [ "$(gate_next_image intermediate)" = "$next_before" ] || gate_fail "the next boot image changed after a refused stage"
  case "$(gate_status_field "$(gate_ctl intermediate image status)" "Reboot pending")" in
    no*) ;;
    *) gate_fail "a reboot is pending after a refused stage" ;;
  esac
  gate_note "W-signed and unsigned images refused, next boot image unchanged"
}

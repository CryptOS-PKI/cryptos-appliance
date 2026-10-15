# shellcheck shell=bash
# Step 11: a fresh install of the candidate (nodeid) as a Root, with its
# ceremony. The tpm variant is installed by the QEMU suite.

step_fresh() {
  local w="$GATE_WORK"
  [ -f "$GATE_KEYDIR/admin.crt" ] || gate_new_admin
  gate_upload_iso "$w/candidate/candidate.iso" candidate.iso
  gate_fresh_cfg() { gate_root_config gate-fresh "$1" "$GATE_FRESH_CN"; }
  gate_install fresh 3 candidate.iso "$w/fresh.yaml" gate_fresh_cfg
  gate_ctl fresh ceremony start --config "$w/fresh.yaml" > "$w/fresh-ceremony.out"
  grep -q COMPLETE "$w/fresh-ceremony.out" || gate_fail "the fresh Root's ceremony did not report COMPLETE"
  gate_pin_ca fresh
  [ "$(gate_status_field "$(gate_ctl fresh status)" Identity)" = ESTABLISHED ] || gate_fail "the fresh Root has no established identity"
  gate_expect_image fresh candidate
  gate_note "fresh nodeid Root installed from the candidate ISO, ceremony complete"
}

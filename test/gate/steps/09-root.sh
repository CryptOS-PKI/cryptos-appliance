# shellcheck shell=bash
# Step 9: the Root's upgrade (stage, activate) keeps its state, and it still
# signs: it signs the Intermediate's renewal CSR and the result chains to it.

step_root() {
  local w="$GATE_WORK" c="$GATE_WORK/candidate" before
  gate_ctl root image stage --image "$c/candidate.uki" > "$w/stage-9.out"
  before="$(gate_boot_count root)"
  gate_ctl root image activate --confirm "$GATE_ROOT_CN" >/dev/null
  gate_wait_up root "$before"
  gate_expect_image root candidate
  gate_check_identity root
  gate_check_audit root

  gate_ctl intermediate ca get-renewal-csr > "$w/int-renewal.csr"
  gate_ctl root ca sign-subordinate --csr "$w/int-renewal.csr" --profile sub-ca > "$w/int-renewal-chain.pem"
  gate_first_cert "$w/int-renewal-chain.pem" "$w/int-renewal.pem"
  openssl verify -CAfile "$w/root.pem" "$w/int-renewal.pem" >/dev/null || gate_fail "the Root's signature after the upgrade does not verify"
  gate_note "Root on the candidate, same serial and key, audit chain intact, signs"
}

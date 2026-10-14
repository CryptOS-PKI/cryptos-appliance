# shellcheck shell=bash
# Step 10: the Intermediate re-keys through the node's normal path (`ca
# rotate-key`, the Root's `ca sign-subordinate`, `ca submit-rotation`), on
# the candidate, so every release checks it again. The new certificate
# chains to the Root under a new key, issuance works under that key, the
# revocation made before the re-key still shows on the CRL and over OCSP,
# and the audit chain verifies.

step_rekey() {
  local w="$GATE_WORK" old_spki new_spki
  cp "$w/int.pem" "$w/int-before-rekey.pem"
  old_spki="$(gate_cert_spki "$w/int.pem")"

  gate_ctl intermediate ca rotate-key > "$w/int-rekey.csr"
  gate_ctl root ca sign-subordinate --csr "$w/int-rekey.csr" --profile sub-ca > "$w/int-rekey-chain.pem"
  gate_ctl intermediate ca submit-rotation --chain "$w/int-rekey-chain.pem" >/dev/null

  gate_ctl intermediate identity show -o pem > "$w/int-rekeyed-bundle.pem"
  gate_first_cert "$w/int-rekeyed-bundle.pem" "$w/int-rekeyed.pem"
  openssl verify -CAfile "$w/root.pem" "$w/int-rekeyed.pem" >/dev/null || gate_fail "the re-keyed Intermediate does not chain to the Root"
  new_spki="$(gate_cert_spki "$w/int-rekeyed.pem")"
  [ "$new_spki" != "$old_spki" ] || gate_fail "the Intermediate's key did not change"

  cp "$w/int-rekeyed.pem" "$w/int.pem"
  gate_state_set int-serial "$(gate_cert_serial "$w/int.pem")"
  gate_state_set int-spki "$new_spki"
  gate_check_issues leaf-after-rekey

  gate_crl_lists "$w/leaf-b.pem" || gate_fail "the revocation made before the re-key is not on the CRL"
  [ "$(GATE_OCSP_ISSUER="$w/int-before-rekey.pem" gate_ocsp_status "$w/leaf-b.pem")" = revoked ] \
    || gate_fail "OCSP does not say revoked for the leaf revoked before the re-key"
  gate_check_audit intermediate
  gate_note "new key chains to the Root, issues; CRL and OCSP keep the earlier revocation; audit chain intact"
}

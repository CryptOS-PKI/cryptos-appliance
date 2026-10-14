# shellcheck shell=bash
# Step 1: the baseline comes up as in the field. A Root and an Intermediate
# are installed from the baseline ISO through maintenance `config apply`, the
# Root runs its ceremony, the Root signs the Intermediate, the Intermediate
# issues two leaves and revokes one. What later steps compare against is
# recorded: both CA serials and keys, the leaves, and the image each node
# runs.

step_baseline() {
  local w="$GATE_WORK" l csr
  gate_new_admin
  gate_upload_iso "$w/baseline/baseline.iso" baseline.iso

  gate_root_config gate-root "$(gate_addr 1)" "$GATE_ROOT_CN" > "$w/root.yaml"
  gate_install root 1 baseline.iso "$w/root.yaml"
  gate_ctl root ceremony start --config "$w/root.yaml" > "$w/root-ceremony.out"
  grep -q COMPLETE "$w/root-ceremony.out" || gate_fail "the Root ceremony did not report COMPLETE"
  gate_pin_ca root
  gate_ctl root identity show -o pem > "$w/root-bundle.pem"
  gate_first_cert "$w/root-bundle.pem" "$w/root.pem"

  gate_int_config gate-intermediate "$(gate_addr 2)" "$GATE_INT_CN" "$w/root.pem" > "$w/int.yaml"
  gate_install intermediate 2 baseline.iso "$w/int.yaml"
  gate_ctl intermediate ca get-subordinate-csr > "$w/int.csr"
  gate_ctl root ca sign-subordinate --csr "$w/int.csr" --profile sub-ca > "$w/int-chain.pem"
  gate_ctl intermediate ca submit-subordinate-cert --chain "$w/int-chain.pem" >/dev/null
  gate_pin_ca intermediate
  gate_ctl intermediate identity show -o pem > "$w/int-bundle.pem"
  gate_first_cert "$w/int-bundle.pem" "$w/int.pem"
  openssl verify -CAfile "$w/root.pem" "$w/int.pem" >/dev/null || gate_fail "the Intermediate does not chain to the Root"

  for l in leaf-a leaf-b; do
    csr="$(gate_new_csr "$l" "$l.gate.example.org")"
    gate_ctl intermediate ca issue-leaf --csr "$csr" --profile tls-server --dns "$l.gate.example.org" > "$w/$l-bundle.pem"
    gate_first_cert "$w/$l-bundle.pem" "$w/$l.pem"
  done
  gate_ctl intermediate ca revoke --serial "$(gate_cert_serial "$w/leaf-b.pem")" --reason 1 >/dev/null

  gate_state_set root-serial "$(gate_cert_serial "$w/root.pem")"
  gate_state_set root-spki "$(gate_cert_spki "$w/root.pem")"
  gate_state_set int-serial "$(gate_cert_serial "$w/int.pem")"
  gate_state_set int-spki "$(gate_cert_spki "$w/int.pem")"

  gate_expect_image root baseline
  gate_expect_image intermediate baseline

  if gate_ctl intermediate audit verify > "$w/audit-baseline.out" 2>&1; then
    gate_note "baseline audit chain intact"
  else
    gate_note "the baseline does not verify its audit chain over the API; step 7 verifies the whole chain on the candidate"
  fi
  gate_note "Root and Intermediate on the baseline, one leaf kept, one revoked"
}

# gate_expect_image <role> <baseline|candidate>: the node runs that image.
gate_expect_image() {
  local role="$1" want got
  want="$(gate_state_get "$2-sha")"
  got="$(gate_running_image "$role")"
  [ "$got" = "$want" ] || gate_fail "$role runs image ${got:-<none>}, want the $2 ($want)"
}

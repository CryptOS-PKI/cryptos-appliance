# shellcheck shell=bash
# Step 7: an upgrade is not a re-key. On the candidate the Intermediate
# keeps its CA serial and key, still lists the leaf it issued on the
# baseline, publishes the revoked serial on its CRL, answers OCSP good and
# revoked, verifies its audit chain across the upgrade, and issues a new leaf.

step_state() {
  gate_check_identity intermediate
  gate_check_identity root
  gate_check_issuer_state
  gate_check_audit intermediate
  gate_check_issues new-leaf-7
  gate_note "same CA serial and key, old leaf listed, CRL and OCSP right, audit chain intact, new leaf issued"
}

# gate_check_identity <role>: the node's CA certificate has the serial and
# public key recorded on the baseline.
gate_check_identity() {
  local role="$1" key="$1" pem
  [ "$role" = intermediate ] && key=int
  pem="$GATE_WORK/$role-identity-now.pem"
  gate_ctl "$role" identity show -o pem > "$pem.bundle"
  gate_first_cert "$pem.bundle" "$pem"
  [ "$(gate_cert_serial "$pem")" = "$(gate_state_get "$key-serial")" ] || gate_fail "$role: the CA serial changed"
  [ "$(gate_cert_spki "$pem")" = "$(gate_state_get "$key-spki")" ] || gate_fail "$role: the CA key changed"
}

gate_check_issuer_state() {
  local w="$GATE_WORK" a b
  a="$(gate_cert_serial "$w/leaf-a.pem")"
  b="$(gate_cert_serial "$w/leaf-b.pem")"
  gate_ctl intermediate ca list-issued | tr '[:upper:]' '[:lower:]' | grep -q "$a" \
    || gate_fail "the leaf issued on the baseline is not in the inventory"
  gate_crl_lists "$w/leaf-b.pem" || gate_fail "the revoked serial is not on the CRL"
  [ "$(gate_ocsp_status "$w/leaf-a.pem")" = good ] || gate_fail "OCSP does not say good for the kept leaf"
  [ "$(gate_ocsp_status "$w/leaf-b.pem")" = revoked ] || gate_fail "OCSP does not say revoked for the revoked leaf"
  [ -n "$b" ]
}

gate_check_audit() {
  gate_ctl "$1" audit verify > "$GATE_WORK/audit-$1.out" 2>&1 || gate_fail "$1: the audit chain does not verify"
  grep -q intact "$GATE_WORK/audit-$1.out" || gate_fail "$1: audit verify did not report an intact chain"
}

# gate_check_issues <name>: the Intermediate issues a new leaf that chains to
# the Root.
gate_check_issues() {
  local w="$GATE_WORK" csr
  csr="$(gate_new_csr "$1" "$1.gate.example.org")"
  gate_ctl intermediate ca issue-leaf --csr "$csr" --profile tls-server --dns "$1.gate.example.org" > "$w/$1-bundle.pem"
  gate_first_cert "$w/$1-bundle.pem" "$w/$1.pem"
  openssl verify -CAfile "$w/root.pem" -untrusted "$w/int.pem" "$w/$1.pem" >/dev/null || gate_fail "the new leaf does not chain to the Root"
}

# gate_crl_lists <leaf>: the CRL at the leaf's distribution point lists its
# serial.
gate_crl_lists() {
  local leaf="$1" url serial crl="$GATE_WORK/crl.der"
  url="$(openssl x509 -in "$leaf" -noout -ext crlDistributionPoints 2>/dev/null | grep -o 'URI:[^ ]*' | head -n1 | cut -c5-)"
  [ -n "$url" ] || return 1
  serial="$(gate_cert_serial "$leaf")"
  curl -fsS --max-time 20 -o "$crl" "$url" || return 1
  { openssl crl -in "$crl" -inform DER -noout -text 2>/dev/null || openssl crl -in "$crl" -noout -text; } \
    | tr '[:upper:]' '[:lower:]' | grep -q "serial number: *$serial"
}

# gate_ocsp_status <leaf>: good, revoked or unknown, from the leaf's OCSP
# responder, with the response verified against the Root. GATE_OCSP_ISSUER
# names the issuing certificate when it is not the current Intermediate (a
# leaf issued before a re-key).
gate_ocsp_status() {
  local leaf="$1" w="$GATE_WORK" url out
  local issuer="${GATE_OCSP_ISSUER:-$w/int.pem}"
  url="$(openssl x509 -in "$leaf" -noout -ocsp_uri)"
  out="$(openssl ocsp -issuer "$issuer" -cert "$leaf" -url "$url" -CAfile "$w/root.pem" -verify_other "$w/int.pem" 2>&1)" || true
  case "$out" in
    *": revoked"*) echo revoked ;;
    *": good"*) echo good ;;
    *) echo unknown ;;
  esac
}

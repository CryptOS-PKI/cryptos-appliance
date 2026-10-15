# shellcheck shell=bash
# Step 12: Secure Boot on with K in db. Enrolling a key in a VM's db cannot
# be automated reliably on a standalone ESXi host yet, so this stays a
# manual check (docs/secure-boot.md); step B's `sbverify --cert K` covers
# the Authenticode signature and refuses the W-signed image.

step_secure_boot() {
  gate_skip "manual: db enrolment is not automated; step B verifies the signature with K and refuses W"
}

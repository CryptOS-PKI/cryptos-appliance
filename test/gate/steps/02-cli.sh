# shellcheck shell=bash
# Step 2: the new cryptosctl talks to the old nodes.

step_cli_compat() {
  local role out
  for role in root intermediate; do
    out="$(gate_ctl "$role" status)"
    [ "$(gate_status_field "$out" Identity)" = ESTABLISHED ] || gate_fail "$role: status does not show an established identity"
    out="$(gate_ctl "$role" image status)"
    [ -n "$(gate_status_field "$out" "Running image")" ] || gate_fail "$role: image status shows no running image"
  done
  gate_note "status and image status from the candidate cryptosctl on both baseline nodes"
}

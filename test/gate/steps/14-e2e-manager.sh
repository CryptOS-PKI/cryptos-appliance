# shellcheck shell=bash
# Step 14: drive cryptos-manager's full write-path exercise (test/e2e/esxi,
# `task e2e:esxi`, CryptOS-PKI/cryptos-manager#38) against the gate's own
# live Root and Intermediate, with gate_serve_start's served candidate.uki as
# the image under test (E2E_IMAGE_URL/E2E_IMAGE_SIGNATURE_PATH/
# E2E_IMAGE_SHA256). This needs a pinned cryptos-manager checkout
# (GATE_MANAGER_DIR, set by the release workflow from release/pins.yaml) and
# docker, for test/e2e/esxi's own throwaway Postgres; without either, or
# without a served candidate, this reports skip, naming what is missing,
# rather than failing the gate. No node is marked spare, so the manager's own
# rekey, escrow, enrolment and decommission steps report their own skip,
# which is not a failure.

step_e2e_manager() {
  local w="$GATE_WORK" nodes pg db_port work2 root_dir int_dir url image_sha deadline

  if [ -z "${GATE_MANAGER_DIR:-}" ] || [ ! -d "$GATE_MANAGER_DIR" ]; then
    gate_skip "GATE_MANAGER_DIR is not set to a cryptos-manager checkout"
    return 0
  fi
  url="$(gate_state_get serve-url)"
  if [ -z "$url" ]; then
    gate_skip "the candidate image server never started"
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    gate_skip "docker is not available for test/e2e/esxi's throwaway Postgres"
    return 0
  fi

  root_dir="$(gate_node_dir root)"
  int_dir="$(gate_node_dir intermediate)"
  nodes="$w/e2e-nodes.yaml"
  # The Intermediate goes first: it is the node primary() picks, and the only
  # one with issuing profiles and (once #58 lands) a pki.scep.profiles entry.
  cat > "$nodes" <<EOF
nodes:
  - name: gate-intermediate
    endpoint: $(cat "$int_dir/addr"):443
    role: intermediate
    adminCertPath: $GATE_KEYDIR/admin.crt
    adminKeyPath: $GATE_KEYDIR/admin.key
    caCertPath: $int_dir/trust.pem
  - name: gate-root
    endpoint: $(cat "$root_dir/addr"):443
    role: root
    adminCertPath: $GATE_KEYDIR/admin.crt
    adminKeyPath: $GATE_KEYDIR/admin.key
    caCertPath: $root_dir/trust.pem
EOF

  pg="cryptos-gate-e2e-pg-$GATE_RUN_ID"
  db_port="${GATE_E2E_PG_PORT:-15432}"
  work2="$(mktemp -d /dev/shm/cryptos-gate-e2e.XXXXXX)"
  # shellcheck disable=SC2064 # $pg and $work2 are meant to expand now, not when the trap fires
  trap "docker rm -f '$pg' >/dev/null 2>&1; rm -rf '$work2'" RETURN

  docker run -d --rm --name "$pg" -e POSTGRES_PASSWORD=throwaway -p "$db_port:5432" postgres:18-alpine >/dev/null \
    || gate_fail "could not start the throwaway Postgres container"

  deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ] && ! gate_tcp_up 127.0.0.1 "$db_port"; do sleep 1; done
  gate_tcp_up 127.0.0.1 "$db_port" || gate_fail "the throwaway Postgres container never answered"

  image_sha="$(gate_state_get candidate-sha)"
  if ( cd "$GATE_MANAGER_DIR" \
      && E2E_DATABASE_URL="postgres://postgres:throwaway@127.0.0.1:$db_port/postgres?sslmode=disable" \
         E2E_ADMIN_EMAIL="gate-e2e@example.org" \
         E2E_NODES_FILE="$nodes" \
         E2E_WORKDIR="$work2" \
         E2E_IMAGE_URL="$url" \
         E2E_IMAGE_SIGNATURE_PATH="$w/candidate/candidate.uki.sig" \
         E2E_IMAGE_SHA256="$image_sha" \
         task e2e:esxi ); then
    gate_note "cryptos-manager's full write-path e2e run passed against the live gate nodes"
  else
    gate_fail "cryptos-manager's test/e2e/esxi failed against the live gate nodes"
  fi
}

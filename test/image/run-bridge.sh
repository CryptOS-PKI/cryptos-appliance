#!/usr/bin/env bash
# Run the bridge upgrade test: boot the bridge build (cryptos-node a77ae5b)
# in QEMU (swtpm, OVMF, Secure Boot off) as a nodeid Root, then upgrade it in
# place to the candidate with the bridge-era cryptosctl, check it with the
# current one, roll back to the bridge and upgrade again. The steps live in
# test/integration/bridge_upgrade_test.go (TestBridgeUpgrade); each reports
# pass, fail or skip in a summary table. Entry point for `task e2e:bridge` and
# the ci-e2e-image workflow's bridge job; test/image/build-bridge.sh builds
# its inputs.
#
# Linux only. Unlike run.sh it does not skip on a host without the tools: the
# bridge upgrade is a release proof, so a missing tool fails the run.
# Needs: go, qemu-system-x86_64, swtpm, sgdisk, mtools, OVMF.
#
# Environment:
#   E2E_OUT   where logs and the step summary go (default a temp dir,
#             printed at the end)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
dir="$root/build/out/bridge"

log() { printf '[e2e:bridge] %s\n' "$*" >&2; }

[ "$(uname -s)" = "Linux" ] || { log "SKIP: needs a Linux host (QEMU with KVM); this is $(uname -s)"; exit 0; }
for tool in go qemu-system-x86_64 swtpm sgdisk mformat mcopy mmd ip; do
  command -v "$tool" >/dev/null 2>&1 || { log "missing required tool: $tool"; exit 1; }
done
for f in bridge.uki bridge.uki.sig candidate.uki candidate.uki.sig cryptosctl cryptosctl-bridge versions.env; do
  [ -f "$dir/$f" ] || { log "missing $dir/$f (run test/image/build-bridge.sh first)"; exit 1; }
done
# shellcheck source=/dev/null
source "$dir/versions.env"

ovmf_code="${OVMF_CODE:-}"
ovmf_vars="${OVMF_VARS:-}"
for pair in /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd; do
  [ -n "$ovmf_code" ] && break
  if [ -f "${pair%%:*}" ] && [ -f "${pair##*:}" ]; then
    ovmf_code="${pair%%:*}" ovmf_vars="${pair##*:}"
  fi
done
[ -n "$ovmf_code" ] || { log "OVMF firmware not found (set OVMF_CODE and OVMF_VARS)"; exit 1; }

accel=tcg
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  accel=kvm
else
  log "WARNING: /dev/kvm is not usable by this user; the VM runs under TCG and every boot is much slower"
fi

# The node's revocation preflight dials its own revocation_base_url from
# inside the guest. A guest connection to a host address outside QEMU's
# 10.0.0.0/24 leaves through user networking to that address on this host,
# where a host-forward bound on it leads back to the node's port 80. The
# runner's primary address works for that the same way the kind gateway
# does in run.sh, and the test reaches it directly.
host_ip="$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')"
[ -n "$host_ip" ] || { log "could not read this host's primary IPv4 address"; exit 1; }

out="${E2E_OUT:-$(mktemp -d)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
log "accelerator: $accel, host address: $host_ip, output: $out"

set +e
(
  cd "$root" &&
    CRYPTOS_E2E_BRIDGE=1 \
      E2E_BRIDGE_UKI="$dir/bridge.uki" \
      E2E_BRIDGE_CANDIDATE_UKI="$dir/candidate.uki" \
      E2E_BRIDGE_CRYPTOSCTL="$dir/cryptosctl-bridge" \
      E2E_BRIDGE_VERSION="$E2E_BRIDGE_VERSION" \
      E2E_CANDIDATE_VERSION="$E2E_CANDIDATE_VERSION" \
      E2E_BRIDGE_HOST_IP="$host_ip" \
      E2E_IMAGE_ACCEL="$accel" \
      E2E_IMAGE_OUT="$out" \
      OVMF_CODE="$ovmf_code" OVMF_VARS="$ovmf_vars" \
      CRYPTOSCTL="$dir/cryptosctl" \
      go test -tags=integration -count=1 -v -timeout 30m -run '^TestBridgeUpgrade$' ./test/integration/
) 2>&1 | tee "$out/bridge.log"
rc=${PIPESTATUS[0]}
set -e

# A run that wrote no step table proved nothing (the test did not run, or
# skipped before its first step), so it fails rather than passing empty.
if [ "$rc" = 0 ] && [ ! -f "$out/summary.md" ]; then
  log "TestBridgeUpgrade wrote no step table; failing the run"
  rc=1
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$out/summary.md" ]; then
  cat "$out/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi
log "logs and summary: $out"
exit "$rc"

#!/usr/bin/env bash
# Run the signed-ISO test: check an ISO signed with `cryptosctl image sign`
# with tools of its own (xorriso, mtools, sbverify), boot it in QEMU (OVMF,
# Secure Boot off) on a blank disk, install a nodeid Root from it over the
# maintenance API, boot the installed disk, and upgrade that node in place to
# a second image signed the same way (cryptos-appliance#83). The steps live
# in test/integration/signed_iso_test.go (TestSignedISO); each reports pass,
# fail or skip in a summary table. Entry point for `task e2e:iso` and the
# ci-e2e-image workflow's iso job; test/image/build-iso.sh builds its inputs.
#
# Linux only. A missing tool fails the run: the signed ISO is a release
# proof, like the bridge upgrade.
# Needs: go, qemu-system-x86_64, swtpm, mtools, xorriso, OVMF, sbverify.
#
# Environment:
#   E2E_OUT   where logs and the step summary go (default a temp dir,
#             printed at the end)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
dir="$root/build/out/iso-signed"

log() { printf '[e2e:iso] %s\n' "$*" >&2; }

[ "$(uname -s)" = "Linux" ] || { log "SKIP: needs a Linux host (QEMU with KVM); this is $(uname -s)"; exit 0; }
for tool in go qemu-system-x86_64 swtpm mformat mcopy xorriso sbverify; do
  command -v "$tool" >/dev/null 2>&1 || { log "missing required tool: $tool"; exit 1; }
done
for f in cryptosctl signed-cert.pem versions.env; do
  [ -f "$dir/$f" ] || { log "missing $dir/$f (run test/image/build-iso.sh first)"; exit 1; }
done
# shellcheck source=/dev/null
source "$dir/versions.env"
signed="cryptos-amd64-vmware-nodeid-$E2E_ISO_BUILD_TAG"
for f in "first/$signed.iso" "first/$signed.uki" "next/$signed.uki" "next/$signed.uki.sig"; do
  [ -f "$dir/$f" ] || { log "missing $dir/$f (run test/image/build-iso.sh first)"; exit 1; }
done

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

out="${E2E_OUT:-$(mktemp -d)}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
log "accelerator: $accel, output: $out"

set +e
(
  cd "$root" &&
    CRYPTOS_E2E_ISO=1 \
      E2E_ISO="$dir/first/$signed.iso" \
      E2E_ISO_UKI="$dir/first/$signed.uki" \
      E2E_ISO_NEXT_UKI="$dir/next/$signed.uki" \
      E2E_ISO_CERT="$dir/signed-cert.pem" \
      E2E_ISO_VERSION="$E2E_ISO_VERSION" \
      E2E_ISO_NEXT_VERSION="$E2E_ISO_NEXT_VERSION" \
      E2E_IMAGE_ACCEL="$accel" \
      E2E_IMAGE_OUT="$out" \
      OVMF_CODE="$ovmf_code" OVMF_VARS="$ovmf_vars" \
      CRYPTOSCTL="$dir/cryptosctl" \
      go test -tags=integration -count=1 -v -timeout 30m -run '^TestSignedISO$' ./test/integration/
) 2>&1 | tee "$out/iso.log"
rc=${PIPESTATUS[0]}
set -e

# A run that wrote no step table proved nothing (the test did not run, or
# skipped before its first step), so it fails rather than passing empty.
if [ "$rc" = 0 ] && [ ! -f "$out/summary.md" ]; then
  log "TestSignedISO wrote no step table; failing the run"
  rc=1
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$out/summary.md" ]; then
  cat "$out/summary.md" >>"$GITHUB_STEP_SUMMARY"
fi
log "logs and summary: $out"
exit "$rc"

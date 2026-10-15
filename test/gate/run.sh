#!/usr/bin/env bash
# The release gate on the lab ESXi box: build the upgrade baseline and the
# candidate from this checkout with throwaway per-run keys, then install,
# upgrade with power cuts, check the state is kept, roll back, re-key the
# Intermediate and install fresh on throwaway VMs, and tear it all down.
# docs/release-gate.md lists the steps. Nothing it builds is kept or uploaded anywhere but the gate's own
# datastore folder, which teardown removes.
#
# Settings come from the runner-local file /etc/cryptos-gate/lab-esxi.env
# (GATE_ENV_FILE overrides the path) or, for a local run, from the
# environment: GATE_ESXI_URL, GATE_ESXI_THUMBPRINT, GATE_ESXI_DATASTORE,
# GATE_ESXI_POOL, GATE_ESXI_NETWORK, GATE_NTP, and the ESXi account as
# GATE_ESXI_USERNAME / GATE_ESXI_PASSWORD (exported by the runner wrapper,
# which fetches it from Sneakers). See docs/release-gate.md. There is no
# reserved address pool: the gate's VMs take a normal DHCP address on the lab
# LAN, found per VM at run time.
#
# Every line the gate prints, and the step table it writes, passes through
# gate_redact first, so no lab value reaches a log or the release notes.
#
# Optional:
#   GATE_ONLY                comma-separated step ids to run (B,1,...,13); the
#                            rest are reported as skipped
#   GATE_SUMMARY_OUT         also write the step table (Markdown) here
#   GATE_BASELINE_COMMIT     override release/pins.yaml upgrade_from
#   GATE_TOOLS_CACHE         where the key-free kernel and static tools are
#                            cached by pin (default .cache/gate/tools)
#   GATE_BUILD_TPM=0         skip the tpm candidate build (built as a build
#                            check only; TPM mode is proved in QEMU)
#   GATE_CUT_AFTER           seconds into image stage before the power cut of
#                            step 4 (default 3)
#   GATE_FIRSTBOOT_CUT_AFTER seconds into the candidate's first boot before the
#                            power cut of step 6 (default 3)
#   GATE_BOOT_TIMEOUT, GATE_DISCOVER_TIMEOUT, GATE_DISK_GB
#                            see test/gate/lib.sh
#
# Exit status: 0 every step passed or was skipped, 1 a step failed, 2 the
# settings or tools are missing.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

# shellcheck source=test/gate/lib.sh
source "$here/lib.sh"
for f in "$here"/steps/*.sh; do
  # shellcheck source=/dev/null
  source "$f"
done

gate_arch=amd64
gate_platform=vmware

# ---- builds (step B) -------------------------------------------------------------

gate_build_keys() {
  mkdir -p "$GATE_KEYDIR/bin" "$GATE_KEYDIR/K" "$GATE_KEYDIR/W"
  ( cd "$root" && go build -o "$GATE_KEYDIR/bin/cryptos-sbkey" ./cmd/cryptos-sbkey )
  "$GATE_KEYDIR/bin/cryptos-sbkey" --out-dir "$GATE_KEYDIR/K" --cn "CryptOS gate (ephemeral)" --days 1 >/dev/null
  "$GATE_KEYDIR/bin/cryptos-sbkey" --out-dir "$GATE_KEYDIR/W" --cn "CryptOS gate negative (ephemeral)" --days 1 >/dev/null
}

gate_baseline_commit() {
  if [ -n "${GATE_BASELINE_COMMIT:-}" ]; then
    printf '%s\n' "$GATE_BASELINE_COMMIT"
    return
  fi
  awk '/^upgrade_from:/{u=1; next} /^[^ ]/{u=0} u && /repo: *cryptos-node/ {
    if (match($0, /commit: *[0-9a-f]+/)) { s = substr($0, RSTART, RLENGTH); sub(/commit: */, "", s); print s; exit } }' \
    "$root/release/pins.yaml"
}

gate_build_baseline() {
  BASELINE_SB_KEY="$GATE_KEYDIR/K/sb.key" BASELINE_SB_CERT="$GATE_KEYDIR/K/sb.crt" \
    BASELINE_OUT_DIR="$GATE_WORK/baseline" BASELINE_ARCH="$gate_arch" \
    BASELINE_PLATFORM="$gate_platform" BASELINE_STATEKEY=nodeid \
    bash "$here/baseline.sh" "$(gate_baseline_commit)" >/dev/null
}

# gate_tools_key hashes every input of the kernel and the static tools, so
# the cache is keyed by pin. None of them carries key material.
gate_tools_key() {
  ( cd "$1" && cat build/ci/versions.env build/kernel/cryptos.config "build/kernel/profiles/$gate_platform.config" \
      build/kernel/build.sh build/cryptsetup/build.sh build/e2fsprogs/build.sh build/gptfdisk/build.sh \
      build/dosfstools/build.sh ) | sha256sum | cut -c1-16
}

gate_tools_files=("vmlinuz-$gate_arch" "cryptsetup-$gate_arch" "mke2fs-$gate_arch" "sgdisk-$gate_arch" "mkfs.vfat-$gate_arch")

# gate_build_candidate builds the candidate from a clean clone of this
# checkout's HEAD, signed and anchored with K, in both state-key modes, and
# the candidate cryptosctl from the pinned cryptos-node.
gate_build_candidate() {
  local src="$GATE_WORK/src" out="$GATE_WORK/candidate" cache key f tag
  git clone -q --no-local "$root" "$src"
  git -C "$src" checkout -q --detach "$(git -C "$root" rev-parse HEAD)"
  mkdir -p "$src/build/out" "$out" "$GATE_WORK/bin"

  key="$(gate_tools_key "$src")"
  cache="${GATE_TOOLS_CACHE:-$root/.cache/gate/tools}/$gate_arch-$gate_platform-$key"
  if [ -d "$cache" ]; then
    for f in "${gate_tools_files[@]}"; do cp "$cache/$f" "$src/build/out/$f"; done
    gate_note "kernel and static tools from the cache"
  else
    ( cd "$src" && task kernel:build ARCH="$gate_arch" PLATFORM="$gate_platform" \
        && task cryptsetup:build ARCH="$gate_arch" && task e2fsprogs:build ARCH="$gate_arch" \
        && task sgdisk:build ARCH="$gate_arch" && task mkfsvfat:build ARCH="$gate_arch" )
    mkdir -p "$cache.tmp"
    for f in "${gate_tools_files[@]}"; do cp "$src/build/out/$f" "$cache.tmp/$f"; done
    mv "$cache.tmp" "$cache"
  fi

  tag="$(cd "$src" && bash build/ci/artifact-name.sh)"
  for mode in nodeid tpm; do
    [ "$mode" = tpm ] && [ "${GATE_BUILD_TPM:-1}" = 0 ] && continue
    ( cd "$src" && SB_KEY="$GATE_KEYDIR/K/sb.key" SB_CERT="$GATE_KEYDIR/K/sb.crt" \
        task rootfs:build ARCH="$gate_arch" STATEKEY="$mode" \
        && task uki:assemble ARCH="$gate_arch" \
        && SB_KEY="$GATE_KEYDIR/K/sb.key" SB_CERT="$GATE_KEYDIR/K/sb.crt" task uki:sign ARCH="$gate_arch" \
        && PLATFORM="$gate_platform" STATEKEY="$mode" bash build/iso/build.sh "$gate_arch" )
    if [ "$mode" = nodeid ]; then
      cp "$src/build/out/cryptos-$gate_arch.uki" "$out/candidate.uki"
      cp "$src/build/out/cryptos-$gate_arch.uki.sig" "$out/candidate.uki.sig"
      cp "$src/build/out/cryptos-$gate_arch.uki.unsigned" "$out/candidate.uki.unsigned"
      cp "$src/build/out/cryptos-$gate_arch-$gate_platform-nodeid-$tag.iso" "$out/candidate.iso"
    else
      [ -f "$src/build/out/cryptos-$gate_arch-$gate_platform-$tag.iso" ]
      gate_note "tpm candidate builds (installed in QEMU, not here)"
    fi
  done

  ( cd "$src" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w $(bash build/ci/buildinfo.sh)" \
      -o "$GATE_WORK/bin/cryptosctl" github.com/CryptOS-PKI/cryptos-node/cmd/cryptosctl )
}

# gate_build_negative signs the candidate's unsigned UKI with W, the key no
# gate node trusts, with both signatures a real release carries.
gate_build_negative() {
  local c="$GATE_WORK/candidate"
  sbsign --key "$GATE_KEYDIR/W/sb.key" --cert "$GATE_KEYDIR/W/sb.crt" \
    --output "$c/negative.uki" "$c/candidate.uki.unsigned" >/dev/null 2>&1
  openssl dgst -sha256 -sign "$GATE_KEYDIR/W/sb.key" -out "$c/negative.uki.sig" "$c/negative.uki"
}

# gate_anchor_count <uki> <cert>: how many times the certificate's DER
# (base64, as the build stamps it) appears in the UKI's /init.
gate_anchor_count() {
  local uki="$1" cert="$2" t b64
  t="$(mktemp -d "$GATE_WORK/anchor.XXXXXX")"
  objcopy -O binary --only-section=.initrd "$uki" "$t/initrd.gz"
  ( cd "$t" && gzip -dc initrd.gz | cpio -id --quiet rootfs.squashfs )
  unsquashfs -cat "$t/rootfs.squashfs" init > "$t/init"
  b64="$(openssl x509 -in "$cert" -outform DER | base64 -w0)"
  grep -aoF "$b64" "$t/init" | wc -l
}

gate_verify_sig() {
  local pub
  pub="$(mktemp "$GATE_WORK/pub.XXXXXX")"
  openssl x509 -in "$2" -pubkey -noout > "$pub"
  openssl dgst -sha256 -verify "$pub" -signature "$1.sig" "$1" >/dev/null
}

gate_check_builds() {
  local b="$GATE_WORK/baseline" c="$GATE_WORK/candidate" k="$GATE_KEYDIR/K/sb.crt" size limit
  sbverify --cert "$k" "$b/baseline.uki" >/dev/null 2>&1 || { gate_log "baseline UKI does not verify with K"; return 1; }
  sbverify --cert "$k" "$c/candidate.uki" >/dev/null 2>&1 || { gate_log "candidate UKI does not verify with K"; return 1; }
  gate_verify_sig "$b/baseline.uki" "$k" || { gate_log "baseline .sig does not verify with K"; return 1; }
  gate_verify_sig "$c/candidate.uki" "$k" || { gate_log "candidate .sig does not verify with K"; return 1; }
  if sbverify --cert "$k" "$c/negative.uki" >/dev/null 2>&1; then
    gate_log "the negative image verifies with K"
    return 1
  fi
  [ "$(gate_anchor_count "$b/baseline.uki" "$k")" = 1 ] || { gate_log "K is not stamped exactly once in the baseline /init"; return 1; }
  [ "$(gate_anchor_count "$c/candidate.uki" "$k")" = 1 ] || { gate_log "K is not stamped exactly once in the candidate /init"; return 1; }
  # The 512 MiB ESP holds the active, .NEW and .PREV images at once; keep
  # 32 MiB of slack.
  size="$(stat -c%s "$c/candidate.uki")"
  limit=$(( (512 - 32) * 1024 * 1024 / 3 ))
  [ "$size" -le "$limit" ] || { gate_log "candidate UKI is $size bytes; three copies do not fit the ESP"; return 1; }
  gate_state_set baseline-sha "$(sha256sum "$b/baseline.uki" | cut -d' ' -f1)"
  gate_state_set candidate-sha "$(sha256sum "$c/candidate.uki" | cut -d' ' -f1)"
  gate_note "sbverify and .sig pass with K for baseline and candidate, W refused, K once in each /init, UKI $((size / 1024 / 1024)) MiB"
}

step_build() {
  gate_build_keys
  gate_build_baseline
  gate_build_candidate
  gate_build_negative
  gate_check_builds
}

# ---- main ---------------------------------------------------------------------------

gate_preflight() {
  local t missing=()
  for t in "${GATE_GOVC:-govc}" openssl perl curl sbsign sbverify objcopy unsquashfs cpio gzip go task timeout shred git sha256sum; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    gate_log "missing tools: ${missing[*]}"
    return 1
  fi
}

gate_cleanup() {
  local rc=$?
  set +e
  if [ -n "${GATE_WORK:-}" ] && [ -d "$GATE_WORK" ]; then
    gate_teardown >/dev/null 2>&1
  fi
  gate_keys_shred
  if [ -n "${GATE_WORK:-}" ] && [ "${GATE_KEEP_WORK:-}" != 1 ]; then
    rm -rf "$GATE_WORK"
  fi
  exit "$rc"
}

gate_main() {
  gate_load_env || exit 2
  gate_fetch_account || exit 2
  gate_mask_github
  gate_start_redaction

  GATE_RUN_ID="${GATE_RUN_ID:-$(date -u +%Y%m%d%H%M%S)-$$}"
  [[ "$GATE_RUN_ID" =~ ^[a-z0-9-]{1,40}$ ]] || gate_die "GATE_RUN_ID must be 1-40 of [a-z0-9-]"
  GATE_ROOT_CN="CryptOS Gate Root $GATE_RUN_ID"
  GATE_INT_CN="CryptOS Gate Intermediate $GATE_RUN_ID"
  GATE_FRESH_CN="CryptOS Gate Fresh Root $GATE_RUN_ID"
  GATE_WORK="$(mktemp -d)"
  GATE_CRYPTOSCTL="${GATE_CRYPTOSCTL:-$GATE_WORK/bin/cryptosctl}"
  export GATE_RUN_ID GATE_ROOT_CN GATE_INT_CN GATE_FRESH_CN GATE_WORK GATE_CRYPTOSCTL
  trap gate_cleanup EXIT
  trap 'exit 130' INT TERM
  gate_keys_init || exit 2
  gate_preflight || exit 2

  gate_log "run $GATE_RUN_ID"
  gate_step B "build: baseline and candidate signed with K, negative image signed with W" step_build
  gate_step 1 "baseline Root and Intermediate from the ISO, ceremonies, leaf issued, one revoked" step_baseline B
  gate_step 2 "candidate cryptosctl against the baseline nodes" step_cli_compat 1
  gate_step 3 "image signed by another key and unsigned image refused, nothing written" step_refused 1
  gate_step 4 "power cut during the ESP write: boots the baseline, state intact" step_cut_write 3
  gate_step 5 "power cut after stage, before activate: boots the candidate, state intact" step_cut_before_activate 4
  gate_step 6 "power cut during the candidate's first boot: comes up on the candidate" step_cut_first_boot 5
  gate_step 7 "state kept: CA serial and key, issued leaf, CRL, OCSP, audit chain, new leaf" step_state 6
  gate_step 8 "rollback to the baseline, state kept, still signs, upgrade again" step_rollback 7
  gate_step 9 "Root: stage, activate, state kept, still signs" step_root 1
  gate_step 10 "Intermediate re-key: new key chains to the Root, issues, revocations and audit chain kept" step_rekey 8 9
  gate_step 11 "fresh install of the candidate (nodeid) and its ceremony" step_fresh B
  gate_step 12 "Secure Boot on with K in db, W refused at boot" step_secure_boot
  gate_step 13 "teardown: VMs destroyed, datastore folder removed" step_teardown

  gate_summary
  if [ -n "${GATE_SUMMARY_OUT:-}" ]; then
    gate_summary | gate_redact > "$GATE_SUMMARY_OUT"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { printf '## ESXi release gate\n\n'; gate_summary; } | gate_redact >> "$GITHUB_STEP_SUMMARY"
  fi
  if gate_failed; then
    gate_log "gate FAILED"
    exit 1
  fi
  gate_log "gate passed"
}

if [ -z "${GATE_TEST_SOURCE_ONLY:-}" ]; then
  gate_main "$@"
fi

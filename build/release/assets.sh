#!/usr/bin/env bash
# Build every unsigned image a release ships into dist/: one UKI and one ISO
# for each platform and state-key variant below. Called by the assets job in
# release.yml and the dispatch rehearsal in ci-image.yml, so the two can't
# drift. Nothing is signed and no upgrade anchor is stamped; a build that
# carries either stops the run.
#
# VMware ships both state-key variants because a host without a key provider
# can't give a guest a vTPM. Proxmox always can, so it ships tpm only.
#
# Each variant runs the whole `task iso:unsigned` recipe; the UKI is copied out
# before the next build overwrites build/out/cryptos-<arch>.uki.unsigned.
#
# Usage: ARCH=amd64 build/release/assets.sh
set -euo pipefail

arch="${ARCH:-amd64}"
variants=("vmware:tpm" "vmware:nodeid" "proxmox:tpm")

log() { printf 'assets: %s\n' "$*" >&2; }

mkdir -p dist
# The build-number tag every artifact file name carries; build/iso/build.sh
# bakes the same one into the ISO's name.
build_tag="$(bash build/ci/artifact-name.sh)"
log "build tag $build_tag, ${#variants[@]} variants, $arch"

for variant in "${variants[@]}"; do
  platform="${variant%%:*}"
  statekey="${variant##*:}"
  suffix=""
  [ "$statekey" = nodeid ] && suffix="-nodeid"
  started=$SECONDS
  log "building $platform $statekey"
  task iso:unsigned ARCH="$arch" PLATFORM="$platform" STATEKEY="$statekey"

  # No upgrade anchor: the stamped anchor is a base64 X.509 DER string in
  # /init; the signed smoke build in ci-image.yml proves this pattern finds one.
  init="build/.work/rootfs-${arch}/init"
  if grep -q -a -E 'MII[A-Za-z0-9+/]{400,}' "$init"; then
    log "release build of $platform $statekey carries an upgrade anchor"
    exit 1
  fi
  # No Authenticode signature on the UKI.
  uki="build/out/cryptos-${arch}.uki.unsigned"
  if sbverify --list "$uki" 2>&1 | grep -q 'signature 1'; then
    log "release UKI of $platform $statekey carries a signature"
    exit 1
  fi

  cp "$uki" "dist/cryptos-${arch}-${platform}${suffix}-${build_tag}.uki.unsigned"
  cp "build/out/cryptos-${arch}-${platform}${suffix}-unsigned-${build_tag}.iso" dist/
  log "$platform $statekey done in $((SECONDS - started))s"
done
log "wrote $(find dist -maxdepth 1 -type f | wc -l | tr -d ' ') files to dist/"

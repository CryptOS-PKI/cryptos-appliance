#!/usr/bin/env bash
# Build what the signed-ISO test (test/image/run-iso.sh, TestSignedISO)
# boots: two unsigned ISOs made the way the release makes its assets, each
# then signed with `cryptosctl image sign` and one throwaway key, the way an
# operator signs a downloaded ISO (cryptos-appliance#83).
#
#   first/<release name>-unsigned-<tag>.iso   the unsigned ISO, as released
#   first/<release name>-<tag>.iso            signed by cryptosctl image sign
#   first/<release name>-<tag>.uki, .uki.sig  the signed UKI it writes beside
#                                             the ISO, and its release .sig
#   next/...                                  the same for a second build that
#                                             reports a different version
#   signed-cert.pem                           the key's certificate (public)
#   cryptosctl                                cryptosctl from the cryptos-node
#                                             module go.mod pins
#   versions.env                              each build's version string
#
# Each ISO is the release recipe (`task iso:unsigned`): the vmware kernel,
# whose AHCI, CD-ROM and ISO 9660 drivers the installer needs to read the
# ISO, a rootfs with no anchor (STATEKEY=nodeid, the variant my production
# nodes run), and build/iso/build.sh with UNSIGNED=1. The one difference is
# the UKI's qemu-dev command line instead of prod, so the test can read the
# serial console. The key lives on /dev/shm and is shredded before this
# script returns; nothing it signs is published or cached.
#
# Output in build/out/iso-signed. Linux only. Needs the image toolchain
# (build/README.md) plus xorriso, mtools and mkfs.vfat, and docker for the
# static tools.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
arch=amd64
platform=vmware
out="$root/build/out"
dest="$out/iso-signed"

log() { printf '[e2e:iso build] %s\n' "$*" >&2; }

[ "$(uname -s)" = "Linux" ] || { log "SKIP: the image builds on a Linux host; this is $(uname -s)"; exit 0; }
for tool in openssl git go xorriso mcopy mkfs.vfat; do
  command -v "$tool" >/dev/null 2>&1 || { log "missing required tool: $tool"; exit 1; }
done

cd "$root"
started=$SECONDS

# Not local to a function: the EXIT trap reads it.
keydir="$(mktemp -d /dev/shm/cryptos-iso-key.XXXXXX)"
cleanup() {
  shred -u "$keydir"/sb.* 2>/dev/null || true
  rm -rf "$keydir"
}
trap cleanup EXIT

log "kernel with the $platform drivers (reuses build/.work/kernel when it is there)"
PLATFORM="$platform" bash build/kernel/build.sh "$arch"
for tool in cryptsetup:cryptsetup e2fsprogs:mke2fs gptfdisk:sgdisk dosfstools:mkfs.vfat; do
  dir="${tool%%:*}" bin="${tool##*:}"
  if [ -x "$out/$bin-$arch" ]; then
    log "reusing $out/$bin-$arch"
  else
    log "building $bin"
    bash "build/$dir/build.sh" "$arch"
  fi
done

rm -rf "$dest"
mkdir -p "$dest"

log "cryptosctl from the pinned cryptos-node"
CGO_ENABLED=0 go build -trimpath -ldflags "$(bash build/ci/buildinfo.sh)" \
  -o "$dest/cryptosctl" github.com/CryptOS-PKI/cryptos-node/cmd/cryptosctl

log "throwaway signing key and upgrade anchor in $keydir (tmpfs)"
go run ./cmd/cryptos-sbkey --out-dir "$keydir" --cn "CryptOS signed ISO test (throwaway)" --days 2 >/dev/null
cp "$keydir/sb.crt" "$dest/signed-cert.pem"

build_tag="$(bash build/ci/artifact-name.sh)"
base_version="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
for name in first next; do
  ver="$base_version-iso-$name"
  log "unsigned ISO $ver (the release recipe)"
  CRYPTOS_VERSION="$ver" SB_CERT='' STATEKEY=nodeid bash build/squashfs/build.sh "$arch"
  if grep -q -a -E 'MII[A-Za-z0-9+/]{400,}' "$root/build/.work/rootfs-$arch/init"; then
    log "the unsigned $name build carries a build-time anchor"
    exit 1
  fi
  CRYPTOS_VERSION="$ver" bash build/uki/assemble.sh "$arch" qemu-dev
  UNSIGNED=1 PLATFORM="$platform" STATEKEY=nodeid bash build/iso/build.sh "$arch"
  iso_name="cryptos-$arch-$platform-nodeid-unsigned-$build_tag.iso"
  mkdir -p "$dest/$name"
  cp "$out/$iso_name" "$dest/$name/$iso_name"

  # The how-to in docs/secure-boot.md, step for step: sign the downloaded
  # ISO with the default output names, then check the UKI written beside it.
  "$dest/cryptosctl" image sign --image "$dest/$name/$iso_name" \
    --key "$keydir/sb.key" --cert "$keydir/sb.crt"
  signed="$dest/$name/cryptos-$arch-$platform-nodeid-$build_tag"
  for f in "$signed.iso" "$signed.uki" "$signed.uki.sig"; do
    [ -f "$f" ] || { log "cryptosctl image sign did not write $f"; exit 1; }
  done
  openssl x509 -in "$keydir/sb.crt" -pubkey -noout >"$dest/signed.pub"
  openssl dgst -sha256 -verify "$dest/signed.pub" -signature "$signed.uki.sig" "$signed.uki"
done

cat >"$dest/versions.env" <<EOF
E2E_ISO_BUILD_TAG=$build_tag
E2E_ISO_VERSION=$base_version-iso-first
E2E_ISO_NEXT_VERSION=$base_version-iso-next
EOF

found="$(find "$out" "$root/build/.work" -type f \( -name 'sb.key' -o -name 'sb.crt' -o -name 'sb.der' \) 2>/dev/null || true)"
if [ -n "$found" ]; then
  log "key material outside the tmpfs key directory:"
  printf '  %s\n' "$found" >&2
  exit 1
fi
log "wrote $dest in $((SECONDS - started))s"

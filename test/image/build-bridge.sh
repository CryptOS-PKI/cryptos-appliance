#!/usr/bin/env bash
# Build what the bridge upgrade test (test/image/run-bridge.sh,
# TestBridgeUpgrade) boots: the bridge build my production nodes run today,
# the candidate from this checkout, and the cryptosctl of each era.
#
#   bridge.uki, bridge.uki.sig        cryptos-node a77ae5b, built with that
#                                     commit's own rootfs and UKI recipe
#                                     (it predates the appliance split, so the
#                                     build lives in the cryptos-node repo)
#   candidate.uki, candidate.uki.sig  this checkout
#   cryptosctl-bridge                 cryptosctl from a77ae5b (cryptos.v1)
#   cryptosctl                        cryptosctl from the cryptos-node module
#                                     go.mod pins (cryptos.node.v1)
#   signed.uki, signed-next.uki       the candidate built unsigned and with no
#     (each with .sig and .unsigned)  build-time anchor, then signed with
#                                     `cryptosctl image sign` and a second
#                                     throwaway key, as an operator signs a
#                                     downloaded release asset; signed-next
#                                     reports a different version
#   signed-cert.pem                   that second key's certificate (public)
#   versions.env                      the version string each image reports
#
# Both images are the normal build, with no coverage instrumentation:
# STATEKEY=nodeid (the TPM-less state key my production nodes use), the
# generic kernel and the qemu-dev command line, so the suite can read the
# serial console. Both are signed (sbsign plus the detached .sig) and
# anchored with one throwaway RSA key made for this run on /dev/shm, so the
# bridge accepts the candidate and the candidate can take the next upgrade.
# The key is shredded before this script returns; nothing it signs is ever
# published or cached.
#
# The kernel and the static tools are built once with this checkout's
# recipe and handed to the bridge build: build/kernel, build/ci/versions.env
# and the static-tool recipes are byte-for-byte the same at a77ae5b.
#
# Output in build/out/bridge. Linux only. Needs the image toolchain
# (build/README.md) plus sbsigntool, and docker for the static tools.
#
# Environment:
#   BRIDGE_COMMIT   override the bridge commit (default a77ae5b..., full SHA)
#   BRIDGE_REMOTE   override the cryptos-node remote
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
arch=amd64
out="$root/build/out"
dest="$out/bridge"
commit="${BRIDGE_COMMIT:-a77ae5bf55737dec83188fe61fb615fd2fe839e1}"
remote="${BRIDGE_REMOTE:-https://github.com/CryptOS-PKI/cryptos-node.git}"

log() { printf '[e2e:bridge build] %s\n' "$*" >&2; }

[ "$(uname -s)" = "Linux" ] || { log "SKIP: the image builds on a Linux host; this is $(uname -s)"; exit 0; }
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { log "BRIDGE_COMMIT must be a full 40-hex SHA: $commit"; exit 1; }
for tool in sbsign sbverify openssl git go; do
  command -v "$tool" >/dev/null 2>&1 || { log "missing required tool: $tool"; exit 1; }
done

cd "$root"
started=$SECONDS

# Not local to a function: the EXIT trap reads them.
keydir="$(mktemp -d /dev/shm/cryptos-bridge-key.XXXXXX)"
signkeydir="$(mktemp -d /dev/shm/cryptos-bridge-signkey.XXXXXX)"
src="$(mktemp -d)"
cleanup() {
  shred -u "$keydir"/sb.* "$signkeydir"/sb.* 2>/dev/null || true
  rm -rf "$keydir" "$signkeydir" "$src"
}
trap cleanup EXIT

# Fail if a file named like signing-key material shows up outside the tmpfs
# key directory.
check_no_stray_keys() {
  local found
  found="$(find "$@" -type f \( -name 'sb.key' -o -name 'sb.crt' -o -name 'sb.der' \) 2>/dev/null || true)"
  if [ -n "$found" ]; then
    log "key material outside the tmpfs key directory:"
    printf '  %s\n' "$found" >&2
    return 1
  fi
}

log "kernel (reuses build/.work/kernel when it is there)"
PLATFORM='' bash build/kernel/build.sh "$arch"
for tool in cryptsetup:cryptsetup e2fsprogs:mke2fs gptfdisk:sgdisk dosfstools:mkfs.vfat; do
  dir="${tool%%:*}" bin="${tool##*:}"
  if [ -x "$out/$bin-$arch" ]; then
    log "reusing $out/$bin-$arch"
  else
    log "building $bin"
    bash "build/$dir/build.sh" "$arch"
  fi
done

log "throwaway signing key and upgrade anchor in $keydir (tmpfs)"
go run ./cmd/cryptos-sbkey --out-dir "$keydir" --cn "CryptOS bridge upgrade test (throwaway)" --days 2 >/dev/null
sb_key="$keydir/sb.key" sb_cert="$keydir/sb.crt"

rm -rf "$dest"
mkdir -p "$dest"

candidate_version="$(git describe --tags --always --dirty 2>/dev/null || echo dev)-candidate"
log "candidate $candidate_version (this checkout)"
CRYPTOS_VERSION="$candidate_version" SB_CERT="$sb_cert" STATEKEY=nodeid bash build/squashfs/build.sh "$arch"
CRYPTOS_VERSION="$candidate_version" bash build/uki/assemble.sh "$arch" qemu-dev
SB_KEY="$sb_key" SB_CERT="$sb_cert" bash build/uki/sign.sh "$arch"
cp "$out/cryptos-$arch.uki" "$dest/candidate.uki"
cp "$out/cryptos-$arch.uki.sig" "$dest/candidate.uki.sig"

log "fetching cryptos-node@$commit"
git init -q "$src"
git -C "$src" fetch -q --depth 1 "$remote" "$commit"
git -C "$src" checkout -q FETCH_HEAD

bridge_version="bridge-${commit:0:7}"
log "bridge $bridge_version (the commit's own rootfs and UKI recipe)"
mkdir -p "$src/build/out"
for f in vmlinuz cryptsetup mke2fs sgdisk mkfs.vfat; do
  cp "$out/$f-$arch" "$src/build/out/$f-$arch"
done
(
  cd "$src"
  CRYPTOS_VERSION="$bridge_version" SB_CERT="$sb_cert" STATEKEY=nodeid bash build/squashfs/build.sh "$arch"
  CRYPTOS_VERSION="$bridge_version" bash build/uki/assemble.sh "$arch" qemu-dev
  SB_KEY="$sb_key" SB_CERT="$sb_cert" bash build/uki/sign.sh "$arch"
)
cp "$src/build/out/cryptos-$arch.uki" "$dest/bridge.uki"
cp "$src/build/out/cryptos-$arch.uki.sig" "$dest/bridge.uki.sig"

log "cryptosctl of each era"
( cd "$src" && CGO_ENABLED=0 go build -trimpath -ldflags "$(CRYPTOS_VERSION="$bridge_version" bash build/ci/buildinfo.sh)" \
  -o "$dest/cryptosctl-bridge" ./cmd/cryptosctl )
CGO_ENABLED=0 go build -trimpath -ldflags "$(bash build/ci/buildinfo.sh)" \
  -o "$dest/cryptosctl" github.com/CryptOS-PKI/cryptos-node/cmd/cryptosctl

log "sign-time anchor: unsigned candidates signed with cryptosctl image sign"
go run ./cmd/cryptos-sbkey --out-dir "$signkeydir" --cn "CryptOS sign-time anchor test (throwaway)" --days 2 >/dev/null
for name in signed signed-next; do
  ver="$candidate_version-$name"
  # The release-asset shape: no SB_CERT, so no anchor is compiled into /init.
  CRYPTOS_VERSION="$ver" SB_CERT='' STATEKEY=nodeid bash build/squashfs/build.sh "$arch"
  if grep -q -a -E 'MII[A-Za-z0-9+/]{400,}' "$root/build/.work/rootfs-$arch/init"; then
    log "the unsigned $name build carries a build-time anchor"
    exit 1
  fi
  CRYPTOS_VERSION="$ver" bash build/uki/assemble.sh "$arch" qemu-dev
  cp "$out/cryptos-$arch.uki.unsigned" "$dest/$name.uki.unsigned"
  # The how-to in docs/secure-boot.md, step for step: sign with the default
  # output name, then check the detached signature with openssl. The
  # Authenticode check (sbverify) is a step of its own in the test.
  "$dest/cryptosctl" image sign --image "$dest/$name.uki.unsigned" \
    --key "$signkeydir/sb.key" --cert "$signkeydir/sb.crt"
  openssl x509 -in "$signkeydir/sb.crt" -pubkey -noout >"$dest/signed.pub"
  openssl dgst -sha256 -verify "$dest/signed.pub" -signature "$dest/$name.uki.sig" "$dest/$name.uki"
done
cp "$signkeydir/sb.crt" "$dest/signed-cert.pem"

cat >"$dest/versions.env" <<EOF
E2E_BRIDGE_VERSION=$bridge_version
E2E_CANDIDATE_VERSION=$candidate_version
E2E_SIGNED_VERSION=$candidate_version-signed
E2E_SIGNED_NEXT_VERSION=$candidate_version-signed-next
EOF

check_no_stray_keys "$src" "$out" "$root/build/.work"
log "wrote $dest in $((SECONDS - started))s"

#!/usr/bin/env bash
# Unit test for check-unsigned.sh: a release directory of unsigned images
# with a matching SHA256SUMS passes; an Authenticode-signed UKI (on its own
# or inside an ISO), a file sbverify cannot read, a signature, certificate
# or attestation file, a SHA256SUMS that is missing, stale or incomplete all
# fail.
#
# The images are systemd's EFI stub (a real, unsigned PE file) standing in
# for a UKI, signed with a throwaway key for the signed cases; the ISOs are
# made with the real mkfs.vfat, mtools and xorriso the way build/iso/build.sh
# makes them.
#
# Skips (exit 0) when sbsign, sbverify, xorriso, mtools, mkfs.vfat or the
# EFI stub is not available.
#
# Usage: build/release/check-unsigned_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/check-unsigned.sh"

stub="${EFI_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"
for t in sbsign sbverify xorriso mformat mcopy mmd mkfs.vfat openssl; do
  command -v "$t" >/dev/null 2>&1 || { echo "check-unsigned_test: SKIP ($t not installed)"; exit 0; }
done
[ -f "$stub" ] || { echo "check-unsigned_test: SKIP (no EFI stub at $stub)"; exit 0; }

fail=0
assert_status() {
  name="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL $name: want exit $want got $got" >&2
    fail=1
  else
    echo "ok   $name (exit $got)"
  fi
}
assert_contains() {
  name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "ok   $name" ;;
    *)
      echo "FAIL $name: missing '$needle' in: $haystack" >&2
      fail=1
      ;;
  esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=throwaway test key" \
  -keyout "$work/test.key" -out "$work/test.crt" 2>/dev/null
cp "$stub" "$work/unsigned.efi"
sbsign --key "$work/test.key" --cert "$work/test.crt" --output "$work/signed.efi" "$work/unsigned.efi" >/dev/null 2>&1

# make_iso <uki> <out.iso>: the layout build/iso/build.sh writes.
make_iso() {
  local d
  d="$(mktemp -d "$work/iso.XXXXXX")"
  truncate -s 4M "$d/esp.img"
  mkfs.vfat "$d/esp.img" >/dev/null
  mmd -i "$d/esp.img" ::EFI ::EFI/BOOT
  mcopy -i "$d/esp.img" "$1" ::EFI/BOOT/BOOTX64.EFI
  mkdir -p "$d/iso"
  cp "$d/esp.img" "$d/iso/efiboot.img"
  cp "$1" "$d/iso/cryptos.uki"
  xorriso -as mkisofs -V TEST -e efiboot.img -no-emul-boot -o "$2" "$d/iso" >/dev/null 2>&1
}

# good_dist <dir>: unsigned UKIs, ISOs, cryptosctl binaries, the build
# record and SHA256SUMS, named the way the release job names them.
good_dist() {
  local d="$1"
  mkdir -p "$d"
  cp "$work/unsigned.efi" "$d/cryptos-amd64-vmware-v0.1.0-0-gabc1234.uki.unsigned"
  cp "$work/unsigned.efi" "$d/cryptos-amd64-vmware-nodeid-v0.1.0-0-gabc1234.uki.unsigned"
  make_iso "$work/unsigned.efi" "$d/cryptos-amd64-vmware-unsigned-v0.1.0-0-gabc1234.iso"
  printf 'binary\n' > "$d/cryptosctl-linux-amd64-v0.1.0-0-gabc1234"
  printf '{}\n' > "$d/build-manifest.json"
  sums "$d"
}
sums() { ( cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' | sort -z | xargs -0 sha256sum > SHA256SUMS ); }

run() {
  out=""
  status=0
  out="$(bash "$script" "$1" 2>&1)" || status=$?
}

# Case 1: everything unsigned and summed.
good_dist "$work/good"
run "$work/good"
assert_status "unsigned release passes" 0 "$status"
assert_contains "says how many images it checked" "3 images, no signature" "$out"

# Case 2: a signed UKI.
good_dist "$work/signed-uki"
cp "$work/signed.efi" "$work/signed-uki/cryptos-amd64-vmware-v0.1.0-0-gabc1234.uki.unsigned"
sums "$work/signed-uki"
run "$work/signed-uki"
assert_status "a signed UKI fails" 1 "$status"
assert_contains "names the signed UKI" "cryptos-amd64-vmware-v0.1.0-0-gabc1234.uki.unsigned carries an Authenticode signature" "$out"

# Case 3: an ISO whose ESP holds a signed UKI.
good_dist "$work/signed-iso"
make_iso "$work/signed.efi" "$work/signed-iso/cryptos-amd64-vmware-unsigned-v0.1.0-0-gabc1234.iso"
sums "$work/signed-iso"
run "$work/signed-iso"
assert_status "an ISO with a signed UKI fails" 1 "$status"
assert_contains "names the ISO" "cryptos-amd64-vmware-unsigned-v0.1.0-0-gabc1234.iso" "$out"

# Case 4: a UKI sbverify cannot read is not taken as unsigned.
good_dist "$work/garbage"
printf 'not a PE file\n' > "$work/garbage/cryptos-amd64-vmware-v0.1.0-0-gabc1234.uki.unsigned"
sums "$work/garbage"
run "$work/garbage"
assert_status "an unreadable UKI fails" 1 "$status"

# Case 5: signature, certificate and attestation files are refused.
for f in SHA256SUMS.sig SHA256SUMS.asc cryptosctl.sigstore.json provenance.intoto.jsonl release.crt release.pem image.p7s; do
  good_dist "$work/extra-$f"
  printf 'x\n' > "$work/extra-$f/$f"
  sums "$work/extra-$f"
  run "$work/extra-$f"
  assert_status "a $f file fails" 1 "$status"
  assert_contains "names $f" "$f" "$out"
done

# Case 6: SHA256SUMS missing, stale or not covering every file.
good_dist "$work/no-sums"
mv "$work/no-sums/SHA256SUMS" "$work/no-sums-SHA256SUMS"
run "$work/no-sums"
assert_status "no SHA256SUMS fails" 1 "$status"

good_dist "$work/stale"
printf 'changed\n' >> "$work/stale/cryptosctl-linux-amd64-v0.1.0-0-gabc1234"
run "$work/stale"
assert_status "a stale SHA256SUMS fails" 1 "$status"

good_dist "$work/unlisted"
printf 'late\n' > "$work/unlisted/cryptosctl-darwin-arm64-v0.1.0-0-gabc1234"
run "$work/unlisted"
assert_status "a file missing from SHA256SUMS fails" 1 "$status"
assert_contains "names the unlisted file" "cryptosctl-darwin-arm64-v0.1.0-0-gabc1234 is not in SHA256SUMS" "$out"

# Case 7: no images at all is not a pass.
mkdir -p "$work/empty"
printf '{}\n' > "$work/empty/build-manifest.json"
sums "$work/empty"
run "$work/empty"
assert_status "no images fails" 1 "$status"

if [ "$fail" -ne 0 ]; then
  echo "check-unsigned_test: FAILED" >&2
  exit 1
fi
echo "check-unsigned_test: all cases passed"

#!/usr/bin/env bash
# Unit test for build/iso/build.sh: two builds of one commit give the same
# ISO bytes, even when they run at different times and under different
# umasks, and the ESP inside carries the UKI unchanged. A dummy UKI stands in
# for the real one; the FAT image, the ISO and its El Torito entry are made
# by the real mkfs.vfat, mtools and xorriso.
#
# Skips (exit 0) when xorriso, mtools or mkfs.vfat is not installed.
#
# Usage: build/iso/build_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for t in xorriso mformat mcopy mmd mkfs.vfat; do
  command -v "$t" >/dev/null 2>&1 || { echo "iso build_test: SKIP ($t not installed)"; exit 0; }
done

fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A throwaway repo with the scripts build.sh calls. "origin" is a fake
# github.com URL purely for the box-wide commit-guard hook; nothing is pushed.
repo="$work/repo"
mkdir -p "$repo/build/iso" "$repo/build/ci" "$repo/build/out"
cp "$here/build.sh" "$repo/build/iso/build.sh"
cp "$here/../ci/artifact-name.sh" "$repo/build/ci/artifact-name.sh"
printf 'build/out/\n' > "$repo/.gitignore"
git init -q "$repo"
git -C "$repo" remote add origin "https://github.com/example/example.git"
git -C "$repo" add -A
git -C "$repo" -c user.name=Bugs5382 \
  -c user.email=12115015+Bugs5382@users.noreply.github.com \
  commit -q -m init
head -c 300000 /dev/zero | tr '\0' 'U' > "$repo/build/out/cryptos-amd64.uki.unsigned"

build() {
  ( cd "$repo" && umask "$1" && UNSIGNED=1 PLATFORM=vmware STATEKEY=nodeid bash build/iso/build.sh amd64 >/dev/null )
  local iso
  iso="$(ls "$repo"/build/out/*.iso)"
  mv "$iso" "$work/$2.iso"
}

build 022 first
sleep 1.1
build 002 second

a="$(sha256sum "$work/first.iso" | cut -d' ' -f1)"
b="$(sha256sum "$work/second.iso" | cut -d' ' -f1)"
if [ "$a" = "$b" ]; then
  echo "ok   two builds of one commit give the same ISO"
else
  echo "FAIL two builds of one commit differ: $a vs $b" >&2
  fail=1
fi

xorriso -osirrox on -indev "$work/first.iso" -extract /efiboot.img "$work/efiboot.img" >/dev/null 2>&1
if mcopy -i "$work/efiboot.img" ::EFI/BOOT/BOOTX64.EFI - | cmp -s - "$repo/build/out/cryptos-amd64.uki.unsigned"; then
  echo "ok   the ESP carries the UKI unchanged"
else
  echo "FAIL the ESP's BOOTX64.EFI is not the UKI" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "iso build_test: FAILED" >&2
  exit 1
fi
echo "iso build_test: all cases passed"

#!/usr/bin/env bash
# Check a release directory before anything in it is attached to a release:
# the project signs nothing, so
#   - every UKI (*.uki.unsigned) and the UKI inside every ISO (/cryptos.uki
#     and the ESP's EFI/BOOT/BOOTX64.EFI) must read as unsigned: sbverify
#     --list has to say "No signature table present"; a file it cannot read
#     fails too;
#   - no signature, certificate or attestation file may be present;
#   - SHA256SUMS must exist, verify, and list every other file.
# Prints each problem and exits 1 if there is any.
#
# Usage: build/release/check-unsigned.sh <dir>
set -euo pipefail

dir="${1:?usage: check-unsigned.sh <dir>}"
[ -d "$dir" ] || { echo "check-unsigned: no such directory: $dir" >&2; exit 1; }
dir="$(cd "$dir" && pwd)"

problems=0
problem() { echo "check-unsigned: $*" >&2; problems=$((problems + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# unsigned_pe <file> <label>: sbverify reads the PE and finds no signature.
unsigned_pe() {
  local out
  if ! out="$(sbverify --list "$1" 2>&1)"; then
    problem "$2: sbverify cannot read it as a PE image"
    return
  fi
  case "$out" in
    *"No signature table present"*) ;;
    *"signature "*) problem "$2 carries an Authenticode signature" ;;
    *) problem "$2: sbverify --list gave no clear answer: $out" ;;
  esac
}

images=0
shopt -s nullglob
for f in "$dir"/*.uki.unsigned; do
  unsigned_pe "$f" "$(basename "$f")"
  images=$((images + 1))
done
for f in "$dir"/*.iso; do
  name="$(basename "$f")"
  t="$work/$name"
  mkdir -p "$t"
  if ! xorriso -osirrox on -indev "$f" -extract /cryptos.uki "$t/cryptos.uki" -extract /efiboot.img "$t/efiboot.img" >/dev/null 2>&1; then
    problem "$name: cannot extract cryptos.uki and efiboot.img"
    continue
  fi
  if ! mcopy -n -i "$t/efiboot.img" ::EFI/BOOT/BOOTX64.EFI "$t/BOOTX64.EFI" 2>/dev/null; then
    problem "$name: the ESP has no EFI/BOOT/BOOTX64.EFI"
    continue
  fi
  unsigned_pe "$t/cryptos.uki" "$name (/cryptos.uki)"
  unsigned_pe "$t/BOOTX64.EFI" "$name (ESP EFI/BOOT/BOOTX64.EFI)"
  images=$((images + 1))
done
[ "$images" -gt 0 ] || problem "no UKI or ISO in $dir"

for f in "$dir"/*; do
  name="$(basename "$f")"
  case "$name" in
    *.sig | *.asc | *.gpg | *.sigstore | *.sigstore.json | *.bundle | *.intoto.jsonl | *.att | *.cosign* | \
      *.crt | *.cer | *.pem | *.der | *.p7s | *.p7b | *.p12 | *.pfx | *.key)
      problem "$name is a signature, certificate, key or attestation file; the project ships none" ;;
  esac
done

if [ ! -f "$dir/SHA256SUMS" ]; then
  problem "no SHA256SUMS"
else
  if ! ( cd "$dir" && sha256sum --quiet -c SHA256SUMS ) >/dev/null 2>&1; then
    problem "SHA256SUMS does not verify"
  fi
  for f in "$dir"/*; do
    name="$(basename "$f")"
    [ "$name" = SHA256SUMS ] && continue
    awk -v n="$name" '{ sub(/^\*/, "", $2) } $2 == n { found = 1 } END { exit !found }' "$dir/SHA256SUMS" \
      || problem "$name is not in SHA256SUMS"
  done
fi

if [ "$problems" -ne 0 ]; then
  echo "check-unsigned: $problems problem(s); nothing may be attached" >&2
  exit 1
fi
echo "check-unsigned: $images images, no signature, SHA256SUMS covers every file"

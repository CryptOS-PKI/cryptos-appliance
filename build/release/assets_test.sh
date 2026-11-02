#!/usr/bin/env bash
# Unit test for build/release/assets.sh: it builds every platform and state-key
# variant the release ships, writes the UKI and ISO of each into dist/ under
# the published names, and stops if a build carries an upgrade anchor or a
# signature. `task` and `sbverify` are stubbed; the file names are real.
#
# Usage: build/release/assets_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/build/release" "$repo/build/ci" "$repo/bin"
cp "$here/assets.sh" "$repo/build/release/assets.sh"
cat >"$repo/build/ci/artifact-name.sh" <<'STUB'
#!/usr/bin/env bash
echo v0.0.0-0-gabc1234
STUB
chmod +x "$repo/build/ci/artifact-name.sh"

# The task stub writes what `task iso:unsigned` writes and records the call.
cat >"$repo/bin/task" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
for a in "$@"; do case "$a" in ARCH=*|PLATFORM=*|STATEKEY=*) eval "$a" ;; esac; done
echo "$PLATFORM $STATEKEY" >>"$REPO/calls"
suffix=""
[ "$STATEKEY" = nodeid ] && suffix="-nodeid"
mkdir -p "$REPO/build/out" "$REPO/build/.work/rootfs-$ARCH"
if [ "${STUB_ANCHOR:-}" = "$PLATFORM" ]; then
  printf 'MII%0500d' 0 >"$REPO/build/.work/rootfs-$ARCH/init"
else
  echo init >"$REPO/build/.work/rootfs-$ARCH/init"
fi
echo "uki $PLATFORM $STATEKEY" >"$REPO/build/out/cryptos-$ARCH.uki.unsigned"
echo "iso $PLATFORM $STATEKEY" >"$REPO/build/out/cryptos-$ARCH-$PLATFORM$suffix-unsigned-v0.0.0-0-gabc1234.iso"
STUB
cat >"$repo/bin/sbverify" <<'STUB'
#!/usr/bin/env bash
if [ -n "${STUB_SIGNED:-}" ]; then echo "signature 1"; else echo "No signature table present"; fi
STUB
chmod +x "$repo/bin/task" "$repo/bin/sbverify"

run() { (cd "$repo" && REPO="$repo" PATH="$repo/bin:$PATH" ARCH=amd64 bash build/release/assets.sh) ; }

check() {
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got [$2], want [$3]"
    fail=1
  fi
}

run >/dev/null 2>&1 || { echo "FAIL assets.sh exited non-zero"; fail=1; }
check "builds each variant once" "$(tr '\n' ';' <"$repo/calls" 2>/dev/null || true)" \
  "vmware tpm;vmware nodeid;proxmox tpm;baremetal tpm;"
want="cryptos-amd64-baremetal-unsigned-v0.0.0-0-gabc1234.iso
cryptos-amd64-baremetal-v0.0.0-0-gabc1234.uki.unsigned
cryptos-amd64-proxmox-unsigned-v0.0.0-0-gabc1234.iso
cryptos-amd64-proxmox-v0.0.0-0-gabc1234.uki.unsigned
cryptos-amd64-vmware-nodeid-unsigned-v0.0.0-0-gabc1234.iso
cryptos-amd64-vmware-nodeid-v0.0.0-0-gabc1234.uki.unsigned
cryptos-amd64-vmware-unsigned-v0.0.0-0-gabc1234.iso
cryptos-amd64-vmware-v0.0.0-0-gabc1234.uki.unsigned"
check "dist holds the published names" "$(cd "$repo/dist" && printf '%s\n' * | LC_ALL=C sort)" "$want"
check "the UKI copy is that variant's own" \
  "$(cat "$repo/dist/cryptos-amd64-proxmox-v0.0.0-0-gabc1234.uki.unsigned" 2>/dev/null || true)" "uki proxmox tpm"

# BSD grep can't take a repeat count above 255, so this case needs a GNU grep.
rm -rf "$repo/dist" "$repo/calls"
if ! printf 'MII%0500d' 0 | grep -q -a -E 'MII[A-Za-z0-9+/]{400,}' 2>/dev/null; then
  echo "skip the upgrade-anchor case ($(uname -s) grep can't run the pattern)"
elif (cd "$repo" && REPO="$repo" STUB_ANCHOR=proxmox PATH="$repo/bin:$PATH" ARCH=amd64 bash build/release/assets.sh) >/dev/null 2>&1; then
  echo "FAIL an upgrade anchor in a build did not stop the run"
  fail=1
else
  echo "ok   an upgrade anchor stops the run"
fi

rm -rf "$repo/dist" "$repo/calls"
if (cd "$repo" && REPO="$repo" STUB_SIGNED=1 PATH="$repo/bin:$PATH" ARCH=amd64 bash build/release/assets.sh) >/dev/null 2>&1; then
  echo "FAIL a signed UKI did not stop the run"
  fail=1
else
  echo "ok   a signed UKI stops the run"
fi

if [ "$fail" = 0 ]; then
  echo "assets_test: PASS"
  exit 0
fi
echo "assets_test: FAIL"
exit 1

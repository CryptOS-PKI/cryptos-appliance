#!/usr/bin/env bash
# Unit test for baseline.sh: the cache key is stable and discriminates on
# every input, a clean run keeps the signing key under /dev/shm and never
# copies key material into the cache, and a builder that leaks a key file
# into its output is caught before anything is cached.
#
# The real cryptos-node is never fetched: a throwaway repo stands in (fetched
# over file://, never github.com), with a minimal cmd/cryptos-sbkey that
# writes the same three file names the real tool does. The heavy image build
# (task iso: kernel, static tools, mksquashfs, sbsign) is replaced by
# BASELINE_BUILDER, a shell snippet the real baseline.sh runs in its place;
# everything around it (the fetch, the real `go build` of cryptos-sbkey, the
# tmpfs key directory, the cache copy and the key-leak check) is exercised for
# real. See CLAUDE.md "No mocking third-party code": task iso is CryptOS's own
# build step, not a third party, and the brief that asked for this script
# allows testing its logic when a full image build does not fit in a test run.
#
# Usage: test/gate/baseline_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/baseline.sh"

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

assert_not_contains() {
  name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      echo "FAIL $name: unexpectedly found '$needle'" >&2
      fail=1
      ;;
    *) echo "ok   $name" ;;
  esac
}

# --- cache_key: source the script for its functions only (BASELINE_TEST_SOURCE_ONLY
# skips main so sourcing it has no side effects). ---
BASELINE_TEST_SOURCE_ONLY=1 source "$script"

k1="$(cache_key aaaa amd64 vmware nodeid)"
k2="$(cache_key aaaa amd64 vmware nodeid)"
assert_status "cache_key is deterministic" "$k1" "$k2"
assert_not_contains "cache_key varies with commit" "$k1" "$(cache_key bbbb amd64 vmware nodeid)"
assert_not_contains "cache_key varies with arch" "$k1" "$(cache_key aaaa arm64 vmware nodeid)"
assert_not_contains "cache_key varies with platform" "$k1" "$(cache_key aaaa amd64 baremetal nodeid)"
assert_not_contains "cache_key varies with statekey" "$k1" "$(cache_key aaaa amd64 vmware tpm)"

# --- fixture: a throwaway "cryptos-node" with a stand-in cryptos-sbkey ---
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkfixture() {
  local bare="$work/remote.git" src="$work/src"
  git init -q --bare "$bare"
  git init -q "$src"
  mkdir -p "$src/cmd/cryptos-sbkey"
  cat > "$src/go.mod" <<'EOF'
module github.com/CryptOS-PKI/cryptos-node

go 1.26
EOF
  # Writes the same three file names the real cmd/cryptos-sbkey writes, so
  # baseline.sh's key handling (placement, export, cleanup, leak check) runs
  # against real files with the real names, without a Linux image toolchain.
  cat > "$src/cmd/cryptos-sbkey/main.go" <<'EOF'
package main

import (
	"flag"
	"os"
	"path/filepath"
)

func main() {
	outDir := flag.String("out-dir", ".", "")
	flag.String("cn", "", "")
	flag.Int("days", 0, "")
	flag.Parse()
	for _, name := range []string{"sb.key", "sb.crt", "sb.der"} {
		if err := os.WriteFile(filepath.Join(*outDir, name), []byte("test-key-material\n"), 0o600); err != nil {
			panic(err)
		}
	}
}
EOF
  # "origin" is a fake github.com URL purely for the box-wide commit-guard
  # hook (keyed on the remote host); the commit is pushed to "bare" below.
  git -C "$src" remote add origin "https://github.com/example/cryptos-node.git"
  git -C "$src" remote add bare "$bare"
  git -C "$src" add -A
  git -C "$src" -c user.name=Bugs5382 \
    -c user.email=12115015+Bugs5382@users.noreply.github.com \
    commit -q -m "init fixture"
  git -C "$src" push -q bare HEAD:refs/heads/main
  git -C "$src" rev-parse HEAD
}

commit="$(mkfixture)"
cache_dir="$work/cache"

# Case 1: a clean run. The fake builder stands in for `task iso`, writing the
# artifact `task iso` would, and echoes $SB_KEY/$SB_CERT's path so the test
# can check they sit under /dev/shm without ever reading the key bytes.
out=""
status=0
out="$(
  BASELINE_REMOTE="$work/remote.git" \
  BASELINE_CACHE_DIR="$cache_dir" \
  BASELINE_BUILDER='mkdir -p build/out && echo "SB_KEY=$SB_KEY SB_CERT=$SB_CERT" && printf "dummy iso\n" > "build/out/cryptos-${ARCH}-${PLATFORM}-nodeid.iso"' \
  bash "$script" "$commit" 2>&1
)" || status=$?
assert_status "clean run" 0 "$status"
assert_contains "clean run reports the key dir" "SB_KEY=/dev/shm/" "$out"
assert_contains "clean run reports the output path" "$cache_dir/baseline-$(cache_key "$commit" amd64 vmware nodeid).iso" "$out"

artifact="$cache_dir/baseline-$(cache_key "$commit" amd64 vmware nodeid).iso"
if [ -f "$artifact" ]; then
  echo "ok   artifact written"
  contents="$(cat "$artifact")"
  assert_not_contains "written artifact excludes key material" "test-key-material" "$contents"
else
  echo "FAIL artifact written: $artifact not found" >&2
  fail=1
fi

# Case 2: a second standalone run rebuilds rather than reusing the first
# run's artifact. Standalone mode signs with its own throwaway key, shredded
# at the end of the run; serving a prior run's ISO from a cache would hand
# back an image anchored to a key that no longer exists. The two runs write
# different content, so a reused artifact is distinguishable from a fresh
# build.
out=""
status=0
out="$(
  BASELINE_REMOTE="$work/remote.git" \
  BASELINE_CACHE_DIR="$cache_dir" \
  BASELINE_BUILDER='mkdir -p build/out && echo "SB_KEY=$SB_KEY SB_CERT=$SB_CERT" && printf "dummy iso run2\n" > "build/out/cryptos-${ARCH}-${PLATFORM}-nodeid.iso"' \
  bash "$script" "$commit" 2>&1
)" || status=$?
assert_status "second run" 0 "$status"
assert_not_contains "second run is not served from a cache" "cache hit" "$out"
second_contents="$(cat "$artifact")"
assert_status "second run rebuilds (artifact holds the new content)" "dummy iso run2" "$second_contents"

# Case 3: a builder that leaks a key file into its output tree is caught
# before anything is cached, and the leaked cache entry is not created.
leak_cache_dir="$work/cache-leak"
out=""
status=0
out="$(
  BASELINE_REMOTE="$work/remote.git" \
  BASELINE_CACHE_DIR="$leak_cache_dir" \
  BASELINE_BUILDER='mkdir -p build/out && cp "$SB_KEY" build/out/sb.key && printf "dummy iso\n" > "build/out/cryptos-${ARCH}-${PLATFORM}-nodeid.iso"' \
  bash "$script" "$commit" 2>&1
)" || status=$?
assert_status "leaked key is rejected" 1 "$status"
assert_contains "leaked key message" "key material" "$out"
leak_artifact="$leak_cache_dir/baseline-$(cache_key "$commit" amd64 vmware nodeid).iso"
if [ -f "$leak_artifact" ]; then
  echo "FAIL leaked key: artifact was cached despite the leak" >&2
  fail=1
else
  echo "ok   leaked key: nothing cached"
fi

# Case 4: the gate's own key. With BASELINE_SB_KEY/BASELINE_SB_CERT the build
# is signed and anchored with that key (the gate signs the baseline and the
# candidate with one key K, so the baseline accepts the candidate), the image
# and its UKI go to BASELINE_OUT_DIR, nothing is cached (the image carries a
# per-run anchor), and the caller's key files are left for the caller to
# shred.
gate_keydir="$(mktemp -d /dev/shm/cryptos-gate-baseline-test.XXXXXX)"
printf 'gate-key\n' > "$gate_keydir/sb.key"
printf 'gate-cert\n' > "$gate_keydir/sb.crt"
gate_out="$work/gate-out"
gate_cache="$work/cache-gate"
out=""
status=0
out="$(
  BASELINE_REMOTE="$work/remote.git" \
  BASELINE_CACHE_DIR="$gate_cache" \
  BASELINE_SB_KEY="$gate_keydir/sb.key" BASELINE_SB_CERT="$gate_keydir/sb.crt" \
  BASELINE_OUT_DIR="$gate_out" \
  BASELINE_BUILDER='mkdir -p build/out && echo "SB_KEY=$SB_KEY SB_CERT=$SB_CERT" && printf "dummy iso\n" > "build/out/cryptos-${ARCH}-${PLATFORM}-nodeid.iso" && printf "dummy uki\n" > "build/out/cryptos-${ARCH}.uki" && printf "dummy sig\n" > "build/out/cryptos-${ARCH}.uki.sig"' \
  bash "$script" "$commit" 2>&1
)" || status=$?
assert_status "gate key run" 0 "$status"
assert_contains "gate key run uses the given key" "SB_KEY=$gate_keydir/sb.key SB_CERT=$gate_keydir/sb.crt" "$out"
assert_contains "gate key run prints the output ISO" "$gate_out/baseline.iso" "$out"
for f in baseline.iso baseline.uki baseline.uki.sig; do
  if [ -f "$gate_out/$f" ]; then echo "ok   gate key run wrote $f"; else echo "FAIL gate key run: $gate_out/$f missing" >&2; fail=1; fi
done
if [ -n "$(find "$gate_cache" -type f 2>/dev/null)" ]; then
  echo "FAIL gate key run: something was cached in $gate_cache" >&2
  fail=1
else
  echo "ok   gate key run caches nothing"
fi
if [ -f "$gate_keydir/sb.key" ] && [ -f "$gate_keydir/sb.crt" ]; then
  echo "ok   gate key run leaves the caller's key in place"
else
  echo "FAIL gate key run: the caller's key files were removed" >&2
  fail=1
fi
rm -rf "$gate_keydir"

# Case 5: a given key outside /dev/shm is refused before anything is fetched.
disk_keydir="$work/disk-key"
mkdir -p "$disk_keydir"
printf 'k\n' > "$disk_keydir/sb.key"
printf 'c\n' > "$disk_keydir/sb.crt"
out=""
status=0
out="$(
  BASELINE_REMOTE="$work/remote.git" \
  BASELINE_SB_KEY="$disk_keydir/sb.key" BASELINE_SB_CERT="$disk_keydir/sb.crt" \
  BASELINE_OUT_DIR="$work/disk-out" \
  BASELINE_BUILDER='exit 0' \
  bash "$script" "$commit" 2>&1
)" || status=$?
assert_status "key outside tmpfs is refused" 1 "$status"
assert_contains "key outside tmpfs message" "/dev/shm" "$out"

if [ "$fail" -ne 0 ]; then
  echo "baseline_test: FAILED" >&2
  exit 1
fi
echo "baseline_test: all cases passed"

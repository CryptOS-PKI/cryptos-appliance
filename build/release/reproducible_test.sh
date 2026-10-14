#!/usr/bin/env bash
# Unit test for reproducible.sh: two clean workspaces are cloned from one
# commit, a builder runs in each, and every output is compared by SHA-256.
#
# The heavy image build (task iso:unsigned: kernel, static tools, mksquashfs,
# ukify, xorriso) is replaced by REPRO_BUILDER, a shell snippet reproducible.sh
# runs in its place in each workspace; the clone, the clean-tree check, the
# hashing, the comparison and the report run for real. The real build is run
# by `task release:reproducible` and the release workflow.
#
# Usage: build/release/reproducible_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/reproducible.sh"

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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A throwaway source repo standing in for this one. "origin" is a fake
# github.com URL purely for the box-wide commit-guard hook (keyed on the remote
# host); nothing is pushed.
repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin "https://github.com/example/example.git"
printf 'source\n' > "$repo/README"
git -C "$repo" add README
git -C "$repo" -c user.name=Bugs5382 \
  -c user.email=12115015+Bugs5382@users.noreply.github.com \
  commit -q -m init
git -C "$repo" tag v0.1.0
commit="$(git -C "$repo" rev-parse HEAD)"

# Case 1: a deterministic builder. Both workspaces write the same bytes, the
# file name carries the workspace's own build tag (git describe), so it is the
# same in both clones too.
det='mkdir -p build/out && git describe --tags --long > build/out/cryptos-amd64.uki.unsigned && cp build/out/cryptos-amd64.uki.unsigned "build/out/cryptos-amd64-vmware-nodeid-unsigned-$(git describe --tags --long).iso"'
out=""
status=0
out="$(REPRO_SOURCE="$repo" REPRO_BUILDER="$det" bash "$script" 2>&1)" || status=$?
assert_status "deterministic builder passes" 0 "$status"
assert_contains "reports the commit" "$commit" "$out"
assert_contains "lists the UKI" "cryptos-amd64.uki.unsigned" "$out"
assert_contains "lists the ISO" "cryptos-amd64-vmware-nodeid-unsigned-v0.1.0-0-g" "$out"
assert_contains "says identical" "reproducible: 2 files identical" "$out"

# Case 2: a builder that stamps the wall clock and a random value into one
# file. The run fails and names that file, and not the identical one.
nondet='mkdir -p build/out && printf same > build/out/cryptos-amd64.uki.unsigned && { date +%s%N; head -c 16 /dev/urandom | od -An -tx1; } > build/out/cryptos-amd64-vmware-nodeid-unsigned.iso'
out=""
status=0
out="$(REPRO_SOURCE="$repo" REPRO_BUILDER="$nondet" bash "$script" 2>&1)" || status=$?
assert_status "non-deterministic builder fails" 1 "$status"
assert_contains "names the differing file" "DIFFERS  cryptos-amd64-vmware-nodeid-unsigned.iso" "$out"
assert_contains "the identical file is marked same" "same     cryptos-amd64.uki.unsigned" "$out"

# Case 3: a file only one workspace produced is a difference too.
oneside='mkdir -p build/out && printf same > build/out/cryptos-amd64.uki.unsigned && case "$PWD" in */ws1) printf x > build/out/only-in-one ;; esac'
out=""
status=0
out="$(REPRO_SOURCE="$repo" REPRO_BUILDER="$oneside" bash "$script" 2>&1)" || status=$?
assert_status "a file in one workspace only fails" 1 "$status"
assert_contains "names the missing file" "MISSING  only-in-one" "$out"

# Case 4: a builder that produces nothing fails rather than passing on zero files.
out=""
status=0
out="$(REPRO_SOURCE="$repo" REPRO_BUILDER='mkdir -p build/out' bash "$script" 2>&1)" || status=$?
assert_status "no outputs fails" 1 "$status"
assert_contains "no outputs message" "no build outputs" "$out"

# Case 5: a dirty source tree is refused: the clones would not match it.
printf 'local change\n' >> "$repo/README"
out=""
status=0
out="$(REPRO_SOURCE="$repo" REPRO_BUILDER="$det" bash "$script" 2>&1)" || status=$?
assert_status "dirty source is refused" 1 "$status"
assert_contains "dirty source message" "uncommitted changes" "$out"
git -C "$repo" checkout -q README

# Case 6: the workspaces are removed afterwards unless REPRO_KEEP is set.
keep="$work/keep"
out=""
status=0
out="$(REPRO_SOURCE="$repo" REPRO_BUILDER="$det" REPRO_WORK="$keep" bash "$script" 2>&1)" || status=$?
assert_status "run with REPRO_WORK" 0 "$status"
if [ -e "$keep/ws1" ] || [ -e "$keep/ws2" ]; then
  echo "FAIL workspaces removed: $keep still holds a workspace" >&2
  fail=1
else
  echo "ok   workspaces removed"
fi
out=""
status=0
out="$(REPRO_SOURCE="$repo" REPRO_BUILDER="$det" REPRO_WORK="$keep" REPRO_KEEP=1 bash "$script" 2>&1)" || status=$?
assert_status "run with REPRO_KEEP" 0 "$status"
if [ -d "$keep/ws1/build/out" ] && [ -d "$keep/ws2/build/out" ]; then
  echo "ok   REPRO_KEEP keeps both workspaces"
else
  echo "FAIL REPRO_KEEP: workspaces not kept under $keep" >&2
  fail=1
fi
assert_not_contains "REPRO_KEEP run still passes" "DIFFERS" "$out"

if [ "$fail" -ne 0 ]; then
  echo "reproducible_test: FAILED" >&2
  exit 1
fi
echo "reproducible_test: all cases passed"

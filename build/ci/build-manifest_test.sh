#!/usr/bin/env bash
# Unit test for build-manifest.sh: builds a throwaway repo (fake github.com
# remote, see artifact-name_test.sh for why) and checks the printed JSON
# carries the full and short SHA, the build tag, and every artifact name given.
# Usage: build/ci/build-manifest_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
assert_contains() {
  name="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) echo "ok   $name" ;;
    *)
      echo "FAIL $name: missing '$needle'" >&2
      fail=1
      ;;
  esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
git init -q "$repo"
git -C "$repo" remote add origin "https://github.com/example/example.git"
git -C "$repo" -c user.name=Bugs5382 \
  -c user.email=12115015+Bugs5382@users.noreply.github.com \
  commit -q --allow-empty -m init
git -C "$repo" tag v0.1.0
commit="$(git -C "$repo" rev-parse HEAD)"
short="$(git -C "$repo" rev-parse --short HEAD)"

mkdir -p "$repo/build/ci"
cp "$here/artifact-name.sh" "$repo/build/ci/artifact-name.sh"
cp "$here/build-manifest.sh" "$repo/build/ci/build-manifest.sh"

out="$(cd "$repo" && bash build/ci/build-manifest.sh dist/cryptos-amd64-vmware-v0.1.0.iso dist/cryptosctl-linux-amd64)"

assert_contains "full commit" "\"commit\": \"$commit\"" "$out"
assert_contains "short commit" "\"short_commit\": \"$short\"" "$out"
assert_contains "build tag" "\"build_tag\": \"v0.1.0-0-g$short\"" "$out"
assert_contains "clean tree" "\"dirty\": false" "$out"
assert_contains "first artifact" "cryptos-amd64-vmware-v0.1.0.iso" "$out"
assert_contains "second artifact" "cryptosctl-linux-amd64" "$out"

if [ "$fail" -ne 0 ]; then
  echo "build-manifest_test: FAILED" >&2
  exit 1
fi
echo "build-manifest_test: all cases passed"

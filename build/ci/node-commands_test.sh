#!/usr/bin/env bash
# Unit test for the cryptos-node commands the image build compiles from this
# module (init, cryptosctl and cryptos-console; build/squashfs/build.sh and
# the release cross-builds). No package here imports them, so go.mod lists
# them as tool directives; without that, `go mod tidy` drops the modules only
# they need (go-buildinfo, for one) and the image build fails on a missing
# go.sum entry. This checks the directives are there and that every command
# resolves its whole import graph on each target the build produces.
# Usage: build/ci/node-commands_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
node="github.com/CryptOS-PKI/cryptos-node/cmd"
fail=0

tools="$(cd "$root" && go mod edit -json | sed -n 's/^[[:space:]]*"Path": "\(github.com\/CryptOS-PKI\/cryptos-node\/cmd\/[^"]*\)".*/\1/p')"

for cmd in init cryptosctl cryptos-console; do
  if ! grep -qx "$node/$cmd" <<<"$tools"; then
    echo "FAIL go.mod has no tool directive for $node/$cmd"
    fail=1
  fi
done

# lists checks one command resolves every package it imports for a target.
lists() {
  local goos="$1" goarch="$2" cmd="$3" out
  if ! out="$(cd "$root" && GOFLAGS=-mod=readonly CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go list -deps "$node/$cmd" 2>&1 >/dev/null)"; then
    echo "FAIL $cmd does not resolve for $goos/$goarch:"
    echo "$out"
    fail=1
  fi
}

for arch in amd64 arm64; do
  for cmd in init cryptosctl cryptos-console; do
    lists linux "$arch" "$cmd"
  done
  lists darwin "$arch" cryptosctl
done

if [ "$fail" = 0 ]; then
  echo "node-commands_test: PASS"
  exit 0
fi
echo "node-commands_test: FAIL"
exit 1

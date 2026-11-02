#!/usr/bin/env bash
# Unit test for buildinfo.sh: the version and commit stamped into the node's
# internal/buildinfo are stamped into github.com/Bugs5382/go-buildinfo too,
# with the same values, so cryptosctl reports them whichever package it reads.
# Usage: build/ci/buildinfo_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/buildinfo.sh"
node="github.com/CryptOS-PKI/cryptos-node/internal/buildinfo"
lib="github.com/Bugs5382/go-buildinfo"
fail=0

# value prints the value a flag set gives var (e.g. pkg.Version), or nothing.
value() {
  local flags="$1" var="$2" prev="" f
  for f in $flags; do
    if [ "$prev" = "-X" ] && [ "${f%%=*}" = "$var" ]; then
      printf '%s' "${f#*=}"
      return
    fi
    prev="$f"
  done
}

check() {
  local name="$1" flags="$2" want_commit="$3" v
  for v in Version Commit; do
    local a b
    a="$(value "$flags" "$node.$v")"
    b="$(value "$flags" "$lib.$v")"
    if [ "$a" != "$b" ]; then
      echo "FAIL $name: $lib.$v is '$b', $node.$v is '$a'"
      fail=1
    fi
  done
  if [ "$(value "$flags" "$node.Version")" = "" ]; then
    echo "FAIL $name: no version stamped: $flags"
    fail=1
  fi
  if [ "$want_commit" = yes ] && [ "$(value "$flags" "$lib.Commit")" = "" ]; then
    echo "FAIL $name: no commit stamped: $flags"
    fail=1
  fi
}

# This checkout: git metadata, so a version and a commit.
check "checkout" "$(CRYPTOS_VERSION=v9.9.9-test bash "$script")" yes
if [ "$(value "$(CRYPTOS_VERSION=v9.9.9-test bash "$script")" "$lib.Version")" != "v9.9.9-test" ]; then
  echo "FAIL checkout: CRYPTOS_VERSION does not reach $lib.Version"
  fail=1
fi

# A source tarball: no git, so "dev" and no commit, for both packages.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/build/ci"
cp "$script" "$tmp/build/ci/buildinfo.sh"
flags="$(GIT_CEILING_DIRECTORIES="$tmp" bash "$tmp/build/ci/buildinfo.sh")"
check "no git" "$flags" no
if [ "$(value "$flags" "$lib.Version")" != "dev" ]; then
  echo "FAIL no git: $lib.Version is not dev: $flags"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "buildinfo_test: PASS"
  exit 0
fi
echo "buildinfo_test: FAIL"
exit 1

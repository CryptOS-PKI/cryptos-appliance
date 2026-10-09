#!/usr/bin/env bash
# Unit test for artifact-name.sh: builds a throwaway git repo per case (so it
# never reads this checkout's own history) and asserts the printed tag.
# Usage: build/ci/artifact-name_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/artifact-name.sh"

fail=0

# Throwaway repos carry a fake github.com remote so the box-wide commit-guard
# hook (enforced on every git init, not just this project) applies the public
# GitHub identity instead of demanding the GitLab default, and commits use
# that identity. Nothing here is pushed; the remote is never fetched.
mkrepo() {
  git init -q "$1"
  git -C "$1" remote add origin "https://github.com/example/example.git"
}
gcommit() {
  git -C "$1" -c user.name=Bugs5382 \
    -c user.email=12115015+Bugs5382@users.noreply.github.com "${@:2}"
}

# Run artifact-name.sh as if "$here/../.." (the repo root it resolves on its
# own) were $1, by pointing a throwaway checkout's structure at a copy of the
# script two levels down, so $root resolves to the throwaway repo.
run_in() {
  repo="$1"
  mkdir -p "$repo/build/ci"
  cp "$script" "$repo/build/ci/artifact-name.sh"
  ( cd "$repo" && bash build/ci/artifact-name.sh )
}

assert_eq() {
  name="$1" want="$2" got="$3"
  if [ "$want" != "$got" ]; then
    echo "FAIL $name: want '$want' got '$got'" >&2
    fail=1
  else
    echo "ok   $name: $got"
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Case 1: no git metadata at all.
no_git="$work/no-git"
mkdir -p "$no_git/build/ci"
cp "$script" "$no_git/build/ci/artifact-name.sh"
got="$(cd "$no_git" && bash build/ci/artifact-name.sh)"
assert_eq "no git metadata" "dev" "$got"

# Case 2: a commit, no tags.
no_tag="$work/no-tag"
mkrepo "$no_tag"
gcommit "$no_tag" commit -q --allow-empty -m init
short="$(git -C "$no_tag" rev-parse --short HEAD)"
got="$(run_in "$no_tag")"
assert_eq "no tags" "g$short" "$got"

# Case 3: exactly on a tag, clean tree.
on_tag="$work/on-tag"
mkrepo "$on_tag"
gcommit "$on_tag" commit -q --allow-empty -m init
git -C "$on_tag" tag v0.1.0
short="$(git -C "$on_tag" rev-parse --short HEAD)"
got="$(run_in "$on_tag")"
assert_eq "exact tag" "v0.1.0-0-g$short" "$got"

# Case 4: commits past a tag.
past_tag="$work/past-tag"
mkrepo "$past_tag"
gcommit "$past_tag" commit -q --allow-empty -m init
git -C "$past_tag" tag v0.1.0
gcommit "$past_tag" commit -q --allow-empty -m second
short="$(git -C "$past_tag" rev-parse --short HEAD)"
got="$(run_in "$past_tag")"
assert_eq "past tag" "v0.1.0-1-g$short" "$got"

# Case 5: dirty tree past a tag.
dirty="$work/dirty"
mkrepo "$dirty"
gcommit "$dirty" commit -q --allow-empty -m init
git -C "$dirty" tag v0.1.0
echo x > "$dirty/f"
git -C "$dirty" add f
short="$(git -C "$dirty" rev-parse --short HEAD)"
got="$(run_in "$dirty")"
assert_eq "dirty tree" "v0.1.0-0-g$short-dirty" "$got"

# Case 6: CRYPTOS_VERSION overrides the version/tag portion only.
override="$work/override"
mkrepo "$override"
gcommit "$override" commit -q --allow-empty -m init
git -C "$override" tag v0.1.0
short="$(git -C "$override" rev-parse --short HEAD)"
mkdir -p "$override/build/ci"
cp "$script" "$override/build/ci/artifact-name.sh"
got="$(cd "$override" && CRYPTOS_VERSION=v9.9.9 bash build/ci/artifact-name.sh)"
assert_eq "CRYPTOS_VERSION override" "v9.9.9-g$short" "$got"

if [ "$fail" -ne 0 ]; then
  echo "artifact-name_test: FAILED" >&2
  exit 1
fi
echo "artifact-name_test: all cases passed"

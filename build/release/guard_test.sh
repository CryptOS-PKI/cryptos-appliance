#!/usr/bin/env bash
# Unit test for guard.sh: builds throwaway bare repos to stand in for the
# five pinned repos (fetched over file://, never github.com) plus a throwaway
# go.mod, and checks the guard accepts a good pin set and rejects a missing
# pin, a short SHA, an unreachable commit and a cryptos-node pin that
# disagrees with go.mod.
# Usage: build/release/guard_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard="$here/guard.sh"

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

# A throwaway bare repo per service repo, each with one commit, so guard.sh's
# reachability check (git fetch over file://) has something real to fetch.
mkbare() {
  local name="$1"
  local bare="$work/remotes/$name.git"
  local src="$work/src-$name"
  mkdir -p "$work/remotes"
  git init -q --bare "$bare"
  git init -q "$src"
  # "origin" is a fake github.com URL purely so the box-wide commit-guard hook
  # (keyed on the remote host, see artifact-name_test.sh) grants the public
  # GitHub identity; the commit is actually pushed to "bare" below.
  git -C "$src" remote add origin "https://github.com/example/$name.git"
  git -C "$src" remote add bare "$bare"
  git -C "$src" -c user.name=Bugs5382 \
    -c user.email=12115015+Bugs5382@users.noreply.github.com \
    commit -q --allow-empty -m "init $name"
  git -C "$src" push -q bare HEAD:refs/heads/main
  git -C "$src" rev-parse HEAD
}

node_sha="$(mkbare cryptos-node)"
manager_sha="$(mkbare cryptos-manager)"
web_sha="$(mkbare cryptos-web)"
release_sha="$(mkbare cryptos-release)"
website_sha="$(mkbare website)"

# A commit that exists nowhere (not pushed to any remote): 40 hex chars,
# well-formed but unreachable.
unreachable_sha="0123456789abcdef0123456789abcdef01234567"

remotes_env=(
  "GUARD_REMOTE_CRYPTOS_NODE=$work/remotes/cryptos-node.git"
  "GUARD_REMOTE_CRYPTOS_MANAGER=$work/remotes/cryptos-manager.git"
  "GUARD_REMOTE_CRYPTOS_WEB=$work/remotes/cryptos-web.git"
  "GUARD_REMOTE_CRYPTOS_RELEASE=$work/remotes/cryptos-release.git"
  "GUARD_REMOTE_WEBSITE=$work/remotes/website.git"
)

write_gomod() {
  local hash="$1" file="$work/go.mod"
  cat > "$file" <<EOF
module github.com/CryptOS-PKI/cryptos-appliance

go 1.26.8

require (
	github.com/CryptOS-PKI/cryptos-node v0.0.0-20261006202821-${hash}
)
EOF
  printf '%s' "$file"
}

write_pins() {
  local file="$work/pins.yaml"
  cat > "$file" <<EOF
version: 1
release: v0.1.0-rc.1
repos:
  cryptos-node:     {commit: $1}
  cryptos-manager:  {commit: $2}
  cryptos-web:      {commit: $3}
  cryptos-release:  {commit: $4}
  website:          {commit: $5}
upgrade_from:
  - {repo: cryptos-node, commit: $6}
EOF
  printf '%s' "$file"
}

run_guard() {
  local pins="$1" gomod="$2"
  env "${remotes_env[@]}" GUARD_GO_MOD="$gomod" bash "$guard" "$pins"
}

# Case 1: a good pin set, everything reachable, go.mod matches.
gomod="$(write_gomod "${node_sha:0:12}")"
pins="$(write_pins "$node_sha" "$manager_sha" "$web_sha" "$release_sha" "$website_sha" "$node_sha")"
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "good pin set" 0 "$status"
assert_contains "good pin set message" "guard: OK" "$out"

# Case 2: a missing pin (cryptos-release absent from the repos block).
pins="$work/pins-missing.yaml"
cat > "$pins" <<EOF
version: 1
release: v0.1.0-rc.1
repos:
  cryptos-node:     {commit: $node_sha}
  cryptos-manager:  {commit: $manager_sha}
  cryptos-web:      {commit: $web_sha}
  website:          {commit: $website_sha}
upgrade_from:
  - {repo: cryptos-node, commit: $node_sha}
EOF
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "missing pin" 1 "$status"
assert_contains "missing pin message" "missing pin: cryptos-release" "$out"

# Case 3: a short SHA.
pins="$(write_pins "${node_sha:0:12}" "$manager_sha" "$web_sha" "$release_sha" "$website_sha" "$node_sha")"
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "short SHA" 1 "$status"
assert_contains "short SHA message" "not a full 40-hex" "$out"

# Case 4: an unreachable commit (well-formed, pushed nowhere).
pins="$(write_pins "$node_sha" "$manager_sha" "$web_sha" "$unreachable_sha" "$website_sha" "$node_sha")"
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "unreachable commit" 1 "$status"
assert_contains "unreachable commit message" "unreachable commit for cryptos-release" "$out"

# Case 5: cryptos-node pin disagrees with go.mod.
other_gomod="$(write_gomod "${manager_sha:0:12}")"
pins="$(write_pins "$node_sha" "$manager_sha" "$web_sha" "$release_sha" "$website_sha" "$node_sha")"
out=""
status=0
out="$(run_guard "$pins" "$other_gomod" 2>&1)" || status=$?
assert_status "go.mod mismatch" 1 "$status"
assert_contains "go.mod mismatch message" "disagrees with go.mod" "$out"

# Case 6: no pins file at all.
out=""
status=0
out="$(run_guard "$work/does-not-exist.yaml" "$gomod" 2>&1)" || status=$?
assert_status "missing pins file" 1 "$status"
assert_contains "missing pins file message" "pins file not found" "$out"

if [ "$fail" -ne 0 ]; then
  echo "guard_test: FAILED" >&2
  exit 1
fi
echo "guard_test: all cases passed"

#!/usr/bin/env bash
# Build the unsigned image twice from one commit, each time in a fresh clone
# with its own Go build cache, and compare every file in build/out by SHA-256.
# This is the check behind "rebuild from the tag and compare the hash": a user
# who builds the same tag must get the same unsigned UKI and ISO bytes the
# release lists in SHA256SUMS.
#
# Exits 0 when every output is identical, 1 when any differs or exists in
# only one workspace (the report names each file), and 1 on a dirty source
# tree, since the clones are taken from HEAD and would not match it.
#
# Usage: build/release/reproducible.sh
#   REPRO_SOURCE    repo to clone (default: this checkout)
#   REPRO_ARCH      default amd64
#   REPRO_PLATFORM  default vmware
#   REPRO_STATEKEY  default nodeid (tpm|nodeid)
#   REPRO_WORK      where the two workspaces go (default: a temp dir)
#   REPRO_KEEP=1    keep both workspaces afterwards, for diffoscope
#   REPRO_BUILDER   test-only: a shell snippet run in each workspace instead
#                   of `task iso:unsigned`. Never set this for a real check.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

src="${REPRO_SOURCE:-$root}"
arch="${REPRO_ARCH:-amd64}"
platform="${REPRO_PLATFORM:-vmware}"
statekey="${REPRO_STATEKEY:-nodeid}"

log() { printf 'reproducible: %s\n' "$*" >&2; }

if ! git -C "$src" diff --quiet HEAD -- || [ -n "$(git -C "$src" status --porcelain --untracked-files=no)" ]; then
  log "the source tree has uncommitted changes; commit or stash them first"
  exit 1
fi
commit="$(git -C "$src" rev-parse HEAD)"

work="${REPRO_WORK:-}"
made_work=0
if [ -z "$work" ]; then
  work="$(mktemp -d)"
  made_work=1
fi
mkdir -p "$work"
work="$(cd "$work" && pwd)"

cleanup() {
  [ "${REPRO_KEEP:-}" = 1 ] && { log "kept the workspaces in $work"; return; }
  rm -rf "$work/ws1" "$work/ws2"
  [ "$made_work" = 1 ] && rm -rf "$work"
  return 0
}
trap cleanup EXIT

build_one() {
  local ws="$1"
  rm -rf "$ws"
  git clone -q --no-local "$src" "$ws"
  git -C "$ws" checkout -q --detach "$commit"
  log "building in $(basename "$ws") (ARCH=$arch PLATFORM=$platform STATEKEY=$statekey)"
  if [ -n "${REPRO_BUILDER:-}" ]; then
    ( cd "$ws" && GOCACHE="$ws/.gocache" ARCH="$arch" PLATFORM="$platform" STATEKEY="$statekey" \
        bash -c "$REPRO_BUILDER" )
  else
    # SB_KEY/SB_CERT are cleared so nothing the caller exported can sign or
    # anchor the build; iso:unsigned clears them as well.
    ( cd "$ws" && env -u SB_KEY -u SB_CERT GOCACHE="$ws/.gocache" \
        task iso:unsigned ARCH="$arch" PLATFORM="$platform" STATEKEY="$statekey" )
  fi
}

hashes() {
  local dir="$1/build/out"
  [ -d "$dir" ] || return 0
  ( cd "$dir" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ) | sed 's|  \./|  |'
}

log "commit $commit"
build_one "$work/ws1"
build_one "$work/ws2"

h1="$(hashes "$work/ws1")"
h2="$(hashes "$work/ws2")"
if [ -z "$h1" ] && [ -z "$h2" ]; then
  log "no build outputs in build/out; nothing to compare"
  exit 1
fi

declare -A a b
while read -r sum name; do [ -n "$name" ] && a["$name"]="$sum"; done <<<"$h1"
while read -r sum name; do [ -n "$name" ] && b["$name"]="$sum"; done <<<"$h2"

names="$(printf '%s\n' "${!a[@]}" "${!b[@]}" | sort -u)"
same=0 bad=0
echo "commit $commit"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ -z "${a[$name]:-}" ] || [ -z "${b[$name]:-}" ]; then
    printf 'MISSING  %s (built in one workspace only)\n' "$name"
    bad=$((bad + 1))
  elif [ "${a[$name]}" = "${b[$name]}" ]; then
    printf 'same     %s  %s\n' "$name" "${a[$name]}"
    same=$((same + 1))
  else
    printf 'DIFFERS  %s  %s  %s\n' "$name" "${a[$name]}" "${b[$name]}"
    bad=$((bad + 1))
  fi
done <<<"$names"

if [ "$bad" -ne 0 ]; then
  echo "reproducible: $bad of $((same + bad)) files differ"
  exit 1
fi
echo "reproducible: $same files identical"

#!/usr/bin/env bash
# Build the gate's upgrade_from baseline image: the build the field runs
# today (cryptos-node a77ae5b by default), from that commit's own in-repo
# build recipe (the build moved to cryptos-appliance afterwards, so the
# pinned commit is fetched and built in place rather than with this repo's
# current Taskfile). Signed with a per-run throwaway Secure Boot key made in
# /dev/shm (tmpfs), never written to disk elsewhere. The key is shredded
# before this script returns, so the built image is never cached for reuse:
# a cached image would trust a key that no longer exists. Every call rebuilds
# and overwrites its output path.
#
# Prints the built image's path on stdout.
#
# Usage: test/gate/baseline.sh [commit]
#   BASELINE_REMOTE     override the cryptos-node remote (default:
#                       https://github.com/CryptOS-PKI/cryptos-node.git)
#   BASELINE_ARCH       default amd64
#   BASELINE_PLATFORM   default vmware
#   BASELINE_STATEKEY   default nodeid (the field's upgrade_from mode)
#   BASELINE_CACHE_DIR  default <repo root>/.cache/gate/baseline; where the
#                       standalone build's output ISO is written (rebuilt and
#                       overwritten on every call, never read back)
#   BASELINE_SB_KEY     with BASELINE_SB_CERT: sign and anchor the baseline
#   BASELINE_SB_CERT    with the caller's key instead of a key of its own (the
#                       gate signs the baseline and the candidate with one key,
#                       so the baseline accepts the candidate). Both must sit on
#                       /dev/shm and are left for the caller to shred. Nothing
#                       is cached in this mode: the image carries the caller's
#                       per-run anchor.
#   BASELINE_OUT_DIR    required with BASELINE_SB_KEY: where baseline.iso,
#                       baseline.uki and baseline.uki.sig are written
#   BASELINE_BUILDER    test-only: a shell snippet run instead of `task iso`,
#                       in the checked-out commit with SB_KEY/SB_CERT/ARCH/
#                       PLATFORM/STATEKEY exported. Never set this for a real
#                       baseline build.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

default_commit="a77ae5bf55737dec83188fe61fb615fd2fe839e1"

cache_key() {
  # commit arch platform statekey -> one opaque string; never fed key material.
  printf '%s-%s-%s-%s' "$1" "$2" "$3" "$4"
}

# Fail loudly if a file named like Secure Boot key material shows up anywhere
# outside the tmpfs key directory, before it can reach the output path.
check_no_stray_keys() {
  local search_dir="$1" found
  found="$(find "$search_dir" -type f \( -name 'sb.key' -o -name 'sb.crt' -o -name 'sb.der' \) 2>/dev/null || true)"
  if [ -n "$found" ]; then
    echo "baseline: key material leaked outside the tmpfs key directory:" >&2
    printf '  %s\n' "$found" >&2
    return 1
  fi
  return 0
}

main() {
  local commit="${1:-${BASELINE_COMMIT:-$default_commit}}"
  local remote="${BASELINE_REMOTE:-https://github.com/CryptOS-PKI/cryptos-node.git}"
  local arch="${BASELINE_ARCH:-amd64}"
  local platform="${BASELINE_PLATFORM:-vmware}"
  local statekey="${BASELINE_STATEKEY:-nodeid}"
  local cache_dir="${BASELINE_CACHE_DIR:-$root/.cache/gate/baseline}"

  if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "baseline: commit must be a full 40-hex SHA: $commit" >&2
    exit 1
  fi

  local ext_key="${BASELINE_SB_KEY:-}" ext_cert="${BASELINE_SB_CERT:-}" out_dir="${BASELINE_OUT_DIR:-}"
  local external=0
  if [ -n "$ext_key" ] || [ -n "$ext_cert" ]; then
    external=1
    [ -n "$ext_key" ] && [ -n "$ext_cert" ] && [ -n "$out_dir" ] || {
      echo "baseline: BASELINE_SB_KEY, BASELINE_SB_CERT and BASELINE_OUT_DIR go together" >&2
      exit 1
    }
    local f
    for f in "$ext_key" "$ext_cert"; do
      [ -f "$f" ] || { echo "baseline: key file not found: $f" >&2; exit 1; }
      case "$(readlink -f "$f")" in
        /dev/shm/*) ;;
        *) echo "baseline: the signing key must sit on /dev/shm (tmpfs): $f" >&2; exit 1 ;;
      esac
    done
  fi

  mkdir -p "$cache_dir"
  local key; key="$(cache_key "$commit" "$arch" "$platform" "$statekey")"
  local artifact="$cache_dir/baseline-$key.iso"

  # Not `local`: an EXIT trap set from inside a function can fire after the
  # function's own locals have already gone out of scope (bash's local
  # lifetime ends with the function on an early, set -e-triggered exit),
  # which left cleanup() reading an unbound $keydir. Plain variables outlive
  # that, and this script runs main() exactly once.
  workdir="$(mktemp -d)"
  keydir=""
  [ "$external" = 0 ] && keydir="$(mktemp -d /dev/shm/cryptos-gate-baseline-key.XXXXXX)"
  cleanup() {
    if [ -n "$keydir" ]; then
      shred -u "$keydir"/sb.* 2>/dev/null || true
      rm -rf "$keydir"
    fi
    rm -rf "$workdir"
  }
  trap cleanup EXIT

  echo "baseline: fetching cryptos-node@$commit from $remote" >&2
  git init -q "$workdir"
  git -C "$workdir" fetch -q --depth 1 "$remote" "$commit"
  git -C "$workdir" checkout -q FETCH_HEAD

  local sb_key sb_cert
  if [ "$external" = 1 ]; then
    echo "baseline: signing with the caller's key" >&2
    sb_key="$ext_key" sb_cert="$ext_cert"
  else
    echo "baseline: generating the per-run Secure Boot key in $keydir (tmpfs)" >&2
    ( cd "$workdir" && go build -o "$keydir/cryptos-sbkey" ./cmd/cryptos-sbkey )
    "$keydir/cryptos-sbkey" --out-dir "$keydir" --cn "CryptOS gate (ephemeral)" --days 1
    sb_key="$keydir/sb.key" sb_cert="$keydir/sb.crt"
  fi
  [ -f "$sb_key" ] && [ -f "$sb_cert" ] || {
    echo "baseline: cryptos-sbkey did not write $sb_key / $sb_cert" >&2
    exit 1
  }

  echo "baseline: building the image (PLATFORM=$platform STATEKEY=$statekey ARCH=$arch)" >&2
  echo "SB_KEY=$sb_key SB_CERT=$sb_cert" >&2
  if [ -n "${BASELINE_BUILDER:-}" ]; then
    ( cd "$workdir" && SB_KEY="$sb_key" SB_CERT="$sb_cert" ARCH="$arch" PLATFORM="$platform" STATEKEY="$statekey" \
        bash -c "$BASELINE_BUILDER" )
  else
    ( cd "$workdir" && SB_KEY="$sb_key" SB_CERT="$sb_cert" \
        task iso ARCH="$arch" PLATFORM="$platform" STATEKEY="$statekey" )
  fi

  local suffix=""
  [ "$statekey" = "nodeid" ] && suffix="-nodeid"
  local built="$workdir/build/out/cryptos-$arch-$platform$suffix.iso"
  [ -f "$built" ] || {
    echo "baseline: expected build output not found: $built" >&2
    exit 1
  }

  check_no_stray_keys "$workdir" || exit 1

  if [ "$external" = 1 ]; then
    local uki="$workdir/build/out/cryptos-$arch.uki"
    [ -f "$uki" ] || { echo "baseline: expected build output not found: $uki" >&2; exit 1; }
    mkdir -p "$out_dir"
    cp "$built" "$out_dir/baseline.iso"
    cp "$uki" "$out_dir/baseline.uki"
    if [ -f "$uki.sig" ]; then cp "$uki.sig" "$out_dir/baseline.uki.sig"; fi
    check_no_stray_keys "$out_dir" || exit 1
    echo "baseline: built $commit with the caller's key -> $out_dir (not cached)" >&2
    printf '%s\n' "$out_dir/baseline.iso"
    return 0
  fi

  cp "$built" "$artifact"
  check_no_stray_keys "$cache_dir" || { rm -f "$artifact"; exit 1; }

  echo "baseline: built $commit -> $artifact (not cached: standalone mode signs with its own throwaway key)" >&2
  printf '%s\n' "$artifact"
}

if [ -z "${BASELINE_TEST_SOURCE_ONLY:-}" ]; then
  main "$@"
fi

#!/usr/bin/env bash
# Check release/pins.yaml before a release build starts: every required repo
# has a pin, every pin is a full 40-hex commit, every pin is reachable at its
# repo's remote, and the cryptos-node pin equals go.mod's pseudo-version
# commit. This is a fixed-schema reader for pins.yaml's two-level shape, not
# a general YAML parser.
#
# Usage: build/release/guard.sh [pins-file]
#   GUARD_GO_MOD                override go.mod path (default: repo root go.mod)
#   GUARD_REMOTE_<REPO_KEY>     override a repo's remote URL (default:
#                               https://github.com/CryptOS-PKI/<repo>.git);
#                               REPO_KEY is the pins.yaml key, upper-cased
#                               with '-' turned into '_' (e.g. CRYPTOS_NODE)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

pins_file="${1:-$root/release/pins.yaml}"
go_mod="${GUARD_GO_MOD:-$root/go.mod}"

required_repos=(cryptos-node cryptos-manager cryptos-web website)

declare -A repo_commit
upgrade_repo=()
upgrade_commit=()
errors=()

fail() { errors+=("$1"); }

is_full_sha() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

remote_url_for() {
  local key="$1" var
  var="GUARD_REMOTE_$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')"
  if [ -n "${!var:-}" ]; then
    printf '%s' "${!var}"
  else
    printf 'https://github.com/CryptOS-PKI/%s.git' "$key"
  fi
}

commit_reachable() {
  local url="$1" commit="$2" tmp
  tmp="$(mktemp -d)"
  git init -q "$tmp"
  if git -C "$tmp" fetch -q --depth 1 "$url" "$commit" >/dev/null 2>&1 \
      && git -C "$tmp" cat-file -e "${commit}^{commit}" 2>/dev/null; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

if [ ! -f "$pins_file" ]; then
  echo "guard: pins file not found: $pins_file" >&2
  exit 1
fi

if [ ! -f "$go_mod" ]; then
  echo "guard: go.mod not found: $go_mod" >&2
  exit 1
fi

# --- parse pins.yaml ---
section=""
while IFS= read -r line; do
  case "$line" in
    repos:*) section="repos"; continue ;;
    upgrade_from:*) section="upgrade_from"; continue ;;
    [a-zA-Z]*:*) section="" ;;
  esac

  if [ "$section" = "repos" ]; then
    if [[ "$line" =~ ^[[:space:]]+([a-zA-Z0-9_-]+):[[:space:]]*\{commit:[[:space:]]*([^},[:space:]]*)[[:space:]]*\} ]]; then
      repo_commit["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  elif [ "$section" = "upgrade_from" ]; then
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\{repo:[[:space:]]*([a-zA-Z0-9_-]+),[[:space:]]*commit:[[:space:]]*([^},[:space:]]*)[[:space:]]*\} ]]; then
      upgrade_repo+=("${BASH_REMATCH[1]}")
      upgrade_commit+=("${BASH_REMATCH[2]}")
    fi
  fi
done < "$pins_file"

release_name="$(grep -E '^release:' "$pins_file" | head -n1 | sed -E 's/^release:[[:space:]]*//')"

# --- required repo pins: present, well-formed, reachable ---
for repo in "${required_repos[@]}"; do
  commit="${repo_commit[$repo]:-}"
  if [ -z "$commit" ]; then
    fail "missing pin: $repo"
    continue
  fi
  if ! is_full_sha "$commit"; then
    fail "pin for $repo is not a full 40-hex commit: $commit"
    continue
  fi
  url="$(remote_url_for "$repo")"
  if ! commit_reachable "$url" "$commit"; then
    fail "unreachable commit for $repo: $commit ($url)"
  fi
done

# --- upgrade_from: at least one entry, well-formed, reachable ---
if [ "${#upgrade_repo[@]}" -eq 0 ]; then
  fail "missing pin: upgrade_from"
else
  for i in "${!upgrade_repo[@]}"; do
    repo="${upgrade_repo[$i]}"
    commit="${upgrade_commit[$i]}"
    if [ -z "$commit" ]; then
      fail "missing pin: upgrade_from ($repo)"
      continue
    fi
    if ! is_full_sha "$commit"; then
      fail "pin for upgrade_from ($repo) is not a full 40-hex commit: $commit"
      continue
    fi
    url="$(remote_url_for "$repo")"
    if ! commit_reachable "$url" "$commit"; then
      fail "unreachable commit for upgrade_from ($repo): $commit ($url)"
    fi
  done
fi

# --- cryptos-node pin must equal go.mod's pseudo-version commit ---
node_commit="${repo_commit[cryptos-node]:-}"
if [ -n "$node_commit" ] && is_full_sha "$node_commit"; then
  gomod_line="$(grep -E 'github\.com/CryptOS-PKI/cryptos-node[[:space:]]' "$go_mod" || true)"
  if [ -z "$gomod_line" ]; then
    fail "go.mod has no github.com/CryptOS-PKI/cryptos-node requirement"
  else
    gomod_hash="$(printf '%s' "$gomod_line" | grep -oE '[0-9]{14}-[0-9a-f]{12}' | sed -E 's/^[0-9]{14}-//')"
    if [ -z "$gomod_hash" ]; then
      fail "could not read a pseudo-version commit from go.mod: $gomod_line"
    elif [ "${node_commit:0:12}" != "$gomod_hash" ]; then
      fail "cryptos-node pin $node_commit disagrees with go.mod ($gomod_hash)"
    fi
  fi
fi

if [ "${#errors[@]}" -gt 0 ]; then
  echo "guard: FAILED" >&2
  for e in "${errors[@]}"; do
    echo "  - $e" >&2
  done
  exit 1
fi

echo "guard: OK (release ${release_name:-unknown})"

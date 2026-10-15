#!/usr/bin/env bash
# Print one repo's pinned commit from release/pins.yaml's `repos:` block, for
# workflow steps that check out a pinned repo (the release workflow's
# services job checks out cryptos-manager and cryptos-web at their pins).
# Shares guard.sh's reader for pins.yaml's two-level shape, not a general
# YAML parser; `upgrade_from` is a different section and is never returned
# by a repo lookup.
#
# Usage: build/release/pin.sh <repo> [pins-file]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

repo="${1:?usage: pin.sh <repo> [pins-file]}"
pins_file="${2:-$root/release/pins.yaml}"

if [ ! -f "$pins_file" ]; then
  echo "pin: no such pins file: $pins_file" >&2
  exit 1
fi

section=""
while IFS= read -r line; do
  case "$line" in
    repos:*) section="repos"; continue ;;
    upgrade_from:*) section=""; continue ;;
    [a-zA-Z]*:*) section="" ;;
  esac

  if [ "$section" = "repos" ] && [[ "$line" =~ ^[[:space:]]+([a-zA-Z0-9_-]+):[[:space:]]*\{commit:[[:space:]]*([^},[:space:]]*)[[:space:]]*\} ]]; then
    if [ "${BASH_REMATCH[1]}" = "$repo" ]; then
      printf '%s\n' "${BASH_REMATCH[2]}"
      exit 0
    fi
  fi
done < "$pins_file"

echo "pin: no pin for $repo in $pins_file" >&2
exit 1

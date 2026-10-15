#!/usr/bin/env bash
# Render a release's "How <tag> was tested" section from the gate's step
# summary and release/pins.yaml's commit set, and print the release body with
# that section replaced (a prior run's section, if any) or appended. Reads
# the release's current body on stdin and writes the updated body to stdout;
# it never calls `gh` itself, so the workflow decides whether and how to
# publish the result (`gh release edit <tag> --notes-file -`).
#
# Usage: build/release/notes.sh <gate-summary-file> [pins-file]
#   NOTES_RUN_URL   link to the workflow run that produced the summary (required)
#   NOTES_TAG       the release tag, for the heading (required)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

summary_file="${1:?usage: notes.sh <gate-summary-file> [pins-file]}"
pins_file="${2:-$root/release/pins.yaml}"
run_url="${NOTES_RUN_URL:?NOTES_RUN_URL is required}"
tag="${NOTES_TAG:?NOTES_TAG is required}"

if [ ! -f "$summary_file" ]; then
  echo "notes: no such gate summary file: $summary_file" >&2
  exit 1
fi
if [ ! -f "$pins_file" ]; then
  echo "notes: no such pins file: $pins_file" >&2
  exit 1
fi

heading="## How $tag was tested"

render_section() {
  printf '%s\n\n' "$heading"
  printf 'The release gate built every image in this commit set from source, with a\n'
  printf 'throwaway Secure Boot key made for the run, and proved on the lab ESXi host\n'
  printf 'that they install, boot, upgrade in place with state kept and roll back. TPM\n'
  printf 'mode (install, reseal on upgrade, rollback) is proved separately, in QEMU with\n'
  printf 'a software TPM, on the same commit; see docs/release.md.\n\n'
  printf '### Commit set\n\n'
  printf '| Repo | Commit |\n'
  printf '|---|---|\n'
  printf '| cryptos-appliance | `%s` |\n' "$(git -C "$root" rev-parse HEAD)"

  local section=""
  while IFS= read -r line; do
    case "$line" in
      repos:*) section="repos"; continue ;;
      upgrade_from:*) section=""; continue ;;
      [a-zA-Z]*:*) section="" ;;
    esac
    if [ "$section" = "repos" ] && [[ "$line" =~ ^[[:space:]]+([a-zA-Z0-9_-]+):[[:space:]]*\{commit:[[:space:]]*([^},[:space:]]*)[[:space:]]*\} ]]; then
      printf '| %s | `%s` |\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done < "$pins_file"

  printf '\n### Gate steps\n\n'
  cat "$summary_file"
  printf '\n[Gate run](%s)\n' "$run_url"
}

new_section="$(render_section)"
body="$(cat)"

# Drop a previous "## How <tag> was tested" section (a prior run on the same
# tag), so a re-run replaces it instead of piling up duplicates. awk's plain
# string match against $0 (not a regex) means a tag with regex metacharacters
# in it still matches literally.
stripped="$(awk -v h="$heading" '
  BEGIN { skip = 0 }
  $0 == h { skip = 1; next }
  skip && /^## / { skip = 0 }
  !skip { print }
' <<<"$body")"

printf '%s\n\n%s\n' "$stripped" "$new_section"

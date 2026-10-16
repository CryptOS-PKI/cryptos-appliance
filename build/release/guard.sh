#!/usr/bin/env bash
# Check release/pins.yaml before a release build starts: every required repo
# has a pin, every pin is a full 40-hex commit, every pin is reachable at its
# repo's remote, and the cryptos-node pin equals go.mod's pseudo-version
# commit. This is a fixed-schema reader for pins.yaml's two-level shape, not
# a general YAML parser.
#
# On a v* tag push it also checks (release-workflow-design.md 2.1-2.2): the
# tag itself is vX.Y.Z or vX.Y.Z-rc.N, and each of the five release repos
# (the four pinned repos plus cryptos-appliance itself) has a published,
# non-draft prerelease at its pinned commit. On a workflow_dispatch
# rehearsal it instead prints each of those five repos' release-drafter
# draft (name, tag, target, prerelease) next to its pin and fails on any
# mismatch with pins.yaml's own `release:` version. Neither check runs
# outside those two events (a plain local `task release:guard` only checks
# the pins, as before).
#
# Usage: build/release/guard.sh [pins-file]
#   GUARD_GO_MOD                override go.mod path (default: repo root go.mod)
#   GUARD_REMOTE_<REPO_KEY>     override a repo's remote URL (default:
#                               https://github.com/CryptOS-PKI/<repo>.git);
#                               REPO_KEY is the pins.yaml key, upper-cased
#                               with '-' turned into '_' (e.g. CRYPTOS_NODE)
#   GUARD_RELEASES_<REPO_KEY>   override a repo's releases list (default:
#                               `gh api --paginate repos/CryptOS-PKI/<repo>/releases`);
#                               a path to a file of that same JSON array
#   GUARD_SELF_COMMIT           override this repo's own HEAD commit
#                               (default: `git rev-parse HEAD` at the repo root)
#   GUARD_EVENT                 "tag" or "dispatch" (default: read from
#                               GITHUB_REF_TYPE / GITHUB_EVENT_NAME; empty
#                               outside CI, which skips both checks)
#   GUARD_TAG                   the tag being released (default: GITHUB_REF_NAME)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

pins_file="${1:-$root/release/pins.yaml}"
go_mod="${GUARD_GO_MOD:-$root/go.mod}"

required_repos=(cryptos-node cryptos-manager cryptos-web docs)

declare -A repo_commit
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
    [a-zA-Z]*:*) section="" ;;
  esac

  if [ "$section" = "repos" ]; then
    if [[ "$line" =~ ^[[:space:]]+([a-zA-Z0-9_-]+):[[:space:]]*\{commit:[[:space:]]*([^},[:space:]]*)[[:space:]]*\} ]]; then
      repo_commit["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
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

# --- tag-release and rehearsal-dispatch checks ---
#
# "Release repos" are the four pinned repos plus cryptos-appliance itself,
# which has no pin (GUARD_SELF_COMMIT / HEAD stands in for one).

release_repos=("${required_repos[@]}" cryptos-appliance)
declare -A release_commit
for repo in "${required_repos[@]}"; do
  release_commit["$repo"]="${repo_commit[$repo]:-}"
done
release_commit[cryptos-appliance]="${GUARD_SELF_COMMIT:-$(git -C "$root" rev-parse HEAD 2>/dev/null || true)}"

releases_json_for() {
  local key="$1" var
  var="GUARD_RELEASES_$(printf '%s' "$key" | tr '[:lower:]-' '[:upper:]_')"
  if [ -n "${!var:-}" ]; then
    cat "${!var}"
  else
    gh api --paginate "repos/CryptOS-PKI/$key/releases"
  fi
}

# commit_for_tag <repo> <tag>: the commit a repo's tag points to, resolved
# at its remote (the same GUARD_REMOTE_<REPO_KEY> url the pins check uses).
# An annotated tag's peeled ref (<tag>^{}) wins over the tag object's own sha.
commit_for_tag() {
  local repo="$1" tagname="$2" url direct="" peeled=""
  url="$(remote_url_for "$repo")"
  while IFS=$'\t' read -r sha ref; do
    case "$ref" in
      "refs/tags/$tagname") direct="$sha" ;;
      "refs/tags/$tagname^{}") peeled="$sha" ;;
    esac
  done < <(git ls-remote "$url" "refs/tags/$tagname" "refs/tags/$tagname^{}" 2>/dev/null || true)
  if [ -n "$peeled" ]; then
    printf '%s' "$peeled"
  else
    printf '%s' "$direct"
  fi
}

# check_tag_releases: every release repo has a published (non-draft),
# prerelease release whose tag resolves to its pinned commit.
check_tag_releases() {
  local repo commit rel draft prerelease tag_name rel_commit found
  for repo in "${release_repos[@]}"; do
    commit="${release_commit[$repo]:-}"
    found=""
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      draft="$(jq -r '.draft' <<<"$rel")"
      [ "$draft" = "true" ] && continue
      prerelease="$(jq -r '.prerelease' <<<"$rel")"
      [ "$prerelease" = "true" ] || continue
      tag_name="$(jq -r '.tag_name' <<<"$rel")"
      rel_commit="$(commit_for_tag "$repo" "$tag_name")"
      if [ -n "$rel_commit" ] && [ "$rel_commit" = "$commit" ]; then
        found="$tag_name"
        break
      fi
    done < <(releases_json_for "$repo" | jq -c '.[]')
    if [ -z "$found" ]; then
      fail "no published prerelease for $repo at its pinned commit (${commit:-unknown})"
    fi
  done
}

# check_dispatch_drafts: print each release repo's release-drafter draft
# next to its pin, and fail when a draft is missing or disagrees with
# pins.yaml's own release version, target branch or prerelease flag.
check_dispatch_drafts() {
  local repo commit draft dtag dtarget dprerelease
  echo "guard: rehearsal drafts vs pins"
  printf '%-18s  %-12s  %-20s  %-10s  %-10s\n' repo pin draft-tag target prerelease
  for repo in "${release_repos[@]}"; do
    commit="${release_commit[$repo]:-}"
    draft="$(releases_json_for "$repo" | jq -c '[.[] | select(.draft == true)] | .[0] // empty')"
    if [ -z "$draft" ]; then
      printf '%-18s  %-12s  %-20s  %-10s  %-10s\n' "$repo" "${commit:0:12}" "(none)" "-" "-"
      fail "no release-drafter draft for $repo"
      continue
    fi
    dtag="$(jq -r '.tag_name' <<<"$draft")"
    dtarget="$(jq -r '.target_commitish' <<<"$draft")"
    dprerelease="$(jq -r '.prerelease' <<<"$draft")"
    printf '%-18s  %-12s  %-20s  %-10s  %-10s\n' "$repo" "${commit:0:12}" "$dtag" "$dtarget" "$dprerelease"
    if [ "$dtag" != "$release_name" ]; then
      fail "draft for $repo is tagged $dtag, not $release_name"
    fi
    if [ "$dtarget" != "main" ]; then
      fail "draft for $repo targets $dtarget, not main"
    fi
    if [ "$dprerelease" != "true" ]; then
      fail "draft for $repo is not marked prerelease"
    fi
  done
}

guard_event="${GUARD_EVENT:-}"
if [ -z "$guard_event" ]; then
  if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    guard_event="tag"
  elif [ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ]; then
    guard_event="dispatch"
  fi
fi
guard_tag="${GUARD_TAG:-${GITHUB_REF_NAME:-}}"

if [ "$guard_event" = "tag" ]; then
  if ! [[ "$guard_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]]; then
    fail "tag $guard_tag is not vX.Y.Z or vX.Y.Z-rc.N"
  else
    check_tag_releases
  fi
elif [ "$guard_event" = "dispatch" ]; then
  check_dispatch_drafts
fi

if [ "${#errors[@]}" -gt 0 ]; then
  echo "guard: FAILED" >&2
  for e in "${errors[@]}"; do
    echo "  - $e" >&2
  done
  exit 1
fi

echo "guard: OK (release ${release_name:-unknown})"

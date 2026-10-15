#!/usr/bin/env bash
# Unit test for guard.sh: builds throwaway bare repos to stand in for the
# four pinned repos (fetched over file://, never github.com) plus a throwaway
# go.mod, and checks the guard accepts a good pin set and rejects a missing
# pin, a short SHA, an unreachable commit and a cryptos-node pin that
# disagrees with go.mod. It also covers the tag-release and rehearsal-dispatch
# checks (release/pins.yaml section 2.2): the tag format, each of the five
# release repos (the four pinned plus cryptos-appliance itself) having a
# published, non-draft prerelease at its pinned commit on a tag run, and
# each one's release-drafter draft matching the pin on a rehearsal dispatch.
# GUARD_RELEASES_<REPO_KEY> stands in for `gh api .../releases` with a file
# of canned JSON, the same way GUARD_REMOTE_<REPO_KEY> stands in for a real
# github.com remote.
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
website_sha="$(mkbare website)"

# A bare repo standing in for cryptos-appliance itself: the five release
# repos the tag/dispatch checks cover are the four pinned repos plus the
# appliance, which has no pin of its own (GUARD_SELF_COMMIT stands in for
# its HEAD, the same way GUARD_GO_MOD stands in for its go.mod).
appliance_sha="$(mkbare cryptos-appliance)"

# tag_existing <name> <tag>: tags an already-pushed repo's HEAD (one of the
# mkbare commits above) and pushes just the tag, so the tag-release checks
# have a real ref to resolve over file://.
tag_existing() {
  local name="$1" tag="$2"
  git -C "$work/src-$name" tag "$tag"
  git -C "$work/src-$name" push -q bare "refs/tags/$tag"
}

# releases_fixture <file> <tag> <draft> <prerelease> <target>: one release
# object, written to <file> as the single-element JSON array guard.sh reads.
releases_fixture() {
  local file="$1" tag="$2" draft="$3" prerelease="$4" target="$5"
  jq -n --arg tag "$tag" --arg target "$target" \
    --argjson draft "$draft" --argjson prerelease "$prerelease" \
    '[{tag_name: $tag, name: $tag, draft: $draft, prerelease: $prerelease, target_commitish: $target}]' \
    > "$file"
}

no_releases_fixture() {
  printf '[]' > "$1"
}

# A commit that exists nowhere (not pushed to any remote): 40 hex chars,
# well-formed but unreachable.
unreachable_sha="0123456789abcdef0123456789abcdef01234567"

remotes_env=(
  "GUARD_REMOTE_CRYPTOS_NODE=$work/remotes/cryptos-node.git"
  "GUARD_REMOTE_CRYPTOS_MANAGER=$work/remotes/cryptos-manager.git"
  "GUARD_REMOTE_CRYPTOS_WEB=$work/remotes/cryptos-web.git"
  "GUARD_REMOTE_WEBSITE=$work/remotes/website.git"
  "GUARD_REMOTE_CRYPTOS_APPLIANCE=$work/remotes/cryptos-appliance.git"
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
  website:          {commit: $4}
upgrade_from:
  - {repo: cryptos-node, commit: $5}
EOF
  printf '%s' "$file"
}

run_guard() {
  local pins="$1" gomod="$2"
  env "${remotes_env[@]}" GUARD_GO_MOD="$gomod" bash "$guard" "$pins"
}

# run_guard_release <pins> <gomod> <extra env assignments...>: like
# run_guard, plus the tag/dispatch env (GUARD_EVENT, GUARD_TAG,
# GUARD_SELF_COMMIT, GUARD_RELEASES_<REPO_KEY>) each case passes in.
run_guard_release() {
  local pins="$1" gomod="$2"
  shift 2
  env "${remotes_env[@]}" "$@" GUARD_GO_MOD="$gomod" bash "$guard" "$pins"
}

# Case 1: a good pin set, everything reachable, go.mod matches.
gomod="$(write_gomod "${node_sha:0:12}")"
pins="$(write_pins "$node_sha" "$manager_sha" "$web_sha" "$website_sha" "$node_sha")"
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "good pin set" 0 "$status"
assert_contains "good pin set message" "guard: OK" "$out"

# Case 2: a missing pin (website absent from the repos block).
pins="$work/pins-missing.yaml"
cat > "$pins" <<EOF
version: 1
release: v0.1.0-rc.1
repos:
  cryptos-node:     {commit: $node_sha}
  cryptos-manager:  {commit: $manager_sha}
  cryptos-web:      {commit: $web_sha}
upgrade_from:
  - {repo: cryptos-node, commit: $node_sha}
EOF
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "missing pin" 1 "$status"
assert_contains "missing pin message" "missing pin: website" "$out"

# Case 3: a short SHA.
pins="$(write_pins "${node_sha:0:12}" "$manager_sha" "$web_sha" "$website_sha" "$node_sha")"
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "short SHA" 1 "$status"
assert_contains "short SHA message" "not a full 40-hex" "$out"

# Case 4: an unreachable commit (well-formed, pushed nowhere).
pins="$(write_pins "$node_sha" "$manager_sha" "$web_sha" "$unreachable_sha" "$node_sha")"
out=""
status=0
out="$(run_guard "$pins" "$gomod" 2>&1)" || status=$?
assert_status "unreachable commit" 1 "$status"
assert_contains "unreachable commit message" "unreachable commit for website" "$out"

# Case 5: cryptos-node pin disagrees with go.mod.
other_gomod="$(write_gomod "${manager_sha:0:12}")"
pins="$(write_pins "$node_sha" "$manager_sha" "$web_sha" "$website_sha" "$node_sha")"
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

# --- tag-release checks (release/pins.yaml section 2.2, a v* tag push) ---

# write_gomod overwrites the shared $work/go.mod file in place (case 5 above
# pointed it at manager_sha to test the mismatch); put it back to agreeing
# with node_sha before anything below relies on a clean go.mod match.
gomod="$(write_gomod "${node_sha:0:12}")"

good_tag="v0.1.0-rc.1"
tag_existing cryptos-node "$good_tag"
tag_existing cryptos-manager "$good_tag"
tag_existing cryptos-web "$good_tag"
tag_existing website "$good_tag"
tag_existing cryptos-appliance "$good_tag"

rel_node="$work/rel-node.json"
rel_manager="$work/rel-manager.json"
rel_web="$work/rel-web.json"
rel_website="$work/rel-website.json"
rel_appliance="$work/rel-appliance.json"
releases_fixture "$rel_node" "$good_tag" false true main
releases_fixture "$rel_manager" "$good_tag" false true main
releases_fixture "$rel_web" "$good_tag" false true main
releases_fixture "$rel_website" "$good_tag" false true main
releases_fixture "$rel_appliance" "$good_tag" false true main

release_pins="$(write_pins "$node_sha" "$manager_sha" "$web_sha" "$website_sha" "$node_sha")"

# Case 7: a good tag release, every one of the five repos a published
# prerelease at its pinned commit.
release_env_good=(
  GUARD_EVENT=tag
  "GUARD_TAG=$good_tag"
  "GUARD_SELF_COMMIT=$appliance_sha"
  "GUARD_RELEASES_CRYPTOS_NODE=$rel_node"
  "GUARD_RELEASES_CRYPTOS_MANAGER=$rel_manager"
  "GUARD_RELEASES_CRYPTOS_WEB=$rel_web"
  "GUARD_RELEASES_WEBSITE=$rel_website"
  "GUARD_RELEASES_CRYPTOS_APPLIANCE=$rel_appliance"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_good[@]}" 2>&1)" || status=$?
assert_status "tag release: good set" 0 "$status"
assert_contains "tag release: good set message" "guard: OK" "$out"

# Case 8: the tag itself isn't vX.Y.Z or vX.Y.Z-rc.N.
release_env_badtag=(
  GUARD_EVENT=tag
  "GUARD_TAG=v0.1"
  "GUARD_SELF_COMMIT=$appliance_sha"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_badtag[@]}" 2>&1)" || status=$?
assert_status "tag release: bad tag format" 1 "$status"
assert_contains "tag release: bad tag format message" "is not vX.Y.Z or vX.Y.Z-rc.N" "$out"

# Case 9: one repo (website) has no release at all, so no published
# prerelease at its pinned commit.
rel_website_none="$work/rel-website-none.json"
no_releases_fixture "$rel_website_none"
release_env_missing=(
  GUARD_EVENT=tag
  "GUARD_TAG=$good_tag"
  "GUARD_SELF_COMMIT=$appliance_sha"
  "GUARD_RELEASES_CRYPTOS_NODE=$rel_node"
  "GUARD_RELEASES_CRYPTOS_MANAGER=$rel_manager"
  "GUARD_RELEASES_CRYPTOS_WEB=$rel_web"
  "GUARD_RELEASES_WEBSITE=$rel_website_none"
  "GUARD_RELEASES_CRYPTOS_APPLIANCE=$rel_appliance"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_missing[@]}" 2>&1)" || status=$?
assert_status "tag release: no release for website" 1 "$status"
assert_contains "tag release: no release message" "no published prerelease for website" "$out"

# Case 10: cryptos-manager has a release at the right tag and commit, but
# it's still a draft (not published), so it must not count.
rel_manager_draft="$work/rel-manager-draft.json"
releases_fixture "$rel_manager_draft" "$good_tag" true true main
release_env_draft=(
  GUARD_EVENT=tag
  "GUARD_TAG=$good_tag"
  "GUARD_SELF_COMMIT=$appliance_sha"
  "GUARD_RELEASES_CRYPTOS_NODE=$rel_node"
  "GUARD_RELEASES_CRYPTOS_MANAGER=$rel_manager_draft"
  "GUARD_RELEASES_CRYPTOS_WEB=$rel_web"
  "GUARD_RELEASES_WEBSITE=$rel_website"
  "GUARD_RELEASES_CRYPTOS_APPLIANCE=$rel_appliance"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_draft[@]}" 2>&1)" || status=$?
assert_status "tag release: draft does not count" 1 "$status"
assert_contains "tag release: draft message" "no published prerelease for cryptos-manager" "$out"

# --- rehearsal-dispatch checks (workflow_dispatch on main) ---

disp_node="$work/disp-node.json"
disp_manager="$work/disp-manager.json"
disp_web="$work/disp-web.json"
disp_website="$work/disp-website.json"
disp_appliance="$work/disp-appliance.json"
releases_fixture "$disp_node" "$good_tag" true true main
releases_fixture "$disp_manager" "$good_tag" true true main
releases_fixture "$disp_web" "$good_tag" true true main
releases_fixture "$disp_website" "$good_tag" true true main
releases_fixture "$disp_appliance" "$good_tag" true true main

# Case 11: a good rehearsal, every one of the five repos' drafts matching
# the pin (pins.yaml's release: v0.1.0-rc.1).
release_env_dispatch_good=(
  GUARD_EVENT=dispatch
  "GUARD_SELF_COMMIT=$appliance_sha"
  "GUARD_RELEASES_CRYPTOS_NODE=$disp_node"
  "GUARD_RELEASES_CRYPTOS_MANAGER=$disp_manager"
  "GUARD_RELEASES_CRYPTOS_WEB=$disp_web"
  "GUARD_RELEASES_WEBSITE=$disp_website"
  "GUARD_RELEASES_CRYPTOS_APPLIANCE=$disp_appliance"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_dispatch_good[@]}" 2>&1)" || status=$?
assert_status "dispatch rehearsal: good drafts" 0 "$status"
assert_contains "dispatch rehearsal: good drafts message" "guard: OK" "$out"
assert_contains "dispatch rehearsal: prints the table" "rehearsal drafts vs pins" "$out"

# Case 12: website's draft is tagged for a different version than the pins.
disp_website_bad_tag="$work/disp-website-bad-tag.json"
releases_fixture "$disp_website_bad_tag" "v0.1.0-rc.2" true true main
release_env_dispatch_tagmismatch=(
  GUARD_EVENT=dispatch
  "GUARD_SELF_COMMIT=$appliance_sha"
  "GUARD_RELEASES_CRYPTOS_NODE=$disp_node"
  "GUARD_RELEASES_CRYPTOS_MANAGER=$disp_manager"
  "GUARD_RELEASES_CRYPTOS_WEB=$disp_web"
  "GUARD_RELEASES_WEBSITE=$disp_website_bad_tag"
  "GUARD_RELEASES_CRYPTOS_APPLIANCE=$disp_appliance"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_dispatch_tagmismatch[@]}" 2>&1)" || status=$?
assert_status "dispatch rehearsal: draft tag mismatch" 1 "$status"
assert_contains "dispatch rehearsal: draft tag mismatch message" "draft for website is tagged v0.1.0-rc.2, not $good_tag" "$out"

# Case 13: cryptos-manager's draft targets a branch other than main.
disp_manager_bad_target="$work/disp-manager-bad-target.json"
releases_fixture "$disp_manager_bad_target" "$good_tag" true true develop
release_env_dispatch_targetmismatch=(
  GUARD_EVENT=dispatch
  "GUARD_SELF_COMMIT=$appliance_sha"
  "GUARD_RELEASES_CRYPTOS_NODE=$disp_node"
  "GUARD_RELEASES_CRYPTOS_MANAGER=$disp_manager_bad_target"
  "GUARD_RELEASES_CRYPTOS_WEB=$disp_web"
  "GUARD_RELEASES_WEBSITE=$disp_website"
  "GUARD_RELEASES_CRYPTOS_APPLIANCE=$disp_appliance"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_dispatch_targetmismatch[@]}" 2>&1)" || status=$?
assert_status "dispatch rehearsal: draft target mismatch" 1 "$status"
assert_contains "dispatch rehearsal: draft target mismatch message" "draft for cryptos-manager targets develop, not main" "$out"

# Case 14: cryptos-web has no release-drafter draft at all.
disp_web_none="$work/disp-web-none.json"
no_releases_fixture "$disp_web_none"
release_env_dispatch_missing=(
  GUARD_EVENT=dispatch
  "GUARD_SELF_COMMIT=$appliance_sha"
  "GUARD_RELEASES_CRYPTOS_NODE=$disp_node"
  "GUARD_RELEASES_CRYPTOS_MANAGER=$disp_manager"
  "GUARD_RELEASES_CRYPTOS_WEB=$disp_web_none"
  "GUARD_RELEASES_WEBSITE=$disp_website"
  "GUARD_RELEASES_CRYPTOS_APPLIANCE=$disp_appliance"
)
out=""
status=0
out="$(run_guard_release "$release_pins" "$gomod" "${release_env_dispatch_missing[@]}" 2>&1)" || status=$?
assert_status "dispatch rehearsal: missing draft" 1 "$status"
assert_contains "dispatch rehearsal: missing draft message" "no release-drafter draft for cryptos-web" "$out"

if [ "$fail" -ne 0 ]; then
  echo "guard_test: FAILED" >&2
  exit 1
fi
echo "guard_test: all cases passed"

#!/usr/bin/env bash
# Print the build-number tag every published artifact file name carries (the
# ISO, the dist/ UKI copy, the cryptosctl binaries, SHA256SUMS lists the
# resulting names). git-describe style: the nearest tag plus a literal
# "-g<shortsha>", long form so the short SHA is present even on an exact tag,
# suffixed -dirty for a modified tree. CRYPTOS_VERSION overrides the tag/
# version portion only; the short SHA and dirty state always come from git
# HEAD. Without usable git metadata (a source tarball, no .git), prints "dev".
#
# Examples:
#   v0.1.0-5-g1a2b3c4          5 commits past v0.1.0, clean tree
#   v0.1.0-0-g1a2b3c4          built exactly at v0.1.0, clean tree
#   v0.1.0-0-g1a2b3c4-dirty    same commit, uncommitted changes
#   g1a2b3c4                   no tags reachable from HEAD yet
#   dev                        no git metadata at all
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

if ! short="$(git -C "$root" rev-parse --short HEAD 2>/dev/null)"; then
  echo dev
  exit 0
fi

dirty=""
git -C "$root" diff --quiet HEAD -- 2>/dev/null || dirty="-dirty"

if [ -n "${CRYPTOS_VERSION:-}" ]; then
  echo "${CRYPTOS_VERSION}-g${short}${dirty}"
elif describe="$(git -C "$root" describe --tags --long 2>/dev/null)"; then
  echo "${describe}${dirty}"
else
  echo "g${short}${dirty}"
fi

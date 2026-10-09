#!/usr/bin/env bash
# Write the build record for a set of release assets: the full commit, the
# short commit, dirty state, the version, and the build-number tag stamped
# into every artifact's file name by build/ci/artifact-name.sh. Prints JSON to
# stdout; the caller names the file (release-assets writes dist/build-manifest.json).
#
# Usage: build/ci/build-manifest.sh <artifact file>... > dist/build-manifest.json
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

version="${CRYPTOS_VERSION:-$(git -C "$root" describe --tags --always 2>/dev/null || echo dev)}"
build_tag="$("$here/artifact-name.sh")"

commit="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
short_commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty=false
if [ "$commit" != unknown ] && ! git -C "$root" diff --quiet HEAD -- 2>/dev/null; then
  dirty=true
fi

build_date="${SOURCE_DATE_EPOCH:+$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)}"
build_date="${build_date:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

printf '{\n'
printf '  "version": "%s",\n' "$version"
printf '  "build_tag": "%s",\n' "$build_tag"
printf '  "commit": "%s",\n' "$commit"
printf '  "short_commit": "%s",\n' "$short_commit"
printf '  "dirty": %s,\n' "$dirty"
printf '  "build_date": "%s",\n' "$build_date"
printf '  "artifacts": [\n'
n=$#
i=0
for f in "$@"; do
  i=$((i + 1))
  comma=","
  [ "$i" -eq "$n" ] && comma=""
  printf '    "%s"%s\n' "$(basename "$f")" "$comma"
done
printf '  ]\n'
printf '}\n'

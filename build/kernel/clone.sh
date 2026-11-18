#!/usr/bin/env bash
# Sourced by build.sh: fetch the pinned kernel with a retry.
#
# kernel_clone <version> <dest> shallow-clones the stable tag v<version> into
# <dest>. git.kernel.org is a single host that sometimes times out from hosted
# runners, so a failed attempt is retried after a pause, and the source can be
# replaced by a mirror. The tag is always the pinned one, whichever source
# serves it.
#
#   KERNEL_GIT_URL         source repository (default: git.kernel.org's stable tree)
#   KERNEL_CLONE_ATTEMPTS  attempts before giving up (default 4)
#   KERNEL_CLONE_PAUSE     seconds between attempts (default 15)

kernel_clone() {
  local version="$1" dest="$2"
  local url="${KERNEL_GIT_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
  local attempts="${KERNEL_CLONE_ATTEMPTS:-4}" pause="${KERNEL_CLONE_PAUSE:-15}"

  case "$attempts" in
    '' | *[!0-9]* | 0)
      echo "kernel: KERNEL_CLONE_ATTEMPTS must be a positive number, got '$attempts'" >&2
      return 1
      ;;
  esac
  case "$pause" in
    '' | *[!0-9]*)
      echo "kernel: KERNEL_CLONE_PAUSE must be a number of seconds, got '$pause'" >&2
      return 1
      ;;
  esac

  local n
  for ((n = 1; n <= attempts; n++)); do
    if git clone --depth 1 --branch "v${version}" "$url" "$dest"; then
      return 0
    fi
    # A failed clone can leave a partial tree that a rerun would trip over.
    rm -rf "$dest"
    if [ "$n" -lt "$attempts" ]; then
      echo "kernel: clone attempt $n of $attempts failed; retrying in ${pause}s" >&2
      sleep "$pause"
    fi
  done
  echo "kernel: could not clone linux v${version} from ${url} after ${attempts} attempts; set KERNEL_GIT_URL to a mirror or rerun" >&2
  return 1
}

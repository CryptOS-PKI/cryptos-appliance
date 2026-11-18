#!/usr/bin/env bash
# Unit test for the kernel clone's retry and source override (clone.sh). A stub
# git stands in for the network: it fails a set number of times, then succeeds.
#
# Usage: build/kernel/clone_test.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

# A git that records each call and fails the first $STUB_FAILS of them.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
n="$(wc -l <"$STUB_LOG" | tr -d ' ')"
if [ "$n" -le "${STUB_FAILS:-0}" ]; then
  echo "fatal: unable to access: connection timed out" >&2
  exit 128
fi
# git clone ... <url> <dest>: leave a checked-out tree behind.
dest="${*: -1}"
mkdir -p "$dest"
echo ok >"$dest/MARKER"
STUB
chmod +x "$tmp/bin/git"

run() { # run <fails> [env...]: clone into a fresh dest; sets $out and $rc
  local fails="$1"
  shift
  : >"$tmp/log"
  rm -rf "$tmp/src"
  set +e
  out="$(env PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_FAILS="$fails" \
    KERNEL_CLONE_PAUSE=0 "$@" bash -c '
      source "'"$here"'/clone.sh"
      kernel_clone 6.18.2 "'"$tmp"'/src"' 2>&1)"
  rc=$?
  set -e
  calls="$(wc -l <"$tmp/log" | tr -d ' ')"
}

check() { # check <name> <command...>: the command has to succeed
  local name="$1"
  shift
  if ! "$@"; then
    echo "FAIL $name"
    echo "$out"
    fail=1
  fi
}
not() { ! "$@"; }

# 1. Succeeds first time: one attempt, the pinned tag, the canonical source.
run 0
check "first attempt succeeds" test "$rc" = 0
check "one clone call" [ "$calls" = 1 ]
check "pinned tag" grep -q -- '--branch v6.18.2' "$tmp/log"
check "canonical source by default" grep -q 'https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git' "$tmp/log"
check "shallow" grep -q -- '--depth 1' "$tmp/log"

# 2. Fails twice, then succeeds: three attempts, success.
run 2 KERNEL_CLONE_ATTEMPTS=4
check "succeeds after two failures" test "$rc" = 0
check "three clone calls" [ "$calls" = 3 ]
check "tree is there" [ -f "$tmp/src/MARKER" ]

# 3. Fails every time: exactly the attempt limit, a clear message, non-zero.
run 99 KERNEL_CLONE_ATTEMPTS=3
check "gives up non-zero" [ "$rc" != 0 ]
check "stops at the attempt limit" [ "$calls" = 3 ]
check "clear final message" grep -q 'could not clone linux v6.18.2 from https://git.kernel.org.* after 3 attempts' <<<"$out"
check "no half-cloned tree left" [ ! -e "$tmp/src" ]

# 4. The source can be overridden, and the tag stays pinned.
run 0 KERNEL_GIT_URL=https://mirror.example.org/linux.git
check "override used" grep -q 'https://mirror.example.org/linux.git' "$tmp/log"
check "override keeps the pinned tag" grep -q -- '--branch v6.18.2' "$tmp/log"
check "override is not mixed with the default" not grep -q 'git.kernel.org' "$tmp/log"

# 5. Bad settings fail early, not after a pointless loop.
run 0 KERNEL_CLONE_ATTEMPTS=0
check "zero attempts is refused" [ "$rc" != 0 ]
run 0 KERNEL_CLONE_ATTEMPTS=abc
check "a non-number is refused" [ "$rc" != 0 ]
check "refused before cloning" [ "$calls" = 0 ]

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "clone_test: ok"

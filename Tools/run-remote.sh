#!/bin/zsh
# Run the end-to-end checks on another Mac, so they take that machine's
# resources instead of the one you are working on.
#
#   Tools/run-remote.sh                 # the default host below
#   Tools/run-remote.sh some-other-mac   # or name one
#   TYPE_E2E_CHECKS='selftest' Tools/run-remote.sh
#
# Why move them at all, when this project's checks were built not to steal the
# screen. `Diagnostics.isRunningCheck` is the reason they are polite: a check
# runs as an accessory, types through `insertText` rather than key events, and
# renders with `cacheDisplay`, so nothing here activates a window. That part
# needs no help. Three other things still land on whoever is at the keyboard:
#
#   - `selftest` and `speechbench` both depend on `quit-running`, which kills
#     any TYPE already running. On this desk that is the menu-bar app someone
#     is using, and it dies once per check.
#   - `speechbench` speaks through the speakers. There is no quiet mode; the
#     measurement is of real utterances.
#   - `speechbench` reports microseconds, and a machine compiling something
#     else is a machine that reports different microseconds.
#
# So this is not the sibling project's problem — `../scribing-paper` moves its
# XCUITest because XCUITest cannot be made polite at all. Here the checks are
# polite and the machine is still the wrong one.
#
# What the far end needs, all checked before anything is copied:
#   - a Swift toolchain, and Xcode's `actool` for the icon step
#   - a logged-in GUI session: the checks build NSWindow and render through it,
#     and a machine with no window server has nothing to render into
#
# It signs ad hoc, on purpose, and that is `SIGN_ID=-` on the make line below.
# The far end may well hold the Developer ID certificate, and an ssh session
# still cannot unlock the login keychain to use it, and codesign reports
# that as errSecInternalComponent, which names nothing. Ad hoc costs one thing,
# a re-grant of Input Monitoring per build, and no check here ever asks for
# that permission: the self-test pins the global sound off precisely so it
# cannot prompt.
#
# The tracked tree is copied as it stands, uncommitted edits and new files
# included, so what runs there is what you have here, and nothing .gitignore
# covers goes with it. `.git` is not copied, so `BUILD_NUMBER`
# falls back to 1 at the far end; nothing these checks assert reads it.
set -euo pipefail
cd "${0:A:h:h}"

# No host is baked in, and that is deliberate: this repository is public, and a
# machine name is a piece of somebody's network. It comes from the argument, or
# TYPE_E2E_HOST in the environment, or that one line of .env.
#
# One line, not the file. This used to `source .env` whole, which put the App
# Store Connect credentials that live there into this script's environment for
# no reason at all, and did it even when a host had been passed explicitly. Now
# .env is opened only when it is the last place left to look, and only the host
# is taken out of it.
HOST="${1:-${TYPE_E2E_HOST:-}}"
if [[ -z "$HOST" && -f .env ]]; then
  HOST=$(sed -n 's/^TYPE_E2E_HOST=//p' .env | tail -1 | tr -d "\"'")
fi
if [[ -z "$HOST" ]]; then
  print -u2 "usage: $0 <host>   (an ssh host that is not this Mac)"
  print -u2 "   or: set TYPE_E2E_HOST, in .env or the environment"
  exit 2
fi
REMOTE_DIR="${TYPE_E2E_DIR:-ci/type-review-app-macos}"
CHECKS="${TYPE_E2E_CHECKS:-test selftest speechbench}"

print "Checking $HOST can run them..."
ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "
  set -e
  command -v swift >/dev/null || { print -u2 'no Swift toolchain on $HOST'; exit 3; }
  command -v make  >/dev/null || { print -u2 'no make on $HOST'; exit 3; }
  xcrun --find actool >/dev/null 2>&1 || {
    print -u2 'no actool on $HOST: the icon step needs Xcode, not just the command line tools';
    exit 5;
  }
  user=\$(stat -f%Su /dev/console 2>/dev/null || echo '')
  [[ -n \"\$user\" && \"\$user\" != root ]] || {
    print -u2 'no one is logged in at the console on $HOST; the checks need a window server';
    exit 4;
  }
  mkdir -p '$REMOTE_DIR'
" || exit $?

print "Copying the tracked tree to $HOST:$REMOTE_DIR ..."
# What goes across is what git tracks, plus new files git would track: the
# working tree as it stands, uncommitted edits and all, and never a file
# .gitignore covers. That rule is the point. Ignored files are where a checkout
# keeps what must not travel. .env holds the App Store Connect credentials, and
# an earlier version of this script, which copied everything except a short
# list, put that file on the far end every run. A list of exclusions has to
# anticipate every secret anyone will ever add; asking git what the source is
# does not.
#
# The far end is an exact mirror, stale and ignored files deleted, which takes
# --delete-excluded. macOS's rsync is openrsync, and it ignores protect rules
# without a word. Measured: `P /.build/***`, `protect`, and every other variant
# deleted what it was meant to keep, and exited 0 each time. So the incremental
# build is not protected in place. It is moved aside before the copy and put
# back after, which asks nothing of rsync but the mirror it demonstrably does.
filters=$(mktemp)
trap 'rm -f "$filters"' EXIT
{
  git ls-files -co --exclude-standard | while IFS= read -r f; do
    [[ -e $f ]] || continue
    parts=(${(s:/:)f})
    acc=""
    for p in ${parts[1,-2]}; do
      acc+="$p/"
      print -r -- "+ /$acc"
    done
    print -r -- "+ /$f"
  done | sort -u
  print -r -- '- *'
} > "$filters"
# A list missing the package would mirror almost nothing and delete the rest of
# the far end with it. A git failure should stop here, not there.
grep -qx '+ /Package.swift' "$filters" || {
  print -u2 "git listed no Package.swift here; refusing to mirror what it did list"
  exit 8
}

CACHE="$REMOTE_DIR.build-cache"
ssh -o ConnectTimeout=10 "$HOST" "
  set -e
  if [ -d '$REMOTE_DIR/.build' ]; then
    rm -rf '$CACHE'; mkdir -p '$CACHE'; mv '$REMOTE_DIR/.build' '$CACHE/.build'
  fi
"
rsync -az --delete --delete-excluded --filter="merge $filters" ./ "$HOST:$REMOTE_DIR/"
# Put the build back, then check the mirror is what it claims. A run that died
# after the move left the build in the cache, and this restores it next time.
ssh -o ConnectTimeout=10 "$HOST" "
  set -e
  if [ -d '$CACHE/.build' ]; then mv '$CACHE/.build' '$REMOTE_DIR/.build'; rmdir '$CACHE'; fi
  test ! -e '$REMOTE_DIR/.env'
" || {
  print -u2 "the far end is not a clean mirror: a .env is present, or the build could not be restored"
  exit 7
}

print "Running: make SIGN_ID=- $CHECKS on $HOST ..."
# `status` is read-only in zsh, so the exit code needs a name of our own.
ssh -o ConnectTimeout=10 "$HOST" "cd '$REMOTE_DIR' && make SIGN_ID=- $CHECKS"
remote_status=$?
print "$HOST finished with status $remote_status."
exit $remote_status

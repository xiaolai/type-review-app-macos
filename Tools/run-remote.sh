#!/bin/zsh
# Run the end-to-end checks on another Mac, so they take that machine's
# resources instead of the one you are working on.
#
#   Tools/run-remote.sh <host>
#   TYPE_E2E_HOST=<host> Tools/run-remote.sh
#   TYPE_E2E_CHECKS='selftest' Tools/run-remote.sh <host>
#   TYPE_E2E_DRY_RUN=1 Tools/run-remote.sh <host>    checks and stages, contacts nothing
#   TYPE_E2E_FETCH=dist/screenshots ...              copies that folder back afterwards
#
# Why move them at all, when this project's checks were built not to steal the
# screen. `Diagnostics.isRunningCheck` is the reason they are polite: a check
# runs as an accessory, types through `insertText` rather than key events, and
# renders with `cacheDisplay`, so nothing here activates a window. That part
# needs no help. Three other things still land on whoever is at the keyboard:
#
#   - `selftest`, `soundcheck` and `speechbench` all depend on `quit-running`,
#     which kills any TYPE already running. On this desk that is the menu-bar
#     app someone is using, and it dies once per check.
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
# What crosses is exactly what Tools/stage-tree.sh stages: the files git lists
# for this checkout, uncommitted edits and new files included, and no file an
# ignore rule covers, tracked or not. `.git` is not copied, so `BUILD_NUMBER`
# falls back to 1 at the far end; nothing these checks assert reads it.
# `make runner-test` proves the staging and the checks below without a host.
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

# Every value below reaches a remote shell or a mirror that deletes, so each is
# checked for shape before it goes anywhere. The remote directory most of all:
# `TYPE_E2E_DIR=.` made the mirror target the far end's home folder, and the copy
# would have deleted everything in it that is not this repository. It has to be
# a relative path of plain names, none starting with a dot, which also rules out
# `.` and `..`. A trailing slash comes off first, because the cache path is made
# by appending to it and would otherwise land inside the mirror and be deleted.
refuse() { print -u2 "run-remote: $1"; exit 9; }
REMOTE_DIR="${TYPE_E2E_DIR:-ci/type-review-app-macos}"
while [[ $REMOTE_DIR == */ ]]; do REMOTE_DIR=${REMOTE_DIR%/}; done
CHECKS="${TYPE_E2E_CHECKS:-test selftest soundcheck speechbench}"
# What to bring back, for a check that makes something: a folder under dist/,
# which is gitignored output. Nothing else, so a fetch can never write over
# the sources here with the far end's copy of them.
FETCH="${TYPE_E2E_FETCH:-}"
[[ $HOST =~ '^[A-Za-z0-9_][A-Za-z0-9._@-]*$' ]] || refuse "host '$HOST' is not a plain ssh host name"
[[ $REMOTE_DIR =~ '^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$' ]] \
  || refuse "remote directory '$REMOTE_DIR' must be a relative path of plain names"
[[ $CHECKS =~ '^[a-z][a-z0-9-]*( [a-z][a-z0-9-]*)*$' ]] || refuse "checks '$CHECKS' must be make target names"
while [[ $FETCH == */ ]]; do FETCH=${FETCH%/}; done
[[ -z $FETCH || $FETCH =~ '^dist(/[A-Za-z0-9_][A-Za-z0-9_.-]*)+$' ]] \
  || refuse "fetch '$FETCH' must be a folder under dist/, of plain names"
CACHE="$REMOTE_DIR.build-cache"
LOCK="$REMOTE_DIR.lock"

stage=$(mktemp -d)
locked=0
cleanup() {
  rm -rf "$stage"
  if (( locked )); then
    ssh -o ConnectTimeout=10 "$HOST" "rmdir '$LOCK'" || print -u2 "run-remote: could not remove $HOST:$LOCK"
  fi
}
trap cleanup EXIT
count=$(Tools/stage-tree.sh "$stage")

if [[ -n ${TYPE_E2E_DRY_RUN:-} ]]; then
  print "dry run: $count files staged for $HOST:$REMOTE_DIR, build kept at $CACHE while copying"
  print "dry run: would run make SIGN_ID=- $CHECKS"
  [[ -n $FETCH ]] && print "dry run: would copy $HOST:$REMOTE_DIR/$FETCH back to $FETCH"
  exit 0
fi

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

# One run at a time. Two runs share the mirror and the build cache: one would
# move the build aside while the other's copy deleted it, and both would test a
# tree the other was still writing. `mkdir` is the lock because it is atomic.
lock_rc=0
ssh -o ConnectTimeout=10 "$HOST" "
  if mkdir '$LOCK' 2>/dev/null; then exit 0; elif [ -d '$LOCK' ]; then exit 11; else exit 12; fi
" || lock_rc=$?
if (( lock_rc == 11 )); then
  print -u2 "run-remote: another run holds $HOST:$LOCK. If none is running: ssh $HOST rmdir '$LOCK'"
  exit 11
elif (( lock_rc != 0 )); then
  print -u2 "run-remote: could not create the lock $HOST:$LOCK ($lock_rc)"
  exit 12
fi
locked=1

print "Copying $count files to $HOST:$REMOTE_DIR ..."
# The far end is an exact mirror of the staging directory. The incremental build
# is moved aside for the copy and put back after, not protected in place: macOS's
# rsync is openrsync, and it ignores protect rules without a word. Measured,
# `P /.build/***`, `protect` and every other variant deleted what they named, and
# exited 0 each time. A run that dies after the move leaves the build in the
# cache, and the next run restores it.
ssh -o ConnectTimeout=10 "$HOST" "
  set -e
  if [ -d '$REMOTE_DIR/.build' ]; then
    rm -rf '$CACHE'; mkdir -p '$CACHE'; mv '$REMOTE_DIR/.build' '$CACHE/.build'
  fi
"
rsync -az --delete "$stage/" "$HOST:$REMOTE_DIR/"
ssh -o ConnectTimeout=10 "$HOST" "
  set -e
  if [ -d '$CACHE/.build' ]; then mv '$CACHE/.build' '$REMOTE_DIR/.build'; rmdir '$CACHE'; fi
  test ! -e '$REMOTE_DIR/.env' && test ! -L '$REMOTE_DIR/.env'
" || {
  print -u2 "run-remote: the far end is not a clean mirror: a .env is present, or the build could not be restored"
  exit 7
}

print "Running: make SIGN_ID=- $CHECKS on $HOST ..."
remote_status=0
ssh -o ConnectTimeout=10 "$HOST" "cd '$REMOTE_DIR' && make SIGN_ID=- $CHECKS" || remote_status=$?
print "$HOST finished with status $remote_status."
# Whatever the status: a check that failed partway has made something worth
# reading. No --delete, so nothing already here is removed.
if [[ -n $FETCH ]]; then
  mkdir -p "$FETCH"
  if rsync -az "$HOST:$REMOTE_DIR/$FETCH/" "$FETCH/"; then
    print "Copied $HOST:$REMOTE_DIR/$FETCH back to $FETCH."
  else
    print -u2 "run-remote: could not copy $FETCH back from $HOST"
    (( remote_status == 0 )) && remote_status=13
  fi
fi
exit $remote_status

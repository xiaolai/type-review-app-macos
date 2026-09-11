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
# The working tree is copied as it stands, uncommitted changes included, so
# what runs there is what you have here. `.git` is not copied, so `BUILD_NUMBER`
# falls back to 1 at the far end; nothing these checks assert reads it.
set -euo pipefail
cd "${0:A:h:h}"

# No host is baked in, and that is deliberate: this repository is public, and a
# machine name is a piece of somebody's network. It comes from the argument, or
# from TYPE_E2E_HOST, which .env is the right place for — .gitignore covers it
# and the upload credentials already live there.
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
HOST="${1:-${TYPE_E2E_HOST:-}}"
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

print "Copying the working tree to $HOST:$REMOTE_DIR ..."
# --delete keeps the far end honest. .build and TYPE.app are excluded from both
# the copy and the delete, so the remote keeps its own incremental build rather
# than recompiling the world every run.
rsync -az --delete \
  --exclude '.git/' --exclude '.build/' --exclude 'TYPE.app/' \
  --exclude 'TypeReview.app/' --exclude 'dist/' --exclude 'dev-docs/' \
  --exclude '.cc-suite/' --exclude '.DS_Store' \
  ./ "$HOST:$REMOTE_DIR/"

print "Running: make SIGN_ID=- $CHECKS on $HOST ..."
# `status` is read-only in zsh, so the exit code needs a name of our own.
ssh -o ConnectTimeout=10 "$HOST" "cd '$REMOTE_DIR' && make SIGN_ID=- $CHECKS"
remote_status=$?
print "$HOST finished with status $remote_status."
exit $remote_status

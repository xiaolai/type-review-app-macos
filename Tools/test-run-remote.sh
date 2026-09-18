#!/bin/zsh
# Proves Tools/stage-tree.sh and the value checks in Tools/run-remote.sh against
# every filename and value that has broken them, without contacting any host.
#
# Each case here is a real failure, not a hypothetical. A file named `*` made the
# runner copy `.env`. A name git quotes was silently left out. A tracked file an
# ignore rule covers was copied. `TYPE_E2E_DIR=.` pointed a deleting mirror at a
# home folder. None of it shows up anywhere else, because nothing else creates
# those files or passes those values.
set -euo pipefail
repo_root=${0:A:h:h}
stage_tree=$repo_root/Tools/stage-tree.sh
runner=$repo_root/Tools/run-remote.sh
failures=0
fail() { print -u2 "FAIL: $1"; failures=$((failures + 1)); }
pass() { print "ok:   $1"; }
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
commit() { git -c user.email=test@example.invalid -c user.name=test commit -qm fixture; }

# --- staging: a repository holding every name that has broken a copy rule ---
repo=$root/repo
mkdir -p $repo && cd $repo && git init -q
printf '.env\nignored-but-tracked.txt\nkeep/*\n!keep/wanted.txt\n' > .gitignore
print 'SECRET=placeholder' > .env
print swift > Package.swift
print a > '*'; print b > '[x].txt'; print c > 'café.txt'; print d > 'with space.txt'
mkdir -p Sources/Kit keep
print e > Sources/Kit/A.swift; print f > keep/wanted.txt; print g > keep/other.txt
print h > ignored-but-tracked.txt
git add .gitignore Package.swift 'café.txt' Sources/Kit/A.swift keep/wanted.txt
git add -f ignored-but-tracked.txt
commit
touch -t 202001010000 Sources/Kit/A.swift
expected=('*' '.gitignore' 'Package.swift' 'Sources/Kit/A.swift' '[x].txt' 'café.txt' 'keep/wanted.txt' 'with space.txt')

dest=$root/stage
mkdir -p $dest
rc=0
count=$("$stage_tree" "$dest") || rc=$?
if (( rc != 0 )); then
  fail "stage-tree.sh exited $rc on the fixture"
else
  staged=$(cd $dest && find . \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort)
  want=$(printf '%s\n' "${expected[@]}" | LC_ALL=C sort)
  # Quoted: unquoted, the right side of == is a glob, and `*` in it matches anything.
  if [[ $staged == "$want" ]]; then pass "stages exactly what git lists, awkward names included"
  else fail "staged [${staged//$'\n'/|}] expected [${want//$'\n'/|}]"; fi
  if [[ $count == ${#expected} ]]; then pass "reports the $count files it staged"; else fail "reported $count, expected ${#expected}"; fi
  if [[ ! -e $dest/.env ]]; then pass ".env stays behind"; else fail ".env was staged"; fi
  if [[ ! -e $dest/ignored-but-tracked.txt ]]; then pass "a tracked file an ignore rule covers stays behind"; else fail "a tracked ignored file was staged"; fi
  if [[ ! -e $dest/keep/other.txt ]]; then pass "an ignored untracked file stays behind"; else fail "keep/other.txt was staged"; fi
  if [[ $(stat -f %m Sources/Kit/A.swift) == $(stat -f %m $dest/Sources/Kit/A.swift) ]]; then pass "modification times survive, so the far end builds incrementally"
  else fail "a modification time changed"; fi
fi

expect_exit() {  # expected-code label command...
  local want=$1 label=$2; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if (( got == want )); then pass "$label"; else fail "$label: exited $got, expected $want"; fi
}
nonempty=$root/nonempty; mkdir -p $nonempty; print x > $nonempty/f
expect_exit 2 "refuses to stage into a directory that is not empty" "$stage_tree" "$nonempty"

bare=$root/bare
mkdir -p $bare && cd $bare && git init -q
print x > PackageXswift && git add PackageXswift && commit
mkdir -p $root/stage2
expect_exit 8 "refuses a tree with no Package.swift, even one holding PackageXswift" "$stage_tree" "$root/stage2"

# --- the runner's value checks, as a dry run from this repository ---
cd $repo_root
dry() { TYPE_E2E_DRY_RUN=1 TYPE_E2E_DIR=$2 TYPE_E2E_CHECKS=$3 "$runner" "$1"; }
expect_exit 9 "refuses a remote directory of ." dry example.invalid . test
expect_exit 9 "refuses a remote directory of .." dry example.invalid .. test
expect_exit 9 "refuses an absolute remote directory" dry example.invalid /tmp/x test
expect_exit 9 "refuses a remote directory with .. inside" dry example.invalid ci/../x test
expect_exit 9 "refuses a remote directory of ~" dry example.invalid '~' test
expect_exit 9 "refuses a remote directory with a space" dry example.invalid 'ci/a b' test
expect_exit 9 "refuses a host that is an ssh option" dry -oProxyCommand=true ci/x test
expect_exit 9 "refuses checks that are not make target names" dry example.invalid ci/x 'test; rm -rf ~'
fetch() { TYPE_E2E_DRY_RUN=1 TYPE_E2E_DIR=ci/x TYPE_E2E_CHECKS=test TYPE_E2E_FETCH=$1 "$runner" example.invalid; }
expect_exit 9 "refuses to fetch anything outside dist/" fetch Sources
expect_exit 9 "refuses to fetch dist/ itself" fetch dist
expect_exit 9 "refuses to fetch with .. inside" fetch dist/../Sources
expect_exit 9 "refuses to fetch a dot-folder under dist/" fetch dist/.env
expect_exit 9 "refuses an absolute fetch" fetch /tmp/x
expect_exit 0 "accepts a folder under dist/" fetch dist/screenshots/
out=$(dry example.invalid ci/x/ selftest 2>&1) || true
if [[ $out == *'example.invalid:ci/x,'* && $out == *'ci/x.build-cache'* ]]; then
  pass "strips a trailing slash before deriving the cache path"
else fail "trailing slash: $out"; fi

if (( failures )); then print -u2 "$failures check(s) failed"; exit 1; fi
print "all runner checks passed"

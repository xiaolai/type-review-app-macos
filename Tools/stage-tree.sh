#!/bin/zsh
# Copies exactly the files git lists for this checkout into an empty directory,
# for Tools/run-remote.sh to mirror to another Mac.
#
#   Tools/stage-tree.sh <empty directory>     prints the number of files staged
#
# A staging directory rather than rsync filter rules, because a filter rule is a
# pattern. The runner used to write each listed path into an include rule, so a
# file named `*` became `+ /*`, which admits everything, `.env` and its App Store
# Connect credentials included. And a name git quotes, anything with an accent
# or a tab, was looked up by its quoted form, not found, and silently left out.
# Here paths travel NUL-delimited only, and the mirror is of a directory that
# holds nothing else, so no filename is ever read as anything but a name.
#
# What is staged: tracked files and untracked files git would add, minus every
# file an ignore rule covers, tracked or not. `ls-files --exclude-standard` on
# its own keeps a tracked file an ignore rule matches; `check-ignore --no-index`
# judges those too. The staged tree is then asked the same question again, from
# the far side of the copy, before anything leaves this Mac.
#
# Exit codes: 2 usage, 8 nothing sensible to stage, 10 an ignored file would
# have been staged, or git could not say.
set -euo pipefail

dest=${1:-}
if [[ -z $dest || ! -d $dest ]]; then print -u2 "usage: stage-tree.sh <empty directory>"; exit 2; fi
if [[ -n "$(ls -A -- "$dest")" ]]; then print -u2 "stage-tree: $dest is not empty"; exit 2; fi
dest=${dest:A}
cd "$(git rev-parse --show-toplevel)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git ls-files -co --exclude-standard -z > "$work/listed"

# check-ignore exits 1 when nothing it was given is ignored. That is the
# ordinary answer, not a failure; anything above 1 is.
rc=0
git check-ignore --no-index --stdin -z -v -n < "$work/listed" > "$work/verdicts" || rc=$?
if (( rc > 1 )); then print -u2 "stage-tree: git check-ignore failed with $rc"; exit 10; fi

: > "$work/manifest"
count=0
# Not `path`: in zsh that name is the command search path, and reading a
# filename into it leaves nothing on PATH for the lines after.
while IFS= read -r -d '' rule_file && IFS= read -r -d '' rule_line \
    && IFS= read -r -d '' pattern && IFS= read -r -d '' file; do
  # A pattern starting with ! re-includes the file. Any other pattern ignores it.
  if [[ -n $pattern && $pattern != '!'* ]]; then continue; fi
  # Listed by git but deleted in the working tree.
  if [[ ! -e $file && ! -L $file ]]; then continue; fi
  printf '%s\0' "$file" >> "$work/manifest"
  count=$((count + 1))
done < "$work/verdicts"

if (( count == 0 )); then print -u2 "stage-tree: git listed no files here"; exit 8; fi
# cp, one file at a time, not tar or cpio. On macOS both are libarchive, and
# libarchive decomposes accented names as it archives them: café arrived as
# "cafe" plus a combining accent, which is a different name to rsync and to the
# byte comparison in the test. cp takes the name it is given. -p keeps the
# modification times the far end's incremental build depends on; -P copies a
# symlink as a symlink.
while IFS= read -r -d '' file; do
  if [[ $file == */* ]]; then mkdir -p -- "$dest/${file%/*}"; fi
  cp -pP -- "$file" "$dest/$file"
done < "$work/manifest"
if [[ ! -f $dest/Package.swift || -L $dest/Package.swift ]]; then
  print -u2 "stage-tree: what git listed has no Package.swift; refusing to stage it"
  exit 8
fi

# The same rule, asked about what actually landed.
(cd "$dest" && find . \( -type f -o -type l \) -print0) > "$work/found"
: > "$work/staged"
while IFS= read -r -d '' p; do printf '%s\0' "${p#./}" >> "$work/staged"; done < "$work/found"
rc=0
git check-ignore --no-index --stdin -z < "$work/staged" > "$work/flagged" || rc=$?
if (( rc > 1 )); then print -u2 "stage-tree: git check-ignore failed with $rc"; exit 10; fi
if [[ -s $work/flagged ]]; then
  print -u2 "stage-tree: staged files that git ignores:"
  tr '\0' '\n' < "$work/flagged" >&2
  exit 10
fi
print -r -- "$count"

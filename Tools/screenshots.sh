#!/bin/zsh
# Renders the App Store screenshots from a copy of the built app that cannot
# touch a TYPE in use.
#
#   Tools/screenshots.sh <app> <output folder>
#
# The copy has its own bundle identifier, so its preferences are its own and
# are deleted afterwards, and a scratch home, so the profile it types into is
# one it made. It puts a window on screen, which is why `make screenshots` is
# meant to be run on another Mac:
#
#   TYPE_E2E_CHECKS=screenshots TYPE_E2E_FETCH=dist/screenshots \
#     make remote REMOTE_HOST=<host>
set -euo pipefail
(( $# == 2 )) || { print -u2 "usage: $0 <app> <output folder>"; exit 2; }
app=$1
out=$2
id=review.type.app.screenshots
work=$(mktemp -d)
awake=
cleanup() {
  [[ -n $awake ]] && kill "$awake" 2>/dev/null
  rm -rf "$work"
  defaults delete "$id" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cp -R "$app" "$work/TYPE.app"
plist="$work/TYPE.app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$id" "$plist"
[[ $(plutil -extract CFBundleIdentifier raw "$plist") == "$id" ]] \
  || { print -u2 "screenshots: the copy's bundle identifier did not change"; exit 3; }
codesign --force --deep --sign - "$work/TYPE.app" 2>/dev/null
mkdir -p "$work/home" "$out"
out=${out:A}
# Launched through LaunchServices, as a person launches it, because only then
# is it let in front: macOS turns down a background process asking to be
# active while another app is, and a window that is not key is drawn in its
# inactive state. `-W` waits for it to quit, and the log is what says whether
# it succeeded, since `open` does not pass the app's exit status on.
#
# Two arguments go to the app's argument domain, which nothing persists: the
# caret held still, since a blinking one may be caught off; and Settings opened
# on its Sound pane, named rather than numbered because the panes can be
# reordered.
# The display awake for the run. With it asleep, a locked Mac leaves the lock
# screen in front and nothing else may be — so every window rendered inactive,
# while the same run minutes earlier, display still on, came out right.
# `-u` declares a user present, which is what wakes it; the lock stays.
caffeinate -u -t 900 & awake=$!
log="$work/screenshots.log"
open -W -n --env CFFIXED_USER_HOME="$work/home" --stdout "$log" --stderr "$log" "$work/TYPE.app" \
  --args --screenshots "$out" -NSTextInsertionPointBlinkPeriod 0 -SettingsLastPane Sound
cat "$log"
grep -q '^SCREENSHOTS OK' "$log" || { print -u2 "screenshots: the app did not finish; see above"; exit 1; }
xcrun swiftc -O -o "$work/compose" "${0:A:h}/compose-screenshots.swift"
"$work/compose" "$out/raw" "$out"

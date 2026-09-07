# Assembles the .app bundle around the SPM executable. A window needs an
# Info.plist and a bundle identifier; `swift run` alone gives neither.

# Named for the app, not for the repo. macOS labels the Dock item from the
# bundle, and a bundle called TypeReview.app under an app called TYPE gets a
# Dock tooltip that disagrees with its own menu bar.
# Which channel this build is for. Two of them, and they differ in three
# things: whether the sandbox entitlement is applied, which bundle identifier
# the app carries, and where the bundle lands. Everything else — sources,
# resources, signing identity while there is only one — is shared, which is the
# point of having measured that a single event path works under both.
#
#   make                     the direct build, for Homebrew
#   make VARIANT=appstore    sandboxed, for the App Store
#   make appstore            the same, spelled shorter
#
# The App Store build cannot be signed for submission yet: that needs an Apple
# Distribution certificate and this keychain has only a Developer ID. Signed
# with Developer ID it is still a valid, runnable, sandboxed app — which is how
# the sandbox was verified in the first place.
VARIANT ?= direct

ifeq ($(VARIANT),appstore)
BUNDLE_ID    := review.type.app
ENTITLEMENTS := sandbox.entitlements
APP          := .build/appstore/TYPE.app
else ifeq ($(VARIANT),direct)
BUNDLE_ID    := review.type.app.direct
ENTITLEMENTS :=
APP          := TYPE.app
else
$(error VARIANT must be `direct` or `appstore`, not `$(VARIANT)`)
endif

BIN      := TypeReviewApp
CONFIG   := release

# A real identity, not ad-hoc, and the reason is Input Monitoring.
#
# TCC does not remember "this app"; it remembers a *code requirement*. For a
# Developer ID signature that requirement names the team and the bundle
# identifier, both of which survive a rebuild. An ad-hoc signature has no
# identity to name, so its requirement falls back to the cdhash — which changes
# whenever a byte of the binary does. Every `make all` therefore produced an
# app macOS considered a stranger, and the system-wide keystroke sound had to
# be permitted again after every single build.
#
# Overridable, and honoured only if the certificate is actually in the
# keychain: a clone on another Mac still builds, ad hoc, with a warning that
# says what it costs.
# The build number, which nothing used to move. `CFBundleVersion` sat at 1
# through every commit this project has, and both channels care: the App Store
# refuses an upload whose build number is not higher than the last, and a
# Homebrew cask is a version plus a checksum that has to mean something.
#
# The commit count, because it is monotonic without anyone remembering to make
# it so, and it is a number a human can still relate to a point in history.
# Falls back to 1 outside a repository, so a tarball still builds.
#
# `CFBundleShortVersionString` stays hand-edited in Info.plist: what to call a
# release is a decision, not a count.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

SIGN_ID ?= Developer ID Application: HANDO K.K. (Y53RSUA3SM)

# Credentials stored by `xcrun notarytool store-credentials`. Shared across
# this developer's projects rather than duplicated per repository: the profile
# authenticates the *account*, not the app, and a second copy of the same
# password is a second thing to rotate.
NOTARY_PROFILE ?= chase-notary

# Apple's notary service drops connections, and notarytool has no internal
# retry: a timed-out status poll fails the build even though the upload
# succeeded and the submission is Accepted server-side. Retry the whole call
# and fail loudly only once the attempts are spent.
define retry
	@for i in 1 2 3 4 5; do \
		if $(1); then exit 0; fi; \
		echo "attempt $$i failed, retrying in 10s"; sleep 10; \
	done; \
	echo "FAIL: gave up after 5 attempts: $(1)"; exit 1
endef
# Assembled here and published only when every check has passed. Writing
# straight into $(APP) meant a failure half way through left a bundle that was
# incomplete *and* newer than its sources — so the next `make`, `run` or
# `selftest` considered it up to date and ran it.
# Per variant, and flat. Both variants staged through one path, so two
# builds in flight could publish each other's half-assembled bundle.
STAGE    := .build/stage-$(VARIANT)/TYPE.app
CONTENTS := $(STAGE)/Contents

SOURCES := $(shell find Sources -name '*.swift')
CORPUS  := $(shell find Sources/TypeReviewKit/Resources -type f)
# The Icon Composer document, and every file in it. Listed as prerequisites so
# that editing the layer or the gradient rebuilds the bundle; a catalogue that
# silently kept yesterday's icon would be indistinguishable from one that
# recompiled.
ICON_DOC    := Resources/AppIcon.icon
ICON_SOURCE := $(shell find $(ICON_DOC) -type f 2>/dev/null)

# What the app is built *from*, beyond the files listed as prerequisites.
#
# Two inputs cannot be prerequisites at all. `CONFIG` is a variable, so
# `make CONFIG=debug` used to report nothing to do and leave the release binary
# in place under a name claiming to be a debug build. And a *deleted* source
# file simply drops out of `$(shell find)`, leaving the app newer than
# everything still on disk.
#
# Neither is a staleness a timestamp can express, so neither is left to one.
# The signature is compared while this makefile is being read — before any
# target is considered — and a bundle that does not match is removed outright.
# The stamp is written by the recipe, after a successful build, so an
# interrupted one does not leave a signature claiming work that never finished.
#
# An earlier attempt made the stamp a FORCE-dependent prerequisite and let make
# compare mtimes. It worked exactly once: after the first switch the app was
# newer than the stamp again, and `make CONFIG=debug` followed by `make` left
# the debug bundle in place while reporting nothing to do — the very defect it
# was written to fix, surviving because `make -n` cannot show it.
# Per variant: the two produce different bundles from identical sources,
# so one stamp let a variant switch leave the other's bundle looking current.
INPUT_STAMP := .build/inputs-stamp-$(VARIANT)
# Everything that decides the bundle's contents. Sources and configuration
# were here; the identifier, entitlements, build number and signing identity
# were not, and each changes the output while every source file stays put.
# The entitlements file is hashed, not merely named: editing it changes what
# the signature grants while its path stays the same.
ENTITLEMENTS_SIG := $(if $(ENTITLEMENTS),$(shell shasum -a 256 $(ENTITLEMENTS) 2>/dev/null | cut -d' ' -f1),none)
INPUT_SIG   := $(CONFIG)|$(BUNDLE_ID)|$(ENTITLEMENTS_SIG)|$(BUILD_NUMBER)|$(SIGN_ID)|$(sort $(SOURCES))
# Only when this invocation is actually going to build the app, and never on a
# dry run. The check removes a mismatched bundle, and doing that at parse time
# meant `make test CONFIG=debug` — or even `make -n` — destroyed a perfectly
# good release build without replacing it.
GOALS      := $(or $(MAKECMDGOALS),all)
# Every goal that ends up building the app. `zip` and `notarize` do, and
# were missing, so a configuration change could be packaged from a stale
# bundle — the one place a stale bundle actually leaves the machine.
# `appstore` is deliberately absent: it re-invokes make with VARIANT set, and
# the inner invocation does its own invalidation with the right signature.
# Listing it here ran the check in the *outer* process, where VARIANT is still
# `direct` — so `make appstore` deleted the direct bundle on its way past.
BUILDS_APP := $(filter all run selftest zip notarize $(APP),$(GOALS))
DRY_RUN    := $(findstring n,$(firstword -$(MAKEFLAGS)))
ifneq ($(BUILDS_APP),)
ifeq ($(DRY_RUN),)
_ := $(shell mkdir -p .build; \
        [ "$$(cat $(INPUT_STAMP) 2>/dev/null)" = "$(INPUT_SIG)" ] || rm -rf $(APP) $(INPUT_STAMP))
endif
endif

# Stated, not inferred from position. Twice now a new target has been added
# above `all` and silently become the default — `make` printing a version, or
# checking password managers, instead of building the app. Both times the
# build looked like it succeeded. Make's rule is "the first target in the
# file", which is a property of where a line was pasted rather than of intent.
# Recipes here assemble, sign, notarize and archive one bundle through shared
# paths; none of it is safe to interleave, and `make -j notarize zip` could
# archive while stapling was still running. Saying so is cheaper than making
# every step independently parallel-safe for a build that takes seconds.
.NOTPARALLEL:

.DEFAULT_GOAL := all

.PHONY: all run selftest test icon clean notarize password-managers version appstore zip release

all: $(APP)

$(APP): $(SOURCES) $(CORPUS) Package.swift Makefile Info.plist $(ENTITLEMENTS) \
        Resources/TypeReview.icns Resources/typewriter.m4a $(ICON_SOURCE)
	swift build -c $(CONFIG) --product $(BIN)
	@rm -rf "$(STAGE)"
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp .build/$(CONFIG)/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	@cp Info.plist $(CONTENTS)/Info.plist
	# Stamped into the copy, not into the tracked file: the repository's
	# Info.plist would otherwise change on every commit, and a build number
	# that is a property of the build does not belong in source control.
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" \
		$(CONTENTS)/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" \
		$(CONTENTS)/Info.plist
	# And check it landed. PlistBuddy reports success for a key it did not
	# write when the type disagrees, which is the kind of silence this
	# project has been bitten by before.
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' $(CONTENTS)/Info.plist)" \
		= "$(BUILD_NUMBER)" \
		|| { echo "error: CFBundleVersion did not take"; exit 1; }
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $(CONTENTS)/Info.plist)" \
		= "$(BUNDLE_ID)" \
		|| { echo "error: CFBundleIdentifier did not take"; exit 1; }
	@cp Resources/TypeReview.icns $(CONTENTS)/Resources/TypeReview.icns
	# The same mark a second time, as an Icon Composer document compiled to
	# an asset catalogue. macOS 26 draws app icons itself — it shapes them,
	# lights them, and re-lights them for dark mode and tinting — and it can
	# only do that for an icon supplied as contents rather than as a
	# finished picture. Given only the .icns it fills our transparent margin
	# with white and rounds the result, which is how this app came to sit in
	# a cream plate in the Dock.
	#
	# Both keys ship. macOS 26 reads CFBundleIconName and gets the glass;
	# 14 and 15 read CFBundleIconFile and get the painted tile, which is
	# what those versions expect, because they draw an icon exactly as
	# handed over.
	# The partial plist goes beside the bundle, not inside it: $(STAGE) is
	# the .app itself, and anything left in a bundle's root that signing was
	# not told about is "unsealed contents" and fails codesign outright.
	@xcrun actool --compile $(CONTENTS)/Resources --app-icon AppIcon \
		--output-partial-info-plist $(dir $(STAGE))icon-partial.plist \
		--platform macosx --minimum-deployment-target 14.0 --target-device mac \
		--errors --warnings $(ICON_DOC) >/dev/null
	# actool also flattens the document to an .icns. We do not use it —
	# CFBundleIconFile points at the hand-drawn tile, which is the whole
	# reason both files exist — and an unreferenced 50 KB in a shipped
	# bundle is just weight.
	@rm -f $(CONTENTS)/Resources/AppIcon.icns
	@/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" \
		$(CONTENTS)/Info.plist >/dev/null
	# Three assertions, because every step above can fail while looking like
	# it worked. actool exits 0 having written nothing if it decides there
	# is no icon to compile; a catalogue can exist and carry only flattened
	# bitmaps, which is the old icon wearing the new file name; and
	# PlistBuddy reports success for keys it did not write.
	@test -s "$(CONTENTS)/Resources/Assets.car" \
		|| { echo "error: actool wrote no Assets.car"; exit 1; }
	@xcrun assetutil --info $(CONTENTS)/Resources/Assets.car 2>/dev/null \
		| grep -q 'IconImageStack' \
		|| { echo "error: Assets.car has no IconImageStack — no Liquid Glass"; exit 1; }
	@test "$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' $(CONTENTS)/Info.plist)" \
		= "AppIcon" || { echo "error: CFBundleIconName did not take"; exit 1; }
	# The typewriter sound pack's recording. Loaded through `Bundle.main`,
	# so it goes straight into Contents/Resources rather than through a
	# SwiftPM resource bundle — which is also why it sidesteps the
	# generated-accessor trap the corpus bundle fell into.
	cp Resources/typewriter.m4a $(CONTENTS)/Resources/typewriter.m4a
	# SwiftPM puts a target's resources in its own .bundle beside the binary.
	# Without this the corpus is simply absent at runtime and the app falls
	# back to generated words — silently, because a missing corpus and an
	# empty one look identical to the picker.
	#
	# No `|| true`. That is what let this step fail unnoticed for the whole
	# life of the project: the app still ran, because SwiftPM's generated
	# accessor falls back to an absolute path inside .build, so the corpus was
	# being read from the build directory of this machine rather than from the
	# app. Delete .build — or copy the app to any other Mac — and it died on
	# launch. A build step that cannot do its job must stop the build.
	# Named, not globbed. `*.bundle` also swept up whatever else the build
	# directory happened to hold — test resource bundles left by
	# `swift test -c release`, and bundles from targets that no longer
	# exist — so what shipped depended on this machine's build history.
	cp -R .build/$(CONFIG)/TypeReview_TypeReviewKit.bundle $(CONTENTS)/Resources/
	# And prove it landed, rather than trusting that cp said nothing. The
	# assertion is the part that stops this regressing quietly a second time.
	@test -d "$(CONTENTS)/Resources/TypeReview_TypeReviewKit.bundle/Resources/code" \
		|| { echo "error: corpus bundle missing from $(APP)" >&2; exit 1; }
	@test -s "$(CONTENTS)/Resources/typewriter.m4a" \
		|| { echo "error: typewriter sample missing from $(APP)" >&2; exit 1; }
	# stdout silenced, stderr kept. Sending both to /dev/null left a signing
	# failure showing as make's generic "Error 1" with nothing to act on.
	#
	# `--options runtime` because that is how the app would ship, and a
	# hardened runtime is worth discovering at build time rather than at
	# notarisation. `--timestamp=none` because a secure timestamp needs
	# Apple's server: it is required to notarise and pointless for a local
	# build, and requiring it would make `make` fail on a train.
	@if security find-identity -v -p codesigning | grep -q "$(SIGN_ID)"; then \
		codesign --force --options runtime --timestamp=none \
			$(if $(ENTITLEMENTS),--entitlements $(ENTITLEMENTS),) \
			--sign "$(SIGN_ID)" "$(STAGE)" >/dev/null; \
	else \
		echo "warning: signing identity not in the keychain: $(SIGN_ID)"; \
		echo "         falling back to ad hoc — macOS will treat each build as a"; \
		echo "         different app, so Input Monitoring must be granted again"; \
		echo "         after every one."; \
		codesign --force --sign - --timestamp=none \
			$(if $(ENTITLEMENTS),--entitlements $(ENTITLEMENTS),) "$(STAGE)" >/dev/null; \
	fi
	# Proved, not assumed. A signature that does not verify is worse than none:
	# the app launches until Gatekeeper decides otherwise.
	@codesign --verify --strict "$(STAGE)"
	# Published only now, and by rename, so $(APP) is either the previous
	# good bundle or this one — never a half-built mixture of the two.
	@rm -rf $(APP)
	@mkdir -p $(dir $(APP))
	@mv "$(STAGE)" $(APP)
	@printf '%s' '$(INPUT_SIG)' > $(INPUT_STAMP)
	@echo "built $(APP) ($$(du -sh $(APP) | cut -f1))"

run: $(APP)
	open $(APP)

# Drives a complete run through the real input path and checks what reached
# disk. Unit tests cover the engine exhaustively and none of them can tell
# whether the app is wired to it.
selftest: $(APP)
	@./$(APP)/Contents/MacOS/$(BIN) --selftest

test:
	swift test

# Regenerates the icon set. The .icns is committed, so this runs only when
# the artwork changes — Tools/make-icon.swift is the artwork.
#
# One shell, one temporary directory, one trap. The fixed /tmp paths this used
# to write were shared by every checkout and every concurrent run: two of them
# overwrote each other's artwork, and the files were left behind either way.
icon:
	# Every comment in this recipe sits above `@set -e`, not inside it. A `#`
	# line without a trailing backslash ends the shell command it is standing
	# in the middle of, and make then runs the rest as separate invocations --
	# so `work` came back empty, swiftc wrote to /make-icon, and the whole
	# thing still exited 0 because the last echo succeeded.
	#
	# The tool is compiled with the app's own copy of the mark rather than a
	# duplicate of it: one definition, two drawers. It is copied to main.swift
	# first because Swift allows top-level statements only in a file of that
	# name, and only when it is not the sole file in the module. The tool keeps
	# its readable name in the repository and gets the name the compiler
	# insists on inside the work directory.
	@set -e; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	before=$$(shasum -a 256 "$(ICON_DOC)/Assets/mark.svg" 2>/dev/null | cut -d" " -f1 || true); \
	cp Tools/make-icon.swift "$$work/main.swift"; \
	swiftc -O "$$work/main.swift" Sources/TypeReviewApp/IconMark.swift \
		-o "$$work/make-icon"; \
	test -x "$$work/make-icon" \
		|| { echo "error: the generator did not build"; exit 1; }; \
	"$$work/make-icon" "$$work/TypeReview.iconset" "$(ICON_DOC)/Assets/mark.svg"; \
	test "$$(ls "$$work/TypeReview.iconset"/*.png | wc -l | tr -d " ")" = "10" \
		|| { echo "error: the iconset is not ten representations"; exit 1; }; \
	iconutil -c icns "$$work/TypeReview.iconset" -o Resources/TypeReview.icns; \
	after=$$(shasum -a 256 "$(ICON_DOC)/Assets/mark.svg" | cut -d" " -f1); \
	test -n "$$after" \
		|| { echo "error: the Liquid Glass layer was not written"; exit 1; }; \
	if [ -n "$$before" ] && [ "$$before" = "$$after" ]; then \
		echo "note: the layer is unchanged (same geometry, same bytes)"; \
	fi; \
	echo "wrote Resources/TypeReview.icns ($$(du -h Resources/TypeReview.icns | cut -f1))"; \
	echo "wrote $(ICON_DOC)/Assets/mark.svg"

# Notarised and stapled, so the app passes Gatekeeper on a Mac that has never
# seen it — offline included. Without a stapled ticket it only passes while the
# machine can reach Apple to look the ticket up, which is exactly the moment a
# first launch tends not to be able to.
#
# Re-signs the bundle rather than rebuilding it. Notarisation requires a secure
# timestamp and ordinary builds deliberately skip one, so this replaces the
# signature in place — a rebuild here would also mean any later `make all`
# silently discarding a stapled ticket it had just earned.
# What a build would call itself. Useful before tagging or submitting, and
# cheap enough to run when a version number looks wrong.
# A distributable archive of the direct build, plus the checksum a Homebrew
# cask needs.
#
# `ditto -c -k --keepParent`, because that is the incantation Apple documents
# for submitting and distributing an app, and matching the documented path
# costs nothing.
#
# Not for the reason first written here. That comment claimed a plain `zip`
# loses the extended attribute the signature lives in — which is true of a
# lone signed binary and not of a bundle, where the signature is in
# `Contents/_CodeSignature` and inside the Mach-O, both ordinary file content.
# Checked: a plain zip round-trips and still verifies. The rationale was
# plausible and wrong, which is why the check below exists instead of trust.
#
# Notarize before archiving, not after: stapling writes a ticket into the
# bundle, and an archive made first would ship without it.
DIST_VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
# Named per variant, for the reason the input stamp is: the two archives are
# different files that were about to share one name, and whichever was built
# last would have been the one shipped. Not a finding from the audit — it
# followed from fixing the stamp, which is the same mistake one layer down.
ZIP          := dist/TYPE-$(DIST_VERSION)-$(VARIANT).zip

# Notarize, then archive, in that order and in one target. The ordering was
# a comment before, which `make -j notarize zip` was free to ignore — and
# an archive made mid-stapling ships without the ticket, which only shows
# up on someone else's Mac.
release:
	@$(MAKE) --no-print-directory notarize
	@$(MAKE) --no-print-directory zip

zip: $(APP)
	@mkdir -p dist
	@rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	# Round-trips, or it is not a distributable archive. The property that
	# matters is "the app inside this file still verifies", and asserting it
	# costs a second — cheaper than any argument about which archiver keeps
	# what, and it stays true if the archiver ever changes.
	@work=$$(mktemp -d); trap 'rm -rf "$$work"' EXIT; 		ditto -x -k "$(ZIP)" "$$work"; 		codesign --verify --strict "$$work/$(notdir $(APP))" 			|| { echo "error: the archived app does not verify"; exit 1; }
	@printf '\n%s\n' "$(ZIP)"
	@printf '  version : %s (build %s)\n' "$(DIST_VERSION)" "$(BUILD_NUMBER)"
	@printf '  size    : %s\n' "$$(du -h '$(ZIP)' | cut -f1)"
	@printf '  sha256  : %s\n' "$$(shasum -a 256 '$(ZIP)' | cut -d' ' -f1)"

# The sandboxed build, without having to remember the variable.
appstore:
	@$(MAKE) --no-print-directory VARIANT=appstore

version:
	@printf 'marketing : %s   (Info.plist, edited by hand)\n' \
		"$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
	@printf 'build     : %s   (git rev-list --count HEAD)\n' "$(BUILD_NUMBER)"
	@printf 'tree      : %s\n' \
		"$$(test -z "$$(git status --porcelain 2>/dev/null)" && echo clean || echo 'DIRTY — a build from this is not reproducible')"

# Re-check the password-manager list against Homebrew and the App Store.
#
# Not part of `make test`: it needs the network, and a gate that goes red
# because a CDN was slow is a gate people learn to ignore. Run it on its own —
# before a release, or whenever a manager is added — and it exits non-zero when
# the list has drifted, so it still works as a gate where one is wanted.
password-managers:
	@set -e; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	swiftc -O Tools/password-managers.swift -o "$$work/check"; \
	"$$work/check"

notarize: $(APP)
	@security find-identity -v -p codesigning | grep -q "$(SIGN_ID)" \
		|| { echo "FAIL: signing identity not in the keychain: $(SIGN_ID)"; exit 1; }
	codesign --force --options runtime --timestamp $(if $(ENTITLEMENTS),--entitlements $(ENTITLEMENTS),) --sign "$(SIGN_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	# The entitlement has to survive the re-sign, and its absence is invisible:
	# the app runs here either way and the difference only shows up as a
	# rejected submission, or an accepted one that is not sandboxed.
	@if [ -n "$(ENTITLEMENTS)" ]; then \
		codesign -d --entitlements - $(APP) 2>/dev/null | grep -q 'app-sandbox' \
			|| { echo "FAIL: sandbox entitlement lost in re-signing"; exit 1; }; \
		echo "  sandbox entitlement survived re-signing"; \
	fi
	# `get-task-allow` lets a debugger attach, and the notary service refuses
	# any binary carrying it. Checked here so the refusal arrives in a second
	# rather than after an upload.
	@codesign -d --entitlements :- $(APP) 2>/dev/null | grep -q "get-task-allow" \
		&& { echo "FAIL: get-task-allow present — this cannot be notarised"; exit 1; } \
		|| echo "OK: hardened, no get-task-allow"
	@mkdir -p .build/notary
	rm -f .build/notary/$(BIN).zip
	# `ditto`, not `zip`: the notary service needs the bundle's symlinks and
	# extended attributes intact, and `zip` flattens both.
	ditto -c -k --keepParent $(APP) .build/notary/$(BIN).zip
	$(call retry,xcrun notarytool submit .build/notary/$(BIN).zip --keychain-profile $(NOTARY_PROFILE) --wait)
	$(call retry,xcrun stapler staple $(APP))
	xcrun stapler validate $(APP)
	# The assessment a first launch actually performs.
	spctl -a -vv $(APP)

clean:
	rm -rf $(APP) .build

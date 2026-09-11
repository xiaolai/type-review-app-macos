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
# `make appstore` produces the sandboxed app; `make pkg` signs it into a
# submittable package. Both certificates the store needs are in the keychain now
# — Apple Distribution for the app, 3rd Party Mac Developer Installer for the
# package — so this no longer stops at a Developer ID signature the store would
# refuse.
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
# How notarytool is told who we are. A keychain profile locally, where one
# exists and no secret has to be handed about; explicit credentials on a
# builder, where there is no keychain to have stored one in.
#
# Not the App Store Connect API key, which would be the tidier form: that key
# is refused for notarisation too while the team's agreement is unsigned, with
# the same 403 the store API gives. The Apple ID path is unaffected by it.
NOTARY_AUTH ?= --keychain-profile $(NOTARY_PROFILE)

# App Store distribution. A different trust chain from Developer ID entirely —
# that certificate signs software Apple has notarised but does not host, and
# the store will not accept it. Two more are needed: one for the application,
# one for the installer package.
#
# The organisation name differs between them (HANDO on the older Developer ID,
# PANDO on these two) while the team identifier is the same. Same team, renamed
# at some point; the identifier is what anything checks.
STORE_SIGN     ?= Apple Distribution: PANDO K.K. (Y53RSUA3SM)
INSTALLER_SIGN ?= 3rd Party Mac Developer Installer: PANDO K.K. (Y53RSUA3SM)
TEAM_ID        ?= Y53RSUA3SM
# Downloaded from the developer portal. Not in the repository: it is tied to
# one team and expires, so a checked-in copy would be a stale secret-shaped
# file that stops working silently.
STORE_PROFILE  ?= dist/TYPE_Mac_App_Store.provisionprofile
# The store's identifier, spelled out rather than taken from $(BUNDLE_ID):
# `make pkg` builds the appstore variant through a sub-make, so the outer
# invocation still has the direct build's value.
BUNDLE_ID_STORE ?= review.type.app
# Upload credentials. Two ways, and neither puts a secret on a command line.
#
#   API key   ASC_KEY_ID + ASC_ISSUER_ID, with the .p8 in
#             ~/.appstoreconnect/private_keys/. Nothing to type, nothing to
#             expire in a year, and revocable on its own.
#   Apple ID  ASC_APPLE_ID + a password stored under ASC_KEYCHAIN_ITEM by
#             `altool --store-password-in-keychain-item --item <name>`. Passed
#             back as `@keychain --item <name>`, so the password itself never
#             appears on a command line.
#
#             Both forms take the item name as `--item`, and altool's own help
#             documents both as positional -- `--store-password-in-keychain-item
#             <name>` and `-p @keychain:<name>`. Neither works: storing fails
#             with "Expected item argument is missing, --item", and reading
#             fails with "Failed to find item <name>", which reads like a
#             missing keychain entry rather than a syntax error. Measured
#             against altool from Xcode 26.
ASC_KEY_ID       ?=
ASC_ISSUER_ID    ?=
ASC_APPLE_ID     ?=
ASC_KEYCHAIN_ITEM ?= TYPE_ASC
# The name of an environment variable holding the app-specific password.
#
# Preferred over the keychain item, and not by taste. Measured against altool
# from Xcode 26: with the *same* password, `-p @env:VAR` authenticates and
# uploads, while `-p @keychain --item TYPE_ASC` finds the item and then fails
# with "Sign in with the app-specific password you generated". Whatever altool
# reads back out of the keychain is not what it was given.
#
# It is also the form CI needs, where there is no keychain to have stored
# anything in. Keep the variable out of the shell's history -- a .env file that
# .gitignore covers, sourced with `set -a`, is what this repository does.
ASC_PASSWORD_ENV ?=
STORE_PKG       ?= dist/TYPE-$(DIST_VERSION).pkg

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

.PHONY: all run selftest speechbench quit-running test remote icon clean notarize password-managers version appstore zip release pkg verify-pkg validate upload

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
	# Absolute paths, all three of them. actool resolves a relative path
	# against a working directory it caches from an earlier invocation rather
	# than against the current one, so building a second checkout of this
	# project on a machine that has already built the first fails with "the
	# output directory does not exist" naming the *other* checkout. Verified:
	# from /tmp/fresh with the directory present, the relative form reported
	# the original repository's path and the absolute form worked.
	@xcrun actool --compile $(CURDIR)/$(CONTENTS)/Resources --app-icon AppIcon \
		--output-partial-info-plist $(CURDIR)/$(dir $(STAGE))icon-partial.plist \
		--platform macosx --minimum-deployment-target 14.0 --target-device mac \
		--errors --warnings $(CURDIR)/$(ICON_DOC) >/dev/null
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
	# `SIGN_ID=-` asks for ad hoc deliberately, which is not the same thing as
	# the identity being missing. The remote check runner is the case that needs
	# it: signing with a keychain identity requires the keychain unlocked, and an
	# ssh session cannot unlock it. `find-identity` still lists the certificate
	# there, so the test below passes and codesign then fails with
	# errSecInternalComponent, which names nothing. Asking for ad hoc outright is
	# honest about it, and costs nothing a check can feel: the identity buys TCC
	# stability for Input Monitoring, and no check ever requests that permission.
	@if [ "$(SIGN_ID)" = "-" ]; then \
		codesign --force --sign - --timestamp=none \
			$(if $(ENTITLEMENTS),--entitlements $(ENTITLEMENTS),) "$(STAGE)" >/dev/null; \
	elif security find-identity -v -p codesigning | grep -q "$(SIGN_ID)"; then \
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
# Quits a running TYPE before a check, because a check refuses to start beside
# one — they share the profile on disk, and two copies writing it is how a check
# corrupts what it came to verify.
#
# Its own target rather than a line in each recipe: three checks, and the one
# that forgot would be the one that surprises somebody.
quit-running:
	@# `pkill -x`, matching the executable name exactly, rather than `-f` over
	@# the whole command line: `-f '$(BIN)$$'` missed any copy started with an
	@# argument and would have matched an unrelated process whose command line
	@# happened to end the same way.
	@#
	@# Then polled rather than slept past. A fixed sleep cannot tell "gone" from
	@# "still going", and the check that follows refuses to start beside a live
	@# copy -- so a termination that had not finished would fail the build with
	@# a message about something else.
	@# The final check is outside the branch on purpose. Nested inside it, a
	@# `pkill` that failed while the process was still alive skipped
	@# verification entirely and this target exited 0 -- so the check that
	@# follows would refuse to start and blame something else.
	@if pgrep -x $(BIN) >/dev/null 2>&1; then \
		echo "quitting the running TYPE"; \
		pkill -x $(BIN) >/dev/null 2>&1 || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do \
			pgrep -x $(BIN) >/dev/null 2>&1 || break; \
			sleep 0.2; \
		done; \
	fi
	@if pgrep -x $(BIN) >/dev/null 2>&1; then \
		echo "error: TYPE is still running -- quit it by hand"; exit 1; \
	fi

selftest: $(APP) quit-running
	@./$(APP)/Contents/MacOS/$(BIN) --selftest

# Times the keystroke path with word speech off and then on.
#
# Speaking a word is meant to cost the typist nothing: the synthesizer, the
# voice and the provenance decision are all settled when the passage arrives,
# and the keystroke itself only enqueues. That is a promise which holds the day
# it is written and stops holding when somebody moves a line, so it is measured.
# The check counts the words it spoke as well as the microseconds, because
# "speech is free" and "speech never happened" produce the same timings.
speechbench: $(APP) quit-running
	@./$(APP)/Contents/MacOS/$(BIN) --speechbench

test:
	swift test

# The same checks, on a Mac nobody is typing on.
#
# They are already polite about the screen — `Diagnostics.isRunningCheck` is
# what keeps a check from activating a window — so this is not the sibling
# project's problem, where XCUITest cannot be made polite at all. What is left
# still lands on this desk: `selftest` and `speechbench` both quit a running
# TYPE, which here is the menu-bar app somebody is using, and `speechbench`
# speaks aloud and reports microseconds that a busy machine changes.
#
# `make remote REMOTE_HOST=<host>` names one explicitly; otherwise the script
# reads TYPE_E2E_HOST from .env. No machine name is committed. The reasoning,
# the preconditions and the signing override live in the script.
remote:
	@Tools/run-remote.sh $(REMOTE_HOST)

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

# The App Store package, ready to upload.
#
# Every step here can fail while looking like it worked, so every step is
# followed by a check of what actually landed. That is not caution for its own
# sake: a package that uploads and is rejected costs a round trip through
# App Store Connect, and the failures that cause it -- a lost entitlement, a
# missing profile, an app signed with the wrong certificate -- are all
# invisible in the artefact unless something reads it back.
pkg:
	@$(MAKE) --no-print-directory appstore
	@test -f "$(STORE_PROFILE)" || { \
		echo "error: no provisioning profile at $(STORE_PROFILE)"; \
		echo "       download a Mac App Store profile for $(BUNDLE_ID_STORE) and put it there"; \
		exit 1; }
	# That the file exists is not that it is a profile. A text file in its
	# place passed the existence check, was copied in, and came out the far
	# end as a signed package -- one that App Store Connect would reject
	# after the upload, which is the most expensive place to find out. A
	# profile is CMS-signed, so decoding it is both the format check and the
	# integrity check.
	@security cms -D -i "$(STORE_PROFILE)" >/dev/null 2>&1 \
		|| { echo "error: $(STORE_PROFILE) is not a signed provisioning profile"; exit 1; }
	@set -e; \
	plist=$$(mktemp); \
	trap 'rm -f "$$plist"' EXIT; \
	security cms -D -i "$(STORE_PROFILE)" > "$$plist" 2>/dev/null; \
	got=$$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$$plist" 2>/dev/null); \
	test "$$got" = "$(TEAM_ID).$(BUNDLE_ID_STORE)" \
		|| { echo "error: the profile is for '$$got', not $(TEAM_ID).$(BUNDLE_ID_STORE)"; exit 1; }; \
	expiry=$$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$$plist" 2>/dev/null); \
	test -n "$$expiry" || { echo "error: the profile has no expiry date"; exit 1; }; \
	python3 -c "import sys,datetime as d;e=d.datetime.strptime(sys.argv[1],'%a %b %d %H:%M:%S %Z %Y');sys.exit(0 if e>d.datetime.now() else 1)" "$$expiry" \
		|| { echo "error: the profile expired on $$expiry"; exit 1; }; \
	echo "  profile: $(TEAM_ID).$(BUNDLE_ID_STORE), valid until $$expiry"
	@security find-identity -v | grep -q "$(STORE_SIGN)" \
		|| { echo "error: signing identity not in the keychain: $(STORE_SIGN)"; exit 1; }
	@security find-identity -v | grep -q "$(INSTALLER_SIGN)" \
		|| { echo "error: signing identity not in the keychain: $(INSTALLER_SIGN)"; exit 1; }
	@set -e; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	rm -rf "$$work/TYPE.app"; \
	cp -R .build/appstore/TYPE.app "$$work/TYPE.app"; \
	cp "$(STORE_PROFILE)" "$$work/TYPE.app/Contents/embedded.provisionprofile"; \
	: 'Extended attributes stripped, and the provisioning profile is why:'; \
	: 'it arrives through a browser, so it carries com.apple.quarantine, and'; \
	: 'App Store Connect refuses a macOS package containing that attribute on'; \
	: 'any file (91109). Before signing rather than after, so the signature is'; \
	: 'computed over exactly what ships.'; \
	xattr -cr "$$work/TYPE.app"; \
	test -s "$$work/TYPE.app/Contents/embedded.provisionprofile" \
		|| { echo "error: the profile did not copy"; exit 1; }; \
	cp sandbox.entitlements "$$work/store.entitlements"; \
	/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $(TEAM_ID).$(BUNDLE_ID_STORE)" \
		"$$work/store.entitlements" >/dev/null; \
	/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $(TEAM_ID)" \
		"$$work/store.entitlements" >/dev/null; \
	codesign --force --options runtime --timestamp \
		--entitlements "$$work/store.entitlements" \
		--sign "$(STORE_SIGN)" "$$work/TYPE.app"; \
	codesign -dvvv "$$work/TYPE.app" 2>&1 | grep -q "Authority=$(STORE_SIGN)" \
		|| { echo "error: the app is not signed with $(STORE_SIGN)"; exit 1; }; \
	codesign -d --entitlements :- "$$work/TYPE.app" 2>/dev/null \
		| grep -q "com.apple.security.app-sandbox" \
		|| { echo "error: the sandbox entitlement did not survive re-signing"; exit 1; }; \
	codesign -d --entitlements :- "$$work/TYPE.app" 2>/dev/null \
		| grep -q "$(TEAM_ID).$(BUNDLE_ID_STORE)" \
		|| { echo "error: the application-identifier entitlement is absent"; exit 1; }; \
	codesign -d --entitlements :- "$$work/TYPE.app" 2>/dev/null \
		| grep -q "get-task-allow" \
		&& { echo "error: get-task-allow present — the store will refuse this"; exit 1; } \
		|| true; \
	mkdir -p dist; \
	rm -f "$(STORE_PKG)"; \
	productbuild --component "$$work/TYPE.app" /Applications \
		--sign "$(INSTALLER_SIGN)" "$(STORE_PKG)"; \
	pkgutil --check-signature "$(STORE_PKG)" | grep -q "Status: signed" \
		|| { echo "error: the package is not signed"; exit 1; }; \
	printf '\n%s\n' "$(STORE_PKG)"; \
	printf '  version : %s (build %s)\n' "$(DIST_VERSION)" "$(BUILD_NUMBER)"; \
	printf '  size    : %s\n' "$$(du -h '$(STORE_PKG)' | cut -f1)"; \
	printf '  sha256  : %s\n' "$$(shasum -a 256 '$(STORE_PKG)' | cut -d' ' -f1)"

# Sends the package to App Store Connect.
#
# It re-reads the artefact first rather than trusting that `make pkg` left a
# good one. `pkg` and `upload` are separate commands, so an hour and a rebuild
# can sit between them, and the thing being sent is a file on disk rather than
# something this invocation produced.
# Asks Apple whether it would accept the package, without submitting it.
#
# Worth its own step because the local checks in `upload` and the ones Apple
# runs are different questions. Everything here passed locally and Apple still
# refused the first attempt -- for an account-level reason no amount of reading
# the artefact could have found. A validation costs nothing and does not
# consume a submission.
validate: verify-pkg
	@test -f "$(STORE_PKG)" \
		|| { echo "error: no package at $(STORE_PKG) — run 'make pkg' first"; exit 1; }
	@if [ -n "$(ASC_KEY_ID)" ] && [ -n "$(ASC_ISSUER_ID)" ]; then \
		xcrun altool --validate-app -f "$(STORE_PKG)" -t macos \
			--apiKey "$(ASC_KEY_ID)" --apiIssuer "$(ASC_ISSUER_ID)"; \
	elif [ -n "$(ASC_APPLE_ID)" ] && [ -n "$(ASC_PASSWORD_ENV)" ]; then \
		xcrun altool --validate-app -f "$(STORE_PKG)" -t macos \
			-u "$(ASC_APPLE_ID)" -p "@env:$(ASC_PASSWORD_ENV)"; \
	elif [ -n "$(ASC_APPLE_ID)" ]; then \
		xcrun altool --validate-app -f "$(STORE_PKG)" -t macos \
			-u "$(ASC_APPLE_ID)" -p @keychain --item "$(ASC_KEYCHAIN_ITEM)"; \
	else \
		echo "error: no credentials — see 'make upload' for the two forms"; exit 1; \
	fi

# The checks that need nothing but the file on disk. Free and instant, so
# they run before anything is asked of Apple.
verify-pkg:
	@test -f "$(STORE_PKG)" \
		|| { echo "error: no package at $(STORE_PKG) — run 'make pkg' first"; exit 1; }
	# The same three questions the store will ask, asked here where the
	# answer is cheap. An upload that fails validation costs a round trip
	# and tells you less than this does.
	@set -e; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	pkgutil --expand-full "$(STORE_PKG)" "$$work/x" >/dev/null; \
	app=$$(find "$$work/x" -maxdepth 4 -name 'TYPE.app' -type d | head -1); \
	test -n "$$app" || { echo "error: no app inside the package"; exit 1; }; \
	codesign -dvvv "$$app" 2>&1 | grep -q "Authority=$(STORE_SIGN)" \
		|| { echo "error: the packaged app is not signed with $(STORE_SIGN)"; exit 1; }; \
	test -s "$$app/Contents/embedded.provisionprofile" \
		|| { echo "error: the packaged app has no provisioning profile"; exit 1; }; \
	bad=$$(find "$$app" -type f -exec sh -c \
		'xattr "$$1" 2>/dev/null | grep -q com.apple.quarantine && echo "$$1"' _ {} \; \
		| head -3); \
	test -z "$$bad" \
		|| { echo "error: com.apple.quarantine on files inside the package:"; \
		     echo "$$bad" | sed 's|.*/TYPE.app|  TYPE.app|'; \
		     echo "       App Store Connect refuses these with error 91109, and it does"; \
		     echo "       so during processing -- the upload reports success and the"; \
		     echo "       build simply never appears. Rebuild with 'make pkg'."; \
		     exit 1; }; \
	codesign -d --entitlements :- "$$app" 2>/dev/null | grep -q "app-sandbox" \
		|| { echo "error: the packaged app is not sandboxed"; exit 1; }; \
	built=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$$app/Contents/Info.plist"); \
	test "$$built" = "$(BUILD_NUMBER)" \
		|| { echo "error: the package is build $$built, the tree is at $(BUILD_NUMBER)"; \
		     echo "       built $$(( $(BUILD_NUMBER) - $$built )) commit(s) ago — run 'make pkg' again"; \
		     exit 1; }; \
	shortv=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$$app/Contents/Info.plist"); \
	test "$$shortv" = "$(DIST_VERSION)" \
		|| { echo "error: the package says $$shortv, Info.plist says $(DIST_VERSION)"; exit 1; }; \
	test -z "$$(git status --porcelain)" \
		|| { echo "error: the working tree is dirty — the package is not what is committed"; exit 1; }; \
	echo "  package verified: $$shortv ($$built), matches the tree"

upload: verify-pkg validate
	@if [ -n "$(ASC_KEY_ID)" ] && [ -n "$(ASC_ISSUER_ID)" ]; then \
		echo "  uploading with the App Store Connect API key $(ASC_KEY_ID)"; \
		xcrun altool --upload-app -f "$(STORE_PKG)" -t macos \
			--apiKey "$(ASC_KEY_ID)" --apiIssuer "$(ASC_ISSUER_ID)"; \
	elif [ -n "$(ASC_APPLE_ID)" ] && [ -n "$(ASC_PASSWORD_ENV)" ]; then \
		echo "  uploading as $(ASC_APPLE_ID), password from the environment"; \
		xcrun altool --upload-app -f "$(STORE_PKG)" -t macos \
			-u "$(ASC_APPLE_ID)" -p "@env:$(ASC_PASSWORD_ENV)"; \
	elif [ -n "$(ASC_APPLE_ID)" ]; then \
		echo "  uploading as $(ASC_APPLE_ID), password from the keychain"; \
		xcrun altool --upload-app -f "$(STORE_PKG)" -t macos \
			-u "$(ASC_APPLE_ID)" -p @keychain --item "$(ASC_KEYCHAIN_ITEM)"; \
	else \
		echo "error: no upload credentials configured. Either:"; \
		echo "  make upload ASC_KEY_ID=... ASC_ISSUER_ID=...   (App Store Connect API key)"; \
		echo "  make upload ASC_APPLE_ID=you@example.com ASC_PASSWORD_ENV=VAR   (password in \$$VAR)"; \
		echo "  make upload ASC_APPLE_ID=you@example.com       (password in keychain item $(ASC_KEYCHAIN_ITEM))"; \
		exit 1; \
	fi

# Whether App Store Connect will take an upload right now, and if not, which
# of the three gates is shut. `altool` reports all three as "No applications
# found", which is how an unsigned agreement first read as a missing app
# record.
asc-status:
	@test -n "$(ASC_KEY_ID)" && test -n "$(ASC_ISSUER_ID)" \
		|| { echo "usage: make asc-status ASC_KEY_ID=... ASC_ISSUER_ID=..."; exit 1; }
	@python3 Tools/asc-status.py "$(ASC_KEY_ID)" "$(ASC_ISSUER_ID)" "$(BUNDLE_ID_STORE)"

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
	$(call retry,xcrun notarytool submit .build/notary/$(BIN).zip $(NOTARY_AUTH) --wait)
	$(call retry,xcrun stapler staple $(APP))
	xcrun stapler validate $(APP)
	# The assessment a first launch actually performs.
	spctl -a -vv $(APP)

clean:
	rm -rf $(APP) .build

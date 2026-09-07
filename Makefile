# Assembles the .app bundle around the SPM executable. A window needs an
# Info.plist and a bundle identifier; `swift run` alone gives neither.

# Named for the app, not for the repo. macOS labels the Dock item from the
# bundle, and a bundle called TypeReview.app under an app called TYPE gets a
# Dock tooltip that disagrees with its own menu bar.
APP      := TYPE.app
BIN      := TypeReviewApp
CONFIG   := release
# Assembled here and published only when every check has passed. Writing
# straight into $(APP) meant a failure half way through left a bundle that was
# incomplete *and* newer than its sources — so the next `make`, `run` or
# `selftest` considered it up to date and ran it.
STAGE    := .build/stage/$(APP)
CONTENTS := $(STAGE)/Contents

SOURCES := $(shell find Sources -name '*.swift')
CORPUS  := $(shell find Sources/TypeReviewKit/Resources -type f)

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
INPUT_STAMP := .build/inputs-stamp
INPUT_SIG   := $(CONFIG)|$(sort $(SOURCES))
_ := $(shell mkdir -p .build; \
        [ "$$(cat $(INPUT_STAMP) 2>/dev/null)" = "$(INPUT_SIG)" ] || rm -rf $(APP) $(INPUT_STAMP))

.PHONY: all run selftest test icon clean

all: $(APP)

$(APP): $(SOURCES) $(CORPUS) Package.swift Makefile Info.plist \
        Resources/TypeReview.icns Resources/typewriter.m4a
	swift build -c $(CONFIG) --product $(BIN)
	@rm -rf "$(STAGE)"
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp .build/$(CONFIG)/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	@cp Info.plist $(CONTENTS)/Info.plist
	@cp Resources/TypeReview.icns $(CONTENTS)/Resources/TypeReview.icns
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
	@codesign --force --sign - --timestamp=none "$(STAGE)" >/dev/null
	# Published only now, and by rename, so $(APP) is either the previous
	# good bundle or this one — never a half-built mixture of the two.
	@rm -rf $(APP)
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
	@set -e; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	swiftc -O Tools/make-icon.swift -o "$$work/make-icon"; \
	"$$work/make-icon" "$$work/TypeReview.iconset"; \
	iconutil -c icns "$$work/TypeReview.iconset" -o Resources/TypeReview.icns; \
	echo "wrote Resources/TypeReview.icns ($$(du -h Resources/TypeReview.icns | cut -f1))"

clean:
	rm -rf $(APP) .build

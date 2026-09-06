# Assembles the .app bundle around the SPM executable. A window needs an
# Info.plist and a bundle identifier; `swift run` alone gives neither.

# Named for the app, not for the repo. macOS labels the Dock item from the
# bundle, and a bundle called TypeReview.app under an app called TYPE gets a
# Dock tooltip that disagrees with its own menu bar.
APP      := TYPE.app
BIN      := TypeReviewApp
CONTENTS := $(APP)/Contents
CONFIG   := release

.PHONY: all run selftest test icon clean

all: $(APP)

$(APP): $(shell find Sources -name '*.swift') Info.plist Resources/TypeReview.icns Resources/typewriter.m4a
	swift build -c $(CONFIG) --product $(BIN)
	@rm -rf $(APP)
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
	cp -R .build/$(CONFIG)/*.bundle $(CONTENTS)/Resources/
	# And prove it landed, rather than trusting that cp said nothing. The
	# assertion is the part that stops this regressing quietly a second time.
	@test -d "$(CONTENTS)/Resources/TypeReview_TypeReviewKit.bundle/Resources/code" \
		|| { echo "error: corpus bundle missing from $(APP)" >&2; exit 1; }
	@test -s "$(CONTENTS)/Resources/typewriter.m4a" \
		|| { echo "error: typewriter sample missing from $(APP)" >&2; exit 1; }
	@codesign --force --sign - --timestamp=none $(APP) >/dev/null 2>&1
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
icon:
	@swiftc -O Tools/make-icon.swift -o /tmp/type-make-icon
	@/tmp/type-make-icon /tmp/TypeReview.iconset
	@iconutil -c icns /tmp/TypeReview.iconset -o Resources/TypeReview.icns
	@echo "wrote Resources/TypeReview.icns ($$(du -h Resources/TypeReview.icns | cut -f1))"

clean:
	rm -rf $(APP) .build

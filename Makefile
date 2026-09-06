# Assembles the .app bundle around the SPM executable. A window needs an
# Info.plist and a bundle identifier; `swift run` alone gives neither.

APP      := TypeReview.app
BIN      := TypeReviewApp
CONTENTS := $(APP)/Contents
CONFIG   := release

.PHONY: all run selftest test icon clean

all: $(APP)

$(APP): $(shell find Sources -name '*.swift') Info.plist Resources/TypeReview.icns
	swift build -c $(CONFIG) --product $(BIN)
	@rm -rf $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp .build/$(CONFIG)/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	@cp Info.plist $(CONTENTS)/Info.plist
	@cp Resources/TypeReview.icns $(CONTENTS)/Resources/TypeReview.icns
	# SwiftPM puts a target's resources in its own .bundle beside the binary.
	# Without this the corpus is simply absent at runtime and the app falls
	# back to generated words — silently, because a missing corpus and an
	# empty one look identical to the picker.
	@cp -R .build/$(CONFIG)/*.bundle $(CONTENTS)/Resources/ 2>/dev/null || true
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

# Assembles the .app bundle around the SPM executable. A window needs an
# Info.plist and a bundle identifier; `swift run` alone gives neither.

APP      := TypeReview.app
BIN      := TypeReviewApp
CONTENTS := $(APP)/Contents
CONFIG   := release

.PHONY: all run selftest test clean

all: $(APP)

$(APP): $(shell find Sources -name '*.swift') Info.plist
	swift build -c $(CONFIG) --product $(BIN)
	@rm -rf $(APP)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	@cp .build/$(CONFIG)/$(BIN) $(CONTENTS)/MacOS/$(BIN)
	@cp Info.plist $(CONTENTS)/Info.plist
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

clean:
	rm -rf $(APP) .build

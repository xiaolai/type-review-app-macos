import XCTest

@testable import TypeReviewKit

/// The rules a customizable global shortcut has to hold to.
final class KeyboardShortcutTests: XCTestCase {
    func testAQualifyingModifierIsRequired() {
        // A bare key, or shift plus a key, would be taken from every other app
        // for as long as TYPE runs — nobody could type a capital S anywhere.
        XCTAssertFalse(KeyboardShortcut(keyCode: 1, modifiers: []).isValid)
        XCTAssertFalse(KeyboardShortcut(keyCode: 1, modifiers: [.shift]).isValid)
        // Any one of control, option or command is enough.
        for modifier in [ShortcutModifiers.control, .option, .command] {
            XCTAssertTrue(KeyboardShortcut(keyCode: 1, modifiers: modifier).isValid)
            XCTAssertTrue(
                KeyboardShortcut(keyCode: 1, modifiers: [modifier, .shift]).isValid,
                "shift alongside a qualifying modifier is fine")
        }
    }

    func testModifiersPrintInTheOrderMacOSPrintsThem() {
        // ⌃⌥⇧⌘ always, regardless of how the set was built — this is the one
        // thing users notice instantly if it is wrong.
        XCTAssertEqual(ShortcutModifiers([.command, .control]).glyphs, "⌃⌘")
        XCTAssertEqual(ShortcutModifiers([.shift, .option]).glyphs, "⌥⇧")
        XCTAssertEqual(
            ShortcutModifiers([.command, .shift, .option, .control]).glyphs, "⌃⌥⇧⌘")
        XCTAssertEqual(ShortcutModifiers().glyphs, "")
    }

    func testDisplayPutsTheKeyAfterItsModifiers() {
        XCTAssertEqual(KeyboardShortcut.defaultSoundToggle.display(keyName: "S"), "⌃⌥⌘S")
    }

    func testTheDefaultIsSafeToClaimGlobally() {
        XCTAssertTrue(KeyboardShortcut.defaultSoundToggle.isValid)
    }
}

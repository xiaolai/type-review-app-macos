import AppKit
import Carbon.HIToolbox

/// What the system says about the keyboard actually attached.
///
/// The web version cannot ask this. A browser has no way to know which layout
/// is active, so it sniffs `navigator.userAgent` for "Mac", picks one of two
/// hand-drawn pictures, and hard-codes QWERTY, Colemak and Dvorak character
/// tables by hand — 485 lines of them, with no ISO row and no JIS row at all.
/// European and Japanese typists get shown a keyboard they do not own.
///
/// Here the OS answers directly: `TISCopyCurrentKeyboardLayoutInputSource` for
/// the active layout, `UCKeyTranslate` for what each physical key produces, and
/// `KBGetLayoutType` for the real ANSI / ISO / JIS shape. Colemak and Dvorak
/// need no special-casing — they are layouts, and the layout is what we asked
/// for.
enum SystemKeyboard {
    enum Shape: Hashable {
        case ansi, iso, jis
        /// Shape sets, for the geometry table. They live here rather than in
        /// `KeyboardGeometry` because that file used to declare a second,
        /// identical `Shape` and convert between the two case by case.
        static let all: Set<Shape> = [.ansi, .iso, .jis]
        static let isoOnly: Set<Shape> = [.iso]
        static let jisOnly: Set<Shape> = [.jis]
        static let notISO: Set<Shape> = [.ansi, .jis]
        static let ansiOnly: Set<Shape> = [.ansi]
        /// The two shapes whose return key is tall and L-shaped.
        static let tallReturn: Set<Shape> = [.iso, .jis]
    }

    /// The physical shape of the attached keyboard.
    static var shape: Shape {
        switch KBGetLayoutType(Int16(LMGetKbdType())) {
        case PhysicalKeyboardLayoutType(kKeyboardISO): return .iso
        case PhysicalKeyboardLayoutType(kKeyboardJIS): return .jis
        default: return .ansi
        }
    }

    /// The keyboard layout the legends should be drawn from.
    ///
    /// The **ASCII-capable** layout, not simply the current one. With a
    /// Chinese, Japanese or Korean input method active, the current layout is
    /// the input method's own — and `UCKeyTranslate` against it answers with
    /// what that method *produces*, not what is printed on the key: `……` above
    /// 6, `¥` above 4, `《` and `》` on the comma and full stop, `【】` on the
    /// brackets. Those are true answers to the wrong question. An input method
    /// is a layer on top of a keyboard; the keyboard underneath is still the
    /// one with `^` above 6, and that is what the keycap says.
    ///
    /// Dvorak and Colemak are unaffected — both are ASCII-capable layouts, so
    /// this returns them unchanged and their legends stay correct.
    private static var legendSource: TISInputSource? {
        TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    /// The name of the layout the legends come from, e.g. `Dvorak`.
    static var layoutName: String {
        guard let source = legendSource,
            let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName)
        else { return "Unknown" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// Whether the layout being drawn from is ASCII-capable — the property
    /// that separates a keyboard from an input method sitting on one.
    static var legendSourceIsASCIICapable: Bool {
        guard let source = legendSource,
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
        else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() as? Bool ?? false
    }

    /// The character a physical key produces under the current layout.
    ///
    /// This is the whole point: the caller names a *position* on the keyboard
    /// and the system says what it types. A Dvorak user pressing the key where
    /// QWERTY prints S gets "o", and nothing here needs to know that Dvorak
    /// exists.
    static func character(forKeyCode keyCode: UInt16, shift: Bool = false) -> String? {
        guard let source = legendSource,
            let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) : 0

        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count,
                &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        // A dead key produces no character of its own; showing the accent it
        // would combine with is more honest than showing nothing.
        return text.isEmpty ? nil : text
    }
}

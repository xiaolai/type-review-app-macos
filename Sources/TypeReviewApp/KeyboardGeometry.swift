import Carbon.HIToolbox
import Foundation

/// Physical key positions.
///
/// Positions only — no characters. What each key *types* comes from the system
/// at render time, which is why this table is a fraction of the web version's
/// and covers three keyboard shapes instead of two. Changing layout to Dvorak
/// relabels the keys with no code here knowing what Dvorak is.
///
/// Every row is exactly `unitsPerRow` wide. Real keyboards are rectangles, and
/// the odd sizes always land on the edge keys — so each row's last key absorbs
/// whatever slack is left, and the case comes out flush on all three shapes
/// without a hand-tuned width per key per shape.
enum KeyboardGeometry {
    /// The width of every row, in units where a letter key is 1. Apple's
    /// proportions: 15 units from `esc` to the right edge.
    static let unitsPerRow: Double = 15

    /// How a cap is drawn and whether it can be typed.
    enum Role {
        /// Types a character. Carries heat, and its label comes from the OS.
        case letter
        /// A modifier: dimmer, and captioned with its spelled-out name the way
        /// Apple prints them.
        case modifier
        case space
        /// Decorative. Never typed, never tinted — `esc`, the F-row, `fn`.
        case function
        /// The round button. Drawn, not labelled.
        case touchID
    }

    /// Where the glyph sits inside the cap. Apple's edge caps hug the outside
    /// of the keyboard: `tab`/`caps`/left `shift` print at the left edge,
    /// `delete`/`return`/right `shift` at the right.
    enum Align {
        case start, center, end
    }

    struct Key {
        let code: UInt16
        /// Width in units, or nil for the key that absorbs the row's slack.
        let width: Double?
        /// Shown instead of the character, for keys that produce none.
        let label: String?
        /// The word printed under the glyph, as Apple prints it. Dropped
        /// automatically when the cap is too narrow to hold it.
        let sub: String?
        let align: Align
        let role: Role
        /// Present only on some keyboard shapes.
        let shapes: Set<Shape>

        /// Whether this key produces a character the drill can ask for. Space
        /// does — it is a third of English by frequency, and leaving it off the
        /// heatmap hides the key most people are slowest on.
        var types: Bool { role == .letter || role == .space }

        init(
            _ code: Int, _ width: Double? = 1, label: String? = nil, sub: String? = nil,
            align: Align = .center, role: Role = .letter, shapes: Set<Shape> = Shape.all
        ) {
            self.code = UInt16(code)
            self.width = width
            self.label = label
            self.sub = sub
            self.align = align
            self.role = role
            self.shapes = shapes
        }
    }

    enum Shape: Hashable {
        case ansi, iso, jis
        static let all: Set<Shape> = [.ansi, .iso, .jis]
        static let isoOnly: Set<Shape> = [.iso]
        static let jisOnly: Set<Shape> = [.jis]
        static let notISO: Set<Shape> = [.ansi, .jis]
    }

    /// A key with its width resolved — the slack-absorber has a number by the
    /// time a caller sees it.
    struct PlacedKey {
        let key: Key
        let width: Double
    }

    static func rows(for shape: SystemKeyboard.Shape) -> [[PlacedKey]] {
        let current: Shape = switch shape {
        case .ansi: .ansi
        case .iso: .iso
        case .jis: .jis
        }
        return allRows.map { row in
            let keys = row.filter { $0.shapes.contains(current) }
            let fixed = keys.reduce(0.0) { $0 + ($1.width ?? 0) }
            // Deliberately unclamped. The row total is `unitsPerRow` by
            // construction, so a floor here would turn "these keys do not fit"
            // into "this row is too wide" — silently, and only visible as a
            // ragged edge. Left negative, an over-full row shows up as an
            // impossible width, which the selftest checks for and the drawing
            // code skips.
            let slack = unitsPerRow - fixed
            return keys.map { PlacedKey(key: $0, width: $0.width ?? slack) }
        }
    }

    private static let allRows: [[Key]] = [
        // The function row is decorative — no drill ever asks for F7. It is
        // here because leaving it out makes the picture stop being a Mac
        // keyboard, which is the one thing this view has to be.
        [
            Key(kVK_Escape, 2, label: "esc", align: .start, role: .function),
            Key(kVK_F1, label: "F1", role: .function), Key(kVK_F2, label: "F2", role: .function),
            Key(kVK_F3, label: "F3", role: .function), Key(kVK_F4, label: "F4", role: .function),
            Key(kVK_F5, label: "F5", role: .function), Key(kVK_F6, label: "F6", role: .function),
            Key(kVK_F7, label: "F7", role: .function), Key(kVK_F8, label: "F8", role: .function),
            Key(kVK_F9, label: "F9", role: .function), Key(kVK_F10, label: "F10", role: .function),
            Key(kVK_F11, label: "F11", role: .function), Key(kVK_F12, label: "F12", role: .function),
            Key(0xFFFF, nil, role: .touchID),
        ],
        [
            Key(kVK_ANSI_Grave), Key(kVK_ANSI_1), Key(kVK_ANSI_2), Key(kVK_ANSI_3),
            Key(kVK_ANSI_4), Key(kVK_ANSI_5), Key(kVK_ANSI_6), Key(kVK_ANSI_7),
            Key(kVK_ANSI_8), Key(kVK_ANSI_9), Key(kVK_ANSI_0), Key(kVK_ANSI_Minus),
            Key(kVK_ANSI_Equal),
            // JIS keeps ¥ where ANSI ends the row.
            Key(kVK_JIS_Yen, label: "¥", shapes: Shape.jisOnly),
            Key(kVK_Delete, nil, label: "⌫", sub: "delete", align: .end, role: .modifier),
        ],
        [
            Key(kVK_Tab, 1.5, label: "⇥", sub: "tab", align: .start, role: .modifier),
            Key(kVK_ANSI_Q), Key(kVK_ANSI_W), Key(kVK_ANSI_E),
            Key(kVK_ANSI_R), Key(kVK_ANSI_T), Key(kVK_ANSI_Y), Key(kVK_ANSI_U),
            Key(kVK_ANSI_I), Key(kVK_ANSI_O), Key(kVK_ANSI_P), Key(kVK_ANSI_LeftBracket),
            Key(kVK_ANSI_RightBracket),
            Key(kVK_ANSI_Backslash, nil, shapes: Shape.notISO),
            // ISO's return is tall and L-shaped. Drawn as its two halves — a
            // deliberate simplification, and the seam is one gap wide.
            Key(kVK_Return, nil, label: "⏎", sub: "return", align: .end, role: .modifier, shapes: Shape.isoOnly),
        ],
        [
            Key(kVK_CapsLock, 1.75, label: "⇪", sub: "caps lock", align: .start, role: .modifier),
            Key(kVK_ANSI_A), Key(kVK_ANSI_S),
            Key(kVK_ANSI_D), Key(kVK_ANSI_F), Key(kVK_ANSI_G), Key(kVK_ANSI_H),
            Key(kVK_ANSI_J), Key(kVK_ANSI_K), Key(kVK_ANSI_L), Key(kVK_ANSI_Semicolon),
            Key(kVK_ANSI_Quote),
            Key(kVK_ANSI_Backslash, 1, shapes: Shape.isoOnly),
            Key(kVK_Return, nil, label: "⏎", sub: "return", align: .end, role: .modifier),
        ],
        [
            // ISO's left shift is short — the extra key sits beside it.
            Key(kVK_Shift, 2.25, label: "⇧", sub: "shift", align: .start, role: .modifier, shapes: Shape.notISO),
            Key(kVK_Shift, 1.25, label: "⇧", sub: "shift", align: .start, role: .modifier, shapes: Shape.isoOnly),
            // The extra key ISO keyboards have and ANSI ones do not — the one
            // the web version cannot draw at all.
            Key(kVK_ISO_Section, shapes: Shape.isoOnly),
            Key(kVK_ANSI_Z), Key(kVK_ANSI_X), Key(kVK_ANSI_C), Key(kVK_ANSI_V),
            Key(kVK_ANSI_B), Key(kVK_ANSI_N), Key(kVK_ANSI_M), Key(kVK_ANSI_Comma),
            Key(kVK_ANSI_Period), Key(kVK_ANSI_Slash),
            Key(kVK_JIS_Underscore, shapes: Shape.jisOnly),
            Key(kVK_RightShift, nil, label: "⇧", sub: "shift", align: .end, role: .modifier),
        ],
        [
            Key(kVK_Function, 1, label: "fn", align: .start, role: .function),
            Key(kVK_Control, 1, label: "⌃", sub: "control", align: .start, role: .modifier),
            Key(kVK_Option, 1, label: "⌥", sub: "option", align: .start, role: .modifier),
            Key(kVK_Command, 1.25, label: "⌘", sub: "command", align: .start, role: .modifier),
            Key(kVK_JIS_Eisu, 1, label: "英数", role: .modifier, shapes: Shape.jisOnly),
            Key(kVK_Space, 6, label: " ", role: .space, shapes: [.ansi, .iso]),
            // JIS pays for 英数 and かな out of the space bar, exactly as the
            // hardware does — it is the shortest space bar Apple ships.
            Key(kVK_Space, 4.5, label: " ", role: .space, shapes: Shape.jisOnly),
            Key(kVK_JIS_Kana, 1, label: "かな", role: .modifier, shapes: Shape.jisOnly),
            Key(kVK_RightCommand, 1.75, label: "⌘", sub: "command", align: .end, role: .modifier),
            Key(kVK_RightOption, 1.5, label: "⌥", sub: "option", align: .end, role: .modifier),
            Key(kVK_RightControl, nil, label: "⌃", sub: "control", align: .end, role: .modifier),
        ],
    ]
}

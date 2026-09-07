import Carbon.HIToolbox

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

    /// Where the legend sits vertically. The keys along the outer edges carry
    /// theirs in the bottom corner, as Apple prints them; everything else is
    /// centred in its cap.
    enum VerticalAlign {
        case center, bottom
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
        let vertical: VerticalAlign
        let role: Role
        /// Present only on some keyboard shapes.
        let shapes: Set<Shape>

        /// Whether this key produces a character the drill can ask for. Space
        /// does — it is a third of English by frequency, and leaving it off the
        /// heatmap hides the key most people are slowest on.
        var types: Bool { role == .letter || role == .space }

        init(
            _ code: Int, _ width: Double? = 1, label: String? = nil, sub: String? = nil,
            align: Align = .center, vertical: VerticalAlign = .center,
            role: Role = .letter, shapes: Set<Shape> = Shape.all
        ) {
            self.code = UInt16(code)
            self.width = width
            self.label = label
            self.sub = sub
            self.align = align
            self.vertical = vertical
            self.role = role
            self.shapes = shapes
        }
    }

    /// The shapes a key appears on. `SystemKeyboard.Shape`, not a second
    /// enum of the same three cases — that one existed only to be converted
    /// back, case by case, on every call.
    typealias Shape = SystemKeyboard.Shape

    /// A key with its width resolved — the slack-absorber has a number by the
    /// time a caller sees it.
    struct PlacedKey {
        let key: Key
        let width: Double
    }

    static func rows(for shape: SystemKeyboard.Shape) -> [[PlacedKey]] {
        allRows.map { row in
            let keys = row.filter { $0.shapes.contains(shape) }
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
            Key(kVK_Escape, 2, label: "esc", align: .start, vertical: .bottom, role: .function),
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
            // No label: the legend comes from `UCKeyTranslate` like every
            // other character key. Hardcoding "¥" made the cap disagree with
            // the character the heat map and the next-key highlight use, on
            // any layout that maps this key to something else.
            Key(kVK_JIS_Yen, shapes: Shape.jisOnly),
            Key(kVK_Delete, nil, label: "⌫", align: .end, vertical: .bottom, role: .modifier),
        ],
        [
            Key(kVK_Tab, 1.5, label: "⇥", align: .start, vertical: .bottom, role: .modifier),
            Key(kVK_ANSI_Q), Key(kVK_ANSI_W), Key(kVK_ANSI_E),
            Key(kVK_ANSI_R), Key(kVK_ANSI_T), Key(kVK_ANSI_Y), Key(kVK_ANSI_U),
            Key(kVK_ANSI_I), Key(kVK_ANSI_O), Key(kVK_ANSI_P), Key(kVK_ANSI_LeftBracket),
            Key(kVK_ANSI_RightBracket),
            // Only ANSI has a backslash up here. JIS puts that position on
            // the home row, under the lower half of its return key — this row
            // used to include it for JIS as well, which both misplaced the key
            // and left no room for the return to be tall.
            Key(kVK_ANSI_Backslash, nil, shapes: Shape.ansiOnly),
            // ISO's and JIS's return is tall and L-shaped. Drawn as its two
            // halves — a deliberate simplification, and the seam is one gap
            // wide. JIS shares that shape; it used to be given ANSI's
            // single-row return, which is the wrong key on the wrong row.
            Key(kVK_Return, nil, label: "⏎", align: .end, vertical: .bottom, role: .modifier, shapes: Shape.tallReturn),
        ],
        [
            Key(kVK_CapsLock, 1.75, label: "⇪", align: .start, vertical: .bottom, role: .modifier),
            Key(kVK_ANSI_A), Key(kVK_ANSI_S),
            Key(kVK_ANSI_D), Key(kVK_ANSI_F), Key(kVK_ANSI_G), Key(kVK_ANSI_H),
            Key(kVK_ANSI_J), Key(kVK_ANSI_K), Key(kVK_ANSI_L), Key(kVK_ANSI_Semicolon),
            Key(kVK_ANSI_Quote),
            Key(kVK_ANSI_Backslash, 1, shapes: Shape.tallReturn),
            Key(kVK_Return, nil, label: "⏎", align: .end, vertical: .bottom, role: .modifier),
        ],
        [
            // ISO's left shift is short — the extra key sits beside it.
            Key(kVK_Shift, 2.25, label: "⇧", align: .start, vertical: .bottom, role: .modifier, shapes: Shape.notISO),
            Key(kVK_Shift, 1.25, label: "⇧", align: .start, vertical: .bottom, role: .modifier, shapes: Shape.isoOnly),
            // The extra key ISO keyboards have and ANSI ones do not — the one
            // the web version cannot draw at all.
            Key(kVK_ISO_Section, shapes: Shape.isoOnly),
            Key(kVK_ANSI_Z), Key(kVK_ANSI_X), Key(kVK_ANSI_C), Key(kVK_ANSI_V),
            Key(kVK_ANSI_B), Key(kVK_ANSI_N), Key(kVK_ANSI_M), Key(kVK_ANSI_Comma),
            Key(kVK_ANSI_Period), Key(kVK_ANSI_Slash),
            Key(kVK_JIS_Underscore, shapes: Shape.jisOnly),
            Key(kVK_RightShift, nil, label: "⇧", align: .end, vertical: .bottom, role: .modifier),
        ],
        [
            Key(kVK_Function, 1, label: "fn", align: .start, vertical: .bottom, role: .function),
            Key(kVK_Control, 1, label: "⌃", sub: "control", align: .start, vertical: .bottom, role: .modifier),
            Key(kVK_Option, 1, label: "⌥", sub: "option", align: .start, vertical: .bottom, role: .modifier),
            Key(kVK_Command, 1.25, label: "⌘", sub: "command", align: .start, vertical: .bottom, role: .modifier),
            Key(kVK_JIS_Eisu, 1, label: "英数", role: .modifier, shapes: Shape.jisOnly),
            Key(kVK_Space, 6, label: " ", role: .space, shapes: [.ansi, .iso]),
            // JIS pays for 英数 and かな out of the space bar, exactly as the
            // hardware does — it is the shortest space bar Apple ships.
            Key(kVK_Space, 4.5, label: " ", role: .space, shapes: Shape.jisOnly),
            Key(kVK_JIS_Kana, 1, label: "かな", role: .modifier, shapes: Shape.jisOnly),
            Key(kVK_RightCommand, 1.75, label: "⌘", sub: "command", align: .end, vertical: .bottom, role: .modifier),
            Key(kVK_RightOption, 1.5, label: "⌥", sub: "option", align: .end, vertical: .bottom, role: .modifier),
            Key(kVK_RightControl, nil, label: "⌃", sub: "control", align: .end, vertical: .bottom, role: .modifier),
        ],
    ]
}

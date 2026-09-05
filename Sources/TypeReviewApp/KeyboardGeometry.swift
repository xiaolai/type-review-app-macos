import Carbon.HIToolbox
import Foundation

/// Physical key positions.
///
/// Positions only — no characters. What each key *types* comes from the system
/// at render time, which is why this table is a fifth the size of the web
/// version's and covers three keyboard shapes instead of two. Changing layout
/// to Dvorak relabels the keys with no code here knowing what Dvorak is.
enum KeyboardGeometry {
    struct Key {
        let code: UInt16
        /// Width in units, where a letter key is 1.
        let width: Double
        /// Shown instead of the character, for keys that produce none.
        let label: String?
        /// Present only on some keyboard shapes.
        let shapes: Set<Shape>

        init(_ code: Int, _ width: Double = 1, label: String? = nil, shapes: Set<Shape> = Shape.all)
        {
            self.code = UInt16(code)
            self.width = width
            self.label = label
            self.shapes = shapes
        }
    }

    enum Shape: Hashable {
        case ansi, iso, jis
        static let all: Set<Shape> = [.ansi, .iso, .jis]
        static let isoOnly: Set<Shape> = [.iso]
        static let jisOnly: Set<Shape> = [.jis]
    }

    static func rows(for shape: SystemKeyboard.Shape) -> [[Key]] {
        let current: Shape = switch shape {
        case .ansi: .ansi
        case .iso: .iso
        case .jis: .jis
        }
        return allRows.map { $0.filter { $0.shapes.contains(current) } }
    }

    private static let allRows: [[Key]] = [
        [
            Key(kVK_ANSI_Grave), Key(kVK_ANSI_1), Key(kVK_ANSI_2), Key(kVK_ANSI_3),
            Key(kVK_ANSI_4), Key(kVK_ANSI_5), Key(kVK_ANSI_6), Key(kVK_ANSI_7),
            Key(kVK_ANSI_8), Key(kVK_ANSI_9), Key(kVK_ANSI_0), Key(kVK_ANSI_Minus),
            Key(kVK_ANSI_Equal),
            // JIS keeps ¥ where ANSI ends the row.
            Key(kVK_JIS_Yen, label: "¥", shapes: Shape.jisOnly),
            Key(kVK_Delete, 1.6, label: "⌫"),
        ],
        [
            Key(kVK_Tab, 1.5, label: "⇥"), Key(kVK_ANSI_Q), Key(kVK_ANSI_W), Key(kVK_ANSI_E),
            Key(kVK_ANSI_R), Key(kVK_ANSI_T), Key(kVK_ANSI_Y), Key(kVK_ANSI_U),
            Key(kVK_ANSI_I), Key(kVK_ANSI_O), Key(kVK_ANSI_P), Key(kVK_ANSI_LeftBracket),
            Key(kVK_ANSI_RightBracket),
            // ISO moves the backslash down a row and makes Return tall; drawn
            // flat here, which is a deliberate simplification rather than an
            // oversight.
            Key(kVK_ANSI_Backslash, 1.1, shapes: [.ansi, .jis]),
        ],
        [
            Key(kVK_CapsLock, 1.8, label: "⇪"), Key(kVK_ANSI_A), Key(kVK_ANSI_S),
            Key(kVK_ANSI_D), Key(kVK_ANSI_F), Key(kVK_ANSI_G), Key(kVK_ANSI_H),
            Key(kVK_ANSI_J), Key(kVK_ANSI_K), Key(kVK_ANSI_L), Key(kVK_ANSI_Semicolon),
            Key(kVK_ANSI_Quote),
            Key(kVK_ANSI_Backslash, shapes: Shape.isoOnly),
            Key(kVK_Return, 1.8, label: "⏎"),
        ],
        [
            Key(kVK_Shift, 1.5, label: "⇧"),
            // The extra key ISO keyboards have and ANSI ones do not — the one
            // the web version cannot draw at all.
            Key(kVK_ISO_Section, shapes: Shape.isoOnly),
            Key(kVK_ANSI_Z), Key(kVK_ANSI_X), Key(kVK_ANSI_C), Key(kVK_ANSI_V),
            Key(kVK_ANSI_B), Key(kVK_ANSI_N), Key(kVK_ANSI_M), Key(kVK_ANSI_Comma),
            Key(kVK_ANSI_Period), Key(kVK_ANSI_Slash),
            Key(kVK_JIS_Underscore, shapes: Shape.jisOnly),
            Key(kVK_RightShift, 2.2, label: "⇧"),
        ],
        [
            Key(kVK_Control, 1.3, label: "⌃"), Key(kVK_Option, 1.3, label: "⌥"),
            Key(kVK_Command, 1.5, label: "⌘"),
            Key(kVK_JIS_Eisu, 1.2, label: "英数", shapes: Shape.jisOnly),
            Key(kVK_Space, 6, label: " "),
            Key(kVK_JIS_Kana, 1.2, label: "かな", shapes: Shape.jisOnly),
            Key(kVK_RightCommand, 1.5, label: "⌘"), Key(kVK_RightOption, 1.3, label: "⌥"),
        ],
    ]
}

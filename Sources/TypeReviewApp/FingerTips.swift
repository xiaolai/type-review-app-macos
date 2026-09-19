import Carbon.HIToolbox

/// Which finger presses which key: the number shown on the key that is next, when Finger tips is on.
///
/// By key code, not by character, for the same reason `KeyboardGeometry` is: touch typing is positional. The finger
/// that owns the key under the left index stays the same when the layout is Dvorak and that key starts typing `u`,
/// so a chart written in letters would be wrong for everyone who does not type QWERTY.
///
/// The digit is the finger, counted from the thumb: 1 thumb, 2 index, 3 middle, 4 ring, 5 little. That is anatomy's
/// numbering and piano's, and it is the one place a number can be said to have a convention — "the first finger" is
/// the index in ordinary English and the thumb in both of those, so the app says which it means in Settings rather
/// than leaving it to be guessed.
///
/// The hand is not marked at all. It was two colours while every cap carried a badge, and it stopped being worth
/// saying the moment the number moved to the one key that is next: that key is on one side of the board or the
/// other, and nobody confuses their own hands.
///
/// Nothing here draws. This is the chart; `KeyboardView` decides what it looks like.
enum FingerTips {
    /// The two halves of the chart. Not drawn — this is how the chart is written and read, and how a key's finger is
    /// looked up.
    enum Hand {
        case left, right
    }

    /// The standard touch-typing assignment.
    ///
    /// The letters, digits, shift, command and space come from the finger chart the ghost-hands spike measured
    /// against; the rest of the board — tab, caps lock, the brackets, return, fn, control and option — is the
    /// conventional assignment, which no recording here has checked.
    private static let chart: [(hand: Hand, digit: Int, codes: [Int])] = [
        (.left, 5, [kVK_ANSI_Grave, kVK_ANSI_1, kVK_ANSI_Q, kVK_ANSI_A, kVK_ANSI_Z,
                    kVK_Tab, kVK_CapsLock, kVK_Shift, kVK_Control, kVK_Function,
                    kVK_ISO_Section]),
        (.left, 4, [kVK_ANSI_2, kVK_ANSI_W, kVK_ANSI_S, kVK_ANSI_X]),
        (.left, 3, [kVK_ANSI_3, kVK_ANSI_E, kVK_ANSI_D, kVK_ANSI_C]),
        (.left, 2, [kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_R, kVK_ANSI_T,
                    kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_V, kVK_ANSI_B]),
        (.left, 1, [kVK_Option, kVK_Command, kVK_JIS_Eisu]),
        (.right, 2, [kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_Y, kVK_ANSI_U,
                     kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_N, kVK_ANSI_M]),
        (.right, 3, [kVK_ANSI_8, kVK_ANSI_I, kVK_ANSI_K, kVK_ANSI_Comma]),
        (.right, 4, [kVK_ANSI_9, kVK_ANSI_O, kVK_ANSI_L, kVK_ANSI_Period]),
        (.right, 5, [kVK_ANSI_0, kVK_ANSI_Minus, kVK_ANSI_Equal, kVK_Delete,
                     kVK_ANSI_P, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
                     kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_Return, kVK_ANSI_Slash,
                     kVK_RightShift, kVK_RightOption, kVK_RightControl,
                    kVK_JIS_Yen, kVK_JIS_Underscore]),
        (.right, 1, [kVK_Space, kVK_RightCommand, kVK_JIS_Kana]),
    ]

    struct Assignment {
        let hand: Hand
        /// 1 thumb … 5 little.
        let digit: Int
    }

    private static let assignments: [UInt16: Assignment] = {
        var table: [UInt16: Assignment] = [:]
        for entry in chart {
            for code in entry.codes {
                table[UInt16(code)] = Assignment(hand: entry.hand, digit: entry.digit)
            }
        }
        return table
    }()

    /// The finger for a key, 1 thumb … 5 little, or nil for the ones the chart deliberately leaves out.
    static func digit(of code: UInt16) -> Int? { assignments[code]?.digit }

    /// The hand a key belongs to. Asked when a capital is next: the ⇧ that goes with it is the *other* hand's, so
    /// the hand doing the typing does not have to leave the home row to hold it.
    static func hand(of code: UInt16) -> Hand? { assignments[code]?.hand }

    /// The two ⇧ keys, by the hand that holds them.
    static func shift(for hand: Hand) -> UInt16 {
        UInt16(hand == .left ? kVK_Shift : kVK_RightShift)
    }

    /// The two ⌥ keys, by the hand that holds them. Needed for the same reason
    /// ⇧ is: on a German or Spanish keyboard, `@`, `[`, `{` and `\` are ⌥
    /// chords, and a chord is only half explained if the modifier is not named.
    static func option(for hand: Hand) -> UInt16 {
        UInt16(hand == .left ? kVK_Option : kVK_RightOption)
    }

    /// Every key the chart names.
    static var assigned: Set<UInt16> { Set(assignments.keys) }

    /// The keys deliberately left without a finger.
    ///
    /// Escape and the function row are hit by whichever hand is nearer, which is a habit rather than a fingering, and
    /// Touch ID is not typed at all. Written down rather than simply absent, because absence is how this feature
    /// fails silently: a key with no finger draws no badge, which looks exactly like a key whose badge was never
    /// added. `Diagnostics` checks that every key on every keyboard shape is in one list or the other, and that no
    /// entry here names a key no keyboard has.
    static let unassigned: Set<UInt16> = Set(
        ([kVK_Escape, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
          kVK_F10, kVK_F11, kVK_F12].map(UInt16.init)) + [KeyboardGeometry.touchIDCode]
    )

    /// What the digits mean, for Settings and anywhere else that has to say it.
    static let legend = "1 thumb · 2 index · 3 middle · 4 ring · 5 little"
}

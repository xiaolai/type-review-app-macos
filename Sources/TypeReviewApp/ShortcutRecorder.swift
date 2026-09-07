import AppKit
import Carbon.HIToolbox
import TypeReviewKit

extension ShortcutModifiers {
    /// From what AppKit reports on an event.
    init(_ flags: NSEvent.ModifierFlags) {
        var out: ShortcutModifiers = []
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.option) { out.insert(.option) }
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.command) { out.insert(.command) }
        self = out
    }

    /// To what `NSMenuItem` wants.
    var cocoa: NSEvent.ModifierFlags {
        var out: NSEvent.ModifierFlags = []
        if contains(.control) { out.insert(.control) }
        if contains(.option) { out.insert(.option) }
        if contains(.shift) { out.insert(.shift) }
        if contains(.command) { out.insert(.command) }
        return out
    }

    /// To what `RegisterEventHotKey` wants, which is a different set of bits
    /// again — Carbon's masks predate Cocoa's and share none of their values.
    var carbon: UInt32 {
        var out: UInt32 = 0
        if contains(.control) { out |= UInt32(controlKey) }
        if contains(.option) { out |= UInt32(optionKey) }
        if contains(.shift) { out |= UInt32(shiftKey) }
        if contains(.command) { out |= UInt32(cmdKey) }
        return out
    }
}

extension KeyboardShortcut {
    /// The character the key produces under the *current* layout, upper-cased
    /// the way menus print it. Asked of the system rather than looked up in a
    /// table, so a Dvorak user sees the letter their keyboard actually types.
    @MainActor var keyName: String {
        if let named = Self.namedKeys[keyCode] { return named }
        // Non-empty is not the same as printable. `UCKeyTranslate` answers for
        // keys that have no legend with a control character, which is a
        // non-empty string that draws as a blank or a box — a shortcut label
        // saying nothing at all. Anything outside the printable set falls
        // through to the code, which is at least honest.
        let typed = SystemKeyboard.character(forKeyCode: keyCode)?.uppercased()
        if let typed, !typed.isEmpty,
            typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        {
            return typed
        }
        return "Key \(keyCode)"
    }

    @MainActor var displayString: String { display(keyName: keyName) }

    /// What `NSMenuItem.keyEquivalent` wants, which is the *character* the key
    /// produces — not the label a menu prints for it.
    ///
    /// The menu used to be given `keyName.lowercased()`, so a shortcut on
    /// Space was published to AppKit as the five-letter string "space" and one
    /// on F1 as "f1". Neither matches any key, so the menu item that exists as
    /// the fallback for when global registration fails did nothing at all —
    /// the one case where it is the only way to reach the command.
    @MainActor var keyEquivalentString: String {
        if let special = Self.keyEquivalents[keyCode] { return special }
        return SystemKeyboard.character(forKeyCode: keyCode)?.lowercased() ?? ""
    }

    /// Keys whose equivalent is a control character or one of AppKit's
    /// private-use function-key scalars rather than what they type.
    private static let keyEquivalents: [UInt16: String] = {
        func scalar(_ value: Int) -> String {
            UnicodeScalar(UInt32(value)).map(String.init) ?? ""
        }
        var out: [UInt16: String] = [
            UInt16(kVK_Space): " ",
            UInt16(kVK_Return): "\r",
            UInt16(kVK_ANSI_KeypadEnter): "\u{3}",
            UInt16(kVK_Tab): "\t",
            UInt16(kVK_Delete): "\u{8}",
            UInt16(kVK_ForwardDelete): scalar(NSDeleteFunctionKey),
            UInt16(kVK_Escape): "\u{1B}",
            UInt16(kVK_LeftArrow): scalar(NSLeftArrowFunctionKey),
            UInt16(kVK_RightArrow): scalar(NSRightArrowFunctionKey),
            UInt16(kVK_UpArrow): scalar(NSUpArrowFunctionKey),
            UInt16(kVK_DownArrow): scalar(NSDownArrowFunctionKey),
            UInt16(kVK_Home): scalar(NSHomeFunctionKey),
            UInt16(kVK_End): scalar(NSEndFunctionKey),
            UInt16(kVK_PageUp): scalar(NSPageUpFunctionKey),
            UInt16(kVK_PageDown): scalar(NSPageDownFunctionKey),
            UInt16(kVK_Help): scalar(NSHelpFunctionKey),
        ]
        // F1–F20 are contiguous in both numberings, so the table is generated
        // rather than typed twenty times.
        let functionKeys: [Int] = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
            kVK_F20,
        ]
        for (index, code) in functionKeys.enumerated() {
            out[UInt16(code)] = scalar(NSF1FunctionKey + index)
        }
        return out
    }()

    /// Keys that produce no character, or whose character is not what a menu
    /// prints. `UCKeyTranslate` answers with a control character for most of
    /// these, which would render as a blank or a box.
    @MainActor private static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        UInt16(kVK_ANSI_KeypadEnter): "⌤", UInt16(kVK_Help): "?⃝",
    ]
}

/// A button that records the next key combination pressed.
///
/// The macOS idiom for this, and there is no AppKit control that does it — so
/// it is a button that swaps its own title for a prompt and reads one key
/// event through a local monitor while armed.
///
/// While recording it swallows every key, which is the point: the combination
/// being recorded is very often one that would otherwise trigger a menu item,
/// and a recorder that fired the menu instead of capturing the key would be
/// unable to record most of the shortcuts worth setting.
final class ShortcutRecorder: NSButton {
    /// Called with a new shortcut, or with nil when the user clears it.
    var onChange: ((KeyboardShortcut?) -> Void)?
    /// Called with true when recording starts and false when it ends.
    ///
    /// The owner uses it to stand the application's Carbon hot key down for
    /// the duration. A `RegisterEventHotKey` binding is handled below the
    /// Cocoa event stream, so the local monitor here never sees it: trying to
    /// re-record the combination you are already using fired the sound toggle
    /// instead of being captured, which made the one shortcut you most want to
    /// change the one you could not.
    var onRecordingChanged: ((Bool) -> Void)?

    private var shortcut: KeyboardShortcut?
    private var monitor: Any?
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            refreshTitle()
            needsDisplay = true
            onRecordingChanged?(isRecording)
        }
    }
    /// Notification observers, held only while recording.
    private var observers: [NSObjectProtocol] = []

    init(shortcut: KeyboardShortcut?) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        // Wide enough for ⌃⌥⇧⌘ plus a named key, so the control does not
        // change width as the user tries combinations.
        widthAnchor.constraint(equalToConstant: 130).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func beginRecording() {
        guard monitor == nil else { return }
        isRecording = true
        // A local event monitor, not the responder chain.
        //
        // A monitor sees every key event bound for this app before anything
        // else does, and that reach is what a recorder needs: the
        // combinations most worth reassigning are exactly the ones something
        // else would otherwise swallow. ⌘Q would quit before the recorder saw
        // it; ⌘, would open this window again.
        //
        // Doing it through the responder chain means overriding both
        // `keyDown` (for plain keys, which go to the first responder) and
        // `performKeyEquivalent` (for modified ones, which do not) — two
        // paths, and correctness that depends on this button actually holding
        // focus. One monitor needs neither, and it is what every other
        // recorder on this platform uses.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            // Only keys aimed at the window this button is in. A local monitor
            // is app-wide, so without this a keystroke in the practice window
            // — which is still on screen behind Settings — would be swallowed
            // and saved as the shortcut.
            guard event.window == nil || event.window === self.window else { return event }
            self.capture(event)
            return nil  // swallowed, so nothing else acts on it
        }
        armBoundaries()
    }

    /// Everything that should end a recording other than a key press.
    ///
    /// `viewDidMoveToWindow` was the whole of this and it never fired: closing
    /// an `NSWindow` does not detach its content view, so `window` stays
    /// non-nil and the branch below is dead on that path. The monitor stayed
    /// armed for the life of the app, swallowing every keystroke including the
    /// ones meant for the typing surface — and the next key pressed anywhere
    /// was saved as the shortcut.
    private func armBoundaries() {
        let centre = NotificationCenter.default
        let end: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.endRecording() }
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(centre.addObserver(forName: name, object: window, queue: .main, using: end))
        }
        observers.append(
            centre.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main,
                using: end))
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        isRecording = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Kept for the case it does cover — the view genuinely leaving its
        // window — but it is no longer the only guard. See `armBoundaries`.
        if window == nil { endRecording() }
    }

    private func capture(_ event: NSEvent) {
        // Escape abandons; Delete clears the shortcut entirely, which is how
        // someone turns the global hot key off without having to pick a
        // combination they do not want.
        //
        // Unmodified only. Both tests used to ignore the modifier flags, so
        // ⌘⌫ — a perfectly ordinary shortcut — cleared the setting instead of
        // being recorded, and ⌥⎋ cancelled instead of being offered to
        // validation. A combination carrying a modifier is someone recording,
        // not someone reaching for the cancel key.
        let bare = ShortcutModifiers(event.modifierFlags).isEmpty
        if bare, event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            return
        }
        if bare, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            shortcut = nil
            endRecording()
            onChange?(nil)
            return
        }

        let candidate = KeyboardShortcut(
            keyCode: event.keyCode, modifiers: ShortcutModifiers(event.modifierFlags))
        guard candidate.isValid else {
            // Not worth a sentence: the user is mid-gesture with keys held
            // down. A beep says "keep holding modifiers" faster than words
            // would, and recording stays armed so they can simply try again.
            NSSound.beep()
            return
        }
        shortcut = candidate
        endRecording()
        onChange?(candidate)
    }

    private func refreshTitle() {
        if isRecording {
            title = "Type a shortcut…"
        } else if let shortcut {
            title = shortcut.displayString
        } else {
            title = "None"
        }
    }
}

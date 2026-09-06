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
        let typed = SystemKeyboard.character(forKeyCode: keyCode)?.uppercased()
        return typed?.isEmpty == false ? typed! : "Key \(keyCode)"
    }

    @MainActor var displayString: String { display(keyName: keyName) }

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

    private var shortcut: KeyboardShortcut?
    private var monitor: Any?
    private var isRecording = false {
        didSet {
            refreshTitle()
            needsDisplay = true
        }
    }

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
            self.capture(event)
            return nil  // swallowed, so nothing else acts on it
        }
    }

    private func endRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The Settings window is closed rather than deallocated, and a monitor
        // left armed would keep eating every keystroke in the app.
        if window == nil { endRecording() }
    }

    private func capture(_ event: NSEvent) {
        // Escape abandons; Delete clears the shortcut entirely, which is how
        // someone turns the global hot key off without having to pick a
        // combination they do not want.
        if event.keyCode == UInt16(kVK_Escape) {
            endRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
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

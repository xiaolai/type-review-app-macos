import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Keystroke sound for the whole machine rather than for one window.
///
/// ## What this reads, and what it must never read
///
/// A monitor on every key event in every application is the shape of a
/// keylogger, and the only thing that makes it not one is discipline about
/// what it looks at. This reads `keyCode` and nothing else. It never touches
/// `characters` or `charactersIgnoringModifiers`, it never accumulates, it
/// never writes anywhere, and it hands onward a single `UInt16` — so no
/// caller downstream can be given text either.
///
/// `keyCode` is a position on the keyboard, resolved before the layout,
/// before dead keys and before any input method: code 12 is `q` on QWERTY and
/// `'` on Dvorak, and on an AZERTY machine it is `a`. It cannot reconstruct
/// what was typed without knowing the layout, and a sound has no business
/// knowing the letter in the first place. Keep it that way.
///
/// ## Two monitors, not one
///
/// A global monitor is delivered only *other* applications' events — that is
/// what makes it global. On its own it would go silent the moment TYPE came
/// to the front, which is the app someone is most likely to be looking at
/// while deciding whether the setting works. The local monitor covers this
/// app's own windows; between them every keystroke is heard exactly once.
@MainActor
final class GlobalKeySound {
    /// Called for each physical key press, with the code and nothing else.
    private let play: (UInt16) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Modifier state as of the last `.flagsChanged`, so a press can be told
    /// from a release.
    private var lastFlags: NSEvent.ModifierFlags = []

    init(play: @escaping (UInt16) -> Void) {
        self.play = play
    }

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }

    func start() {
        guard !isRunning else { return }
        lastFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            event in
            MainActor.assumeIsolated { KeySoundMonitors.shared?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            event in
            MainActor.assumeIsolated { KeySoundMonitors.shared?.handle(event) }
            // Returned unchanged. A local monitor that swallowed the event
            // would make the sound and eat the keystroke with it.
            return event
        }
        KeySoundMonitors.shared = self
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if KeySoundMonitors.shared === self { KeySoundMonitors.shared = nil }
    }

    /// Tears the monitors down and puts them straight back.
    ///
    /// For the moment Input Monitoring is granted while the app is already
    /// running. The system decides what a monitor may see when it is
    /// installed, so one installed before the grant stays deaf afterwards —
    /// and nothing tells an app its permission changed, which is why this is
    /// driven by the app coming back to the front rather than by an event.
    func reinstall() {
        guard isRunning else { return }
        stop()
        start()
    }

    /// Starts or stops to match `wanted`, and reports whether sound is now
    /// running. Idempotent, because it is called from every place the setting
    /// can change and from the launch path as well.
    @discardableResult
    func setRunning(_ wanted: Bool) -> Bool {
        if wanted { start() } else { stop() }
        return isRunning
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Not on auto-repeat. A held key makes one sound on a real
            // keyboard; at the system repeat rate it would make about thirty
            // a second here.
            //
            // Modified keys *do* sound, unlike in the practice window. There
            // the rule exists because ⌘S is a menu command rather than
            // typing; here the user physically pressed a key in some other
            // app, and a keyboard that goes quiet for every shortcut is not
            // the thing this setting promises.
            guard !event.isARepeat else { return }
            play(event.keyCode)
        case .flagsChanged:
            handleModifier(event)
        default:
            break
        }
    }

    /// Modifier keys, on the way down only.
    ///
    /// `flagsChanged` fires for press *and* release, and a shift key that
    /// clicks twice per capital is wrong in a way you hear immediately. Which
    /// of the two an event is has to be inferred: compare the flag this key
    /// owns against the flags seen last time.
    private func handleModifier(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { lastFlags = flags }
        guard let flag = Self.flag(forModifierKeyCode: event.keyCode) else { return }
        // Caps lock latches rather than being held, so its "release" event
        // arrives on the *next* press — the key really did move both times,
        // and both should sound.
        if event.keyCode == UInt16(kVK_CapsLock) {
            play(event.keyCode)
            return
        }
        guard flags.contains(flag), !lastFlags.contains(flag) else { return }
        play(event.keyCode)
    }

    /// Which flag a modifier key owns, or nil for a key that is not one.
    ///
    /// Left and right halves are separate keys with separate codes and one
    /// shared flag, which is exactly why the press/release test above cannot
    /// be `flags != lastFlags`: releasing left shift while right shift is
    /// still held changes no flag at all.
    private static func flag(forModifierKeyCode code: UInt16) -> NSEvent.ModifierFlags? {
        switch Int(code) {
        case kVK_Shift, kVK_RightShift: return .shift
        case kVK_Control, kVK_RightControl: return .control
        case kVK_Option, kVK_RightOption: return .option
        case kVK_Command, kVK_RightCommand: return .command
        case kVK_CapsLock: return .capsLock
        case kVK_Function: return .function
        default: return nil
        }
    }

    // MARK: - Permission

    /// Whether the system will actually deliver other applications' key
    /// events to this process.
    ///
    /// Two gates, and either one opens it. `addGlobalMonitorForEvents`
    /// documents Accessibility; what macOS has enforced for key events since
    /// Catalina is Input Monitoring. Checking both avoids sending someone to
    /// grant a permission they already granted under the other name.
    ///
    /// This matters because the failure is silent: without permission the
    /// monitor is installed, returns a perfectly good object, and is simply
    /// never called. Nothing anywhere reports it — which is why the setting
    /// shows this state rather than letting the user wonder why their
    /// keyboard went quiet.
    static var isPermitted: Bool {
        if AXIsProcessTrusted() { return true }
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Asks the system for Input Monitoring.
    ///
    /// macOS shows its prompt only the first time a given process asks, and
    /// answers from cache forever after. That is why the caller also offers
    /// the System Settings door: for everyone past their first refusal, this
    /// call is a no-op that returns false.
    @discardableResult
    static func requestPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Opens the pane where the permission is granted by hand.
    static func openPermissionSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The one monitor currently installed.
///
/// `NSEvent`'s monitor handlers are `@Sendable` and outlive the call that
/// registered them, so they cannot capture a main-actor object directly. A
/// single main-actor-isolated reference is the cheapest way to get back to it
/// without weakening the isolation of `GlobalKeySound` itself — and "one at a
/// time" is not a limitation here, it is the requirement: two monitors would
/// mean two clicks per keystroke.
@MainActor
enum KeySoundMonitors {
    static weak var shared: GlobalKeySound?
}

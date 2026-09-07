import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
/// app's own windows; between them a keystroke is heard exactly once.
///
/// ## What is not covered
///
/// Keys consumed inside a nested event-tracking loop of *this* app — while a
/// menu is open, or a window is being dragged — reach neither monitor: the
/// local one is bypassed by the tracking loop and the global one excludes its
/// own application. Those keystrokes are silent. It is a small hole (menus do
/// not stay open long) and closing it would mean an event tap, which is a
/// heavier permission and a worse trade for a sound.
@MainActor
final class GlobalKeySound {
    /// Called for each physical key press, with the code and nothing else.
    private let play: (UInt16) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Modifier state as of the last `.flagsChanged`, as the *raw* mask, so a
    /// press can be told from a release for each physical key.
    private var lastRawFlags: UInt = 0
    /// Whether modifier keys click. See `AppPreferences.modifierSound`.
    private(set) var soundsModifiers = false
    /// Applications to stay silent in, by bundle identifier.
    var mutedApps: Set<String> = []
    /// The bundle identifier of the application in front, cached.
    ///
    /// Asked once per application switch rather than once per keystroke. This
    /// runs on every key pressed anywhere on the machine, and reaching into
    /// `NSWorkspace` from that path to answer a question that changes a few
    /// times an hour is work nobody needs done.
    private var frontmostBundleID: String?
    /// The application the "mute in …" item should name.
    ///
    /// Whatever is in front, unless that is TYPE — in which case the last
    /// thing that was. Both halves are needed: the status-bar menu can be
    /// opened without TYPE ever becoming active, and the menu-bar one cannot
    /// be opened any other way. Falling back only to the remembered app left
    /// the item dead until the user had switched applications at least once,
    /// which is not a state anyone should meet on first use.
    var lastForeignApp: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier { return front }
        return rememberedForeignApp
    }

    private var rememberedForeignApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(play: @escaping (UInt16) -> Void) {
        self.play = play
    }

    var isRunning: Bool { localMonitor != nil }

    func start() {
        guard !isRunning else { return }
        // One owner at a time, enforced rather than assumed. The monitor
        // callbacks reach back through a single shared reference, so a second
        // instance installed its own pair and then redirected *both* pairs to
        // itself — two clicks per key, from monitors the first instance still
        // believed it owned and would later remove.
        precondition(
            KeySoundMonitors.shared == nil,
            "a GlobalKeySound is already running; stop it before starting another")
        lastRawFlags = NSEvent.modifierFlags.rawValue
        // `.flagsChanged` only when modifiers are wanted, so the default
        // configuration observes fewer kinds of keyboard event rather than
        // observing them and throwing the result away.
        let matching: NSEvent.EventTypeMask =
            soundsModifiers ? [.keyDown, .flagsChanged] : [.keyDown]
        // Installed whether or not the permission has been granted, and that
        // is the point: *asking* for other applications' key events is what
        // makes macOS record this app as a client of Accessibility, list it
        // and offer its prompt. Skipping the install while ungranted was
        // circular — nothing ever asked, so nothing was ever offered, and the
        // Settings button sent the user to a list with nothing in it to switch
        // on.
        //
        // What arrives without permission is discarded in `handleGlobal`. TCC
        // gates `.keyDown` and not `.flagsChanged`, so an ungranted app still
        // receives modifier events, and playing those was the worst available
        // outcome: shift and caps lock clicking everywhere while letters
        // stayed silent, which reads as a broken feature rather than as a
        // permission nobody has granted.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: matching) { event in
            MainActor.assumeIsolated { KeySoundMonitors.shared?.handleGlobal(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: matching) { event in
            MainActor.assumeIsolated { KeySoundMonitors.shared?.handle(event) }
            // Returned unchanged. A local monitor that swallowed the event
            // would make the sound and eat the keystroke with it.
            return event
        }
        // The frontmost application, tracked rather than polled. See
        // `frontmostBundleID`.
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let monitor = KeySoundMonitors.shared else { return }
                monitor.frontmostBundleID = app?.bundleIdentifier
                if let app, app.bundleIdentifier != Bundle.main.bundleIdentifier {
                    monitor.rememberedForeignApp = app
                }
            }
        }
        KeySoundMonitors.shared = self
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if KeySoundMonitors.shared === self { KeySoundMonitors.shared = nil }
    }

    /// Tears the monitors down and puts them straight back.
    ///
    /// For the moment Accessibility is granted while the app is already
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
    func setRunning(_ wanted: Bool, soundsModifiers modifiers: Bool) -> Bool {
        // A change of scope needs new monitors: which event kinds they watch
        // is fixed when they are installed.
        if isRunning, modifiers != soundsModifiers { stop() }
        soundsModifiers = modifiers
        if wanted { start() } else { stop() }
        return isRunning
    }

    /// Events from another application, which arrive whether or not the
    /// permission exists. Silent until all of them do, and silent in the
    /// places sound does not belong.
    private func handleGlobal(_ event: NSEvent) {
        guard Self.isPermitted, !isMutedHere else { return }
        handle(event)
    }

    /// Whether this keystroke should be silent because of *where* it is.
    ///
    /// Two reasons, and the first is not a setting. When any application turns
    /// on secure event input — a password field, the login window, a terminal
    /// told to protect its input — the keystroke is one nobody should be
    /// broadcasting the rhythm of. Asking the system covers every password
    /// field in every application, including the ones no exclusion list would
    /// ever have thought to name.
    ///
    /// The second is the user's own list. Video calls, games and anything with
    /// its own audio are the cases a system flag cannot know about.
    private var isMutedHere: Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let frontmostBundleID else { return false }
        return mutedApps.contains(frontmostBundleID)
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
            guard soundsModifiers else { return }
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
        let raw = event.modifierFlags.rawValue
        defer { lastRawFlags = raw }
        // The device-specific bit for *this* key, not the shared one.
        //
        // `.shift` is one flag for two keys. Testing it meant that with left
        // shift already held, pressing right shift changed nothing the test
        // could see and made no sound — and the same for control, option and
        // command. AppKit keeps a separate bit per physical key in the raw
        // mask; those are what distinguish the two halves.
        guard let mask = Self.deviceMask(forModifierKeyCode: event.keyCode) else { return }
        // Caps lock latches, so its bit goes up on one press and down on the
        // next — either way the key moved once and should click once. Every
        // other modifier is held, so only the press counts.
        //
        // It used to click on *any* `flagsChanged` carrying its code, and
        // macOS sends two per press: one as the key goes down and one as it
        // comes back up. Two clicks for one press.
        if event.keyCode == UInt16(kVK_CapsLock) {
            guard (raw ^ lastRawFlags) & mask != 0 else { return }
            play(event.keyCode)
            return
        }
        guard raw & mask != 0, lastRawFlags & mask == 0 else { return }
        play(event.keyCode)
    }

    /// The device-specific bit a modifier key sets, or nil if it is not one.
    ///
    /// These live in the raw modifier mask alongside the documented
    /// device-*independent* flags, one bit per physical key. They are the only
    /// way to tell left shift from right shift, which share `.shift`.
    /// Values from `IOKit/hidsystem/IOLLEvent.h` (`NX_DEVICE…KEYMASK`).
    private static func deviceMask(forModifierKeyCode code: UInt16) -> UInt? {
        switch Int(code) {
        case kVK_Shift: return 0x0000_0002
        case kVK_RightShift: return 0x0000_0004
        case kVK_Control: return 0x0000_0001
        case kVK_RightControl: return 0x0000_2000
        case kVK_Option: return 0x0000_0020
        case kVK_RightOption: return 0x0000_0040
        case kVK_Command: return 0x0000_0008
        case kVK_RightCommand: return 0x0000_0010
        // Latching, and with no left/right pair, so the shared flag is the
        // only bit there is.
        case kVK_CapsLock: return NSEvent.ModifierFlags.capsLock.rawValue
        // No device-specific bit; the shared flag is all there is.
        case kVK_Function: return NSEvent.ModifierFlags.function.rawValue
        default: return nil
        }
    }

    // MARK: - Permission

    /// Whether the system will actually deliver other applications' key
    /// events to this process.
    ///
    /// Accessibility, and only Accessibility. That is what
    /// `addGlobalMonitorForEvents` documents for key-related events, and it is
    /// where macOS lists this app.
    ///
    /// It used to accept Input Monitoring as an alternative, and everything
    /// downstream — the request, the button, the captions — named that
    /// permission instead. It is the wrong one: this app never calls the API
    /// that gates on it, so it never appeared in that list, and someone
    /// following the button arrived at a pane that was empty and stayed empty.
    /// Accepting it here would also have been wrong in the other direction:
    /// granting Input Monitoring alone would have reported "permitted" over a
    /// monitor that still received nothing.
    ///
    /// The check matters because the failure is otherwise silent: the monitor
    /// installs, returns a perfectly good object, and is never called.
    static var isPermitted: Bool { AXIsProcessTrusted() }

    /// Asks the system for Accessibility, with its prompt.
    ///
    /// The prompt is what puts the app in front of the user with an "Open
    /// System Settings" button; the entry in the list is added by asking at
    /// all. macOS shows it only the first time a given process asks and
    /// answers from cache afterwards, which is why the caller also offers the
    /// System Settings door directly.
    @discardableResult
    static func requestPermission() -> Bool {
        // The key by name. `kAXTrustedCheckOptionPrompt` is a global `var` in
        // the SDK, which Swift 6 will not let a concurrent context read.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Opens the pane where the permission is granted by hand.
    static func openPermissionSettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
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

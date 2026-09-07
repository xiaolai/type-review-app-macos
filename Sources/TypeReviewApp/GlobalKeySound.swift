import AppKit
import TypeReviewKit
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
/// ## One tap, not two monitors
///
/// This used to be a pair of `NSEvent` monitors — a global one for other
/// applications and a local one for this app's own windows, because a global
/// monitor is never delivered its own process's events. A session `CGEventTap`
/// sees the whole login session, so one of it replaces both, and `.listenOnly`
/// means it cannot alter or swallow the keystroke it sounds.
///
/// The move was forced by the App Store: `addGlobalMonitorForEvents` is gated
/// on Accessibility, and Accessibility is not available to sandboxed apps. It
/// turned out to be the better trade anyway, and the note that used to sit
/// here had it exactly backwards — it called a tap "a heavier permission".
/// A tap is gated on **Input Monitoring**, which can only listen, where
/// Accessibility can drive other applications. The narrower permission was the
/// one available all along.
///
/// ## What a tap has that a monitor did not
///
/// It can fail to enable. `CGEvent.tapCreate` hands back a usable port without
/// permission and only the enable fails, so `installGlobalMonitor` checks
/// `tapIsEnabled` rather than trusting a non-nil port. And the system switches
/// off a tap whose callback ran too slowly, which `tapCallback` handles by
/// turning it back on — a path that has never fired in testing and is
/// therefore written but unproven.
@MainActor
final class GlobalKeySound {
    /// Called for each physical key press, with the code and nothing else.
    private let play: (UInt16, Stroke) -> Void

    /// One session-wide tap, where there used to be two `NSEvent` monitors.
    ///
    /// `.cgSessionEventTap` sees the whole login session, this app's own
    /// window included, so the separate local monitor that existed to hear
    /// TYPE's own keys is gone rather than ported. `.listenOnly` means the tap
    /// cannot alter or swallow an event, which is what the local monitor's
    /// "return it unchanged" was protecting against.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Modifier state as of the last `.flagsChanged`, as the *raw* mask, so a
    /// press can be told from a release for each physical key.
    private var lastRawFlags: UInt = 0
    /// Whether modifier keys click. See `AppPreferences.modifierSound`.
    private(set) var soundsModifiers = false
    /// Whether keys are heard coming back up as well as going down.
    ///
    /// Gates the event mask rather than the handler, and that is the whole
    /// point. `.keyUp` doubles the keyboard events this process receives from
    /// every application on the machine; taking them in order to throw them
    /// away would be the wrong trade for a feature nobody switched on. The
    /// same rule `.flagsChanged` already follows.
    private(set) var soundsRelease = false
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
    private var siblingObservers: [NSObjectProtocol] = []

    init(play: @escaping (UInt16, Stroke) -> Void) {
        self.play = play
    }

    /// Whether this monitor owns the shared slot — started, whether or not a
    /// tap could actually be installed.
    ///
    /// Separate from `isListening`, and the separation is the fix for a crash.
    /// This used to be `tap != nil`, which was safe while the old `NSEvent`
    /// monitors always installed: `start()` guards on it, and a monitor that
    /// had started always looked started. A tap can fail — no Input Monitoring
    /// yet is the ordinary case — leaving `KeySoundMonitors.shared` set with no
    /// tap. `start()` then passed its own guard and hit the ownership
    /// precondition, so the app died on the next preference change: switch the
    /// setting on before granting the permission, nudge the volume, crash.
    private(set) var isRunning = false

    /// Whether a tap is actually installed and hearing keys. What the caller
    /// of `setRunning` wants to know: "on" and "heard" are not the same thing
    /// while the permission is missing or another copy holds the tap.
    var isListening: Bool { tap != nil }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        // One owner at a time, enforced rather than assumed. The monitor
        // callbacks reach back through a single shared reference, so a second
        // instance installed its own pair and then redirected *both* pairs to
        // itself — two clicks per key, from monitors the first instance still
        // believed it owned and would later remove.
        precondition(
            KeySoundMonitors.shared == nil,
            "a GlobalKeySound is already running; stop it before starting another")
        lastRawFlags = NSEvent.modifierFlags.rawValue
        // Attempted whether or not the permission has been granted, and that
        // is the point: *asking* is what makes macOS record this app as a
        // client of Input Monitoring, list it, and offer its prompt. Skipping
        // it while ungranted was circular — nothing ever asked, so nothing was
        // ever offered, and the Settings button sent the user to a list with
        // nothing in it to switch on.
        //
        // With a tap the ungranted case is cleaner than it was with `NSEvent`.
        // A tap that cannot be enabled is discarded on the spot, so nothing is
        // delivered at all — where the old monitors let modifier events
        // through without permission and clicked for shift and caps lock while
        // letters stayed silent, which reads as a broken feature rather than
        // as a permission nobody has granted.
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
                // Not "receive and discard": while a password manager is in
                // front the monitor is taken down, so nothing is delivered.
                // Switching applications is rare enough that installing and
                // removing it around them costs nothing worth measuring.
                monitor.reconsider()
            }
        }
        // The other install starting or quitting changes whether this one
        // should be listening, and neither is an activation — a menu-bar-only
        // build never comes to the front at all.
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            siblingObservers.append(
                NSWorkspace.shared.notificationCenter.addObserver(
                    forName: name, object: nil, queue: .main
                ) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                    let id = app?.bundleIdentifier
                    MainActor.assumeIsolated {
                        guard id == Channel.sibling else { return }
                        KeySoundMonitors.shared?.reconsider()
                    }
                })
        }
        installGlobalMonitor()
        KeySoundMonitors.shared = self
    }

    /// Puts the tap up or takes it down to match the current reasons.
    ///
    /// Called for anything that can change the answer: a different application
    /// coming to the front, and the other install starting or quitting.
    private func reconsider() {
        if shouldNotListen {
            removeGlobalMonitor()
        } else {
            installGlobalMonitor()
        }
    }

    /// Installs the monitor on other applications' keys, unless something says
    /// it should not be listening at all.
    private func installGlobalMonitor() {
        guard tap == nil, !shouldNotListen else { return }
        // The callback is a C function pointer and cannot capture, so it
        // reaches the instance the same way the old monitors did — through the
        // one shared reference.
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: eventMask, callback: Self.tapCallback, userInfo: nil)
        else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // Enabling is the check that matters, not creating. Without Input
        // Monitoring `tapCreate` still hands back a perfectly good port and
        // the tap simply never turns on — measured, and the same shape as the
        // hot key that registers and then never fires. Keeping a port that
        // cannot be enabled would report a running monitor that hears nothing.
        guard CGEvent.tapIsEnabled(tap: port) else {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            return
        }
        tap = port
        tapSource = source
    }

    private func removeGlobalMonitor() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
    }

    /// The C trampoline.
    ///
    /// Runs on whichever run loop the source was added to, which is the main
    /// one, so the isolation assertion holds for the same reason it does in
    /// `GlobalHotKey`.
    ///
    /// `NSEvent(cgEvent:)` is what keeps this a change of *source* rather than
    /// a change of logic: every rule about key codes, auto-repeat and
    /// device-specific modifier bits carries over untouched.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A failure mode `NSEvent` monitors do not have: the system
            // switches off a tap whose callback was too slow, or one the user
            // disabled, and it stays off until something turns it back on.
            MainActor.assumeIsolated { KeySoundMonitors.shared?.reEnableTap() }
            return nil
        }
        // Neither `CGEvent` nor `NSEvent` is `Sendable`, so the event cannot
        // cross into the main actor's closure on its own. The box carries it
        // across, and the claim it makes is true rather than convenient: the
        // run-loop source is added to `CFRunLoopGetCurrent()` from
        // `installGlobalMonitor()`, which is main-actor isolated, so this
        // callback runs on the main thread and there is no second thread for
        // the event to race against. `assumeIsolated` below traps if that ever
        // stops being so.
        let box = EventBox(event: event)
        MainActor.assumeIsolated {
            guard let nsEvent = NSEvent(cgEvent: box.event) else { return }
            KeySoundMonitors.shared?.handleGlobal(nsEvent)
        }
        return Unmanaged.passUnretained(event)
    }

    /// Carries one event from the tap callback to the main actor.
    ///
    /// `@unchecked` because the compiler cannot see what the run loop
    /// guarantees. See the note at the call site for why the guarantee holds.
    private struct EventBox: @unchecked Sendable {
        let event: CGEvent
    }

    private func reEnableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Whether the application in front is one whose keystrokes are not to be
    /// observed.
    ///
    /// Two ways of knowing, because a hand-kept list of password managers can
    /// only ever be a list of the ones somebody thought of.
    private var isProtectedAppInFront: Bool {
        guard let frontmostBundleID else { return false }
        return AppPreferences.isProtected(frontmostBundleID)
            || Self.declaresCredentialProvider(frontmostBundleID)
    }

    /// Every reason not to be listening right now.
    ///
    /// The sibling check joins the password-manager one rather than getting
    /// machinery of its own, because they want the identical thing: no tap,
    /// installed again when the reason goes away. Two taps on one machine mean
    /// every keystroke sounds twice; `Channel.shouldYieldToSibling` decides
    /// which copy stops, by launch order so that both reach opposite answers.
    /// Self-correcting either way: quitting one lets the other pick the tap up
    /// on the next notification.
    private var shouldNotListen: Bool {
        isProtectedAppInFront || Channel.shouldYieldToSibling
    }

    /// Whether an application says it is a password manager.
    ///
    /// macOS asks one to ship an AutoFill credential-provider extension, so
    /// the application's own bundle declares what it is — better evidence than
    /// any list this app could maintain, and it covers managers written after
    /// this was. It is a supplement rather than a replacement: Apple's own
    /// Passwords and Keychain Access provide the service from inside the
    /// system and ship no such extension, and neither do several of the
    /// KeePass front-ends.
    ///
    /// Answered once per application and remembered. It reads a few property
    /// lists, which is nothing next to how often it would otherwise be asked.
    static func declaresCredentialProvider(_ bundleID: String) -> Bool {
        if let known = credentialProviders[bundleID] { return known }
        var found = false
        // Only a *confirmed* answer is remembered. Caching a failed lookup as
        // `false` turned any transient problem — the app being replaced
        // mid-read, a directory that could not be listed — into "this is not a
        // password manager" for the rest of the process's life. Of the two
        // ways to be wrong here, that is the one that costs something.
        var confirmed = false
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let dir = url.appendingPathComponent("Contents/PlugIns")
            let plugins: [URL]
            do {
                plugins = try FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil)
                confirmed = true
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
            {
                // No PlugIns directory is an answer, and a confirmed one: this
                // application ships no extensions at all.
                plugins = []
                confirmed = true
            } catch {
                plugins = []
            }
            for plugin in plugins where plugin.pathExtension == "appex" {
                guard
                    let info = NSDictionary(
                        contentsOf: plugin.appendingPathComponent("Contents/Info.plist"))
                else {
                    // Listing the directory worked but this extension could not
                    // be read, so nothing was established about it. Folded in
                    // with "read it and it is not a credential provider", the
                    // unread one would be remembered as absence — the same
                    // mistake as caching a failed lookup, one level down.
                    confirmed = false
                    continue
                }
                // Read, and simply not a credential provider. That is an
                // answer, and it is safe to remember.
                guard let extensionInfo = info["NSExtension"] as? [String: Any],
                    let point = extensionInfo["NSExtensionPointIdentifier"] as? String
                else { continue }
                if point.contains("credential-provider") {
                    found = true
                    break
                }
            }
        }
        if confirmed { credentialProviders[bundleID] = found }
        return found
    }

    private static var credentialProviders: [String: Bool] = [:]

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        for observer in siblingObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        siblingObservers = []
        removeGlobalMonitor()
        isRunning = false
        if KeySoundMonitors.shared === self { KeySoundMonitors.shared = nil }
    }

    /// Tears the tap down and puts it straight back.
    ///
    /// For the moment Input Monitoring is granted while the app is already
    /// running. A tap created before the grant cannot be enabled and is
    /// thrown away, so nothing is listening afterwards — and nothing tells an
    /// app its permission changed, which is why this is driven by the app
    /// coming back to the front rather than by an event.
    func reinstall() {
        guard isRunning else { return }
        stop()
        start()
    }

    /// The kinds of keyboard event this monitor asks for, which is as few as
    /// the current settings allow.
    private var eventMask: CGEventMask {
        var mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        if soundsModifiers { mask |= 1 << CGEventType.flagsChanged.rawValue }
        if soundsRelease { mask |= 1 << CGEventType.keyUp.rawValue }
        return mask
    }

    /// Whether this process has already put the permission question to the
    /// user. Asked once per run, not once per attempt: the tap is reinstalled
    /// on every application switch, and a prompt on each of those would be
    /// unusable.
    private var hasAskedForPermission = false

    /// Lets the next `setRunning(true, …)` ask again.
    ///
    /// For deliberate acts — the Settings switch, the menu item. The latch is
    /// there so the app does not nag; someone reaching for the control is not
    /// the app.
    func askAgainOnNextStart() { hasAskedForPermission = false }

    /// Starts or stops to match `wanted`, and reports whether sound is now
    /// running. Idempotent, because it is called from every place the setting
    /// can change and from the launch path as well.
    @discardableResult
    func setRunning(_ wanted: Bool, soundsModifiers modifiers: Bool, soundsRelease release: Bool)
        -> Bool
    {
        // Asking is what registers the app in Input Monitoring and puts the
        // prompt on screen. The old `NSEvent` monitors got that for free —
        // installing one was itself the act that listed the app under
        // Accessibility — and moving to a tap lost it, because `tapCreate`
        // registers nothing. Without this, someone who had switched the
        // setting on and never opened Settings again got silence, no prompt,
        // and no entry in the list to switch on.
        if wanted, !hasAskedForPermission, !Self.isPermitted {
            hasAskedForPermission = true
            Self.requestPermission()
        }
        // One place asks, and this is it. The Settings switch and the menu item
        // used to call `requestPermission` themselves as well, which meant a
        // single toggle asked twice — harmless, since the system answers from
        // cache, and still two code paths for one decision. They call
        // `askAgainOnNextStart()` instead: the latch exists to ration the
        // *app* asking, not to ignore someone pressing a control.
        // A change of scope needs new monitors: which event kinds they watch
        // is fixed when they are installed.
        if isRunning, modifiers != soundsModifiers || release != soundsRelease { stop() }
        soundsModifiers = modifiers
        soundsRelease = release
        if wanted { start() } else { stop() }
        return isListening
    }

    /// Events from another application, which arrive whether or not the
    /// permission exists. Silent until all of them do, and silent in the
    /// places sound does not belong.
    private func handleGlobal(_ event: NSEvent) {
        guard Self.isPermitted else { return }
        // Muted means "make no sound", not "stop watching". The modifier
        // tracker infers press from release by comparing against the flags it
        // saw last, so an event dropped here leaves it believing a key is
        // still held: release shift inside a password manager, come back out,
        // press shift, and the transition test sees no change and stays
        // silent. Keeping the state current costs one assignment.
        if isMutedHere {
            if event.type == .flagsChanged { lastRawFlags = event.modifierFlags.rawValue }
            return
        }
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
            play(event.keyCode, .press)
        case .keyUp:
            // No `isARepeat` to check: a held key repeats its `keyDown` and
            // comes up exactly once, so the release is one sound however long
            // the key was held.
            play(event.keyCode, .release)
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
            // Latching: the key moved once, so it clicks once, and there is no
            // press-and-release pair to distinguish. It gets the press.
            play(event.keyCode, .press)
            return
        }
        let down = raw & mask != 0
        let wasDown = lastRawFlags & mask != 0
        guard down != wasDown else { return }
        // The direction was already being computed here; it was only ever used
        // to discard the release. Now it chooses which half to play.
        guard down || soundsRelease else { return }
        play(event.keyCode, down ? .press : .release)
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
    /// **Input Monitoring**, which is a change, and the second time this
    /// question has been answered differently. The app used to name Input
    /// Monitoring while calling an API gated on Accessibility, so the button
    /// led to a pane that stayed empty; that was corrected to Accessibility.
    /// Moving from `NSEvent.addGlobalMonitorForEvents` to `CGEventTap` moves
    /// it back — the tap is gated on Input Monitoring — and this time the name
    /// and the API agree.
    ///
    /// It is also the better of the two to ask for. Accessibility can drive
    /// other applications; Input Monitoring can only listen. Apple's own
    /// guidance is to ask for the narrower privilege when it will do, and a
    /// sandboxed app may hold this one at all, which is what makes an App
    /// Store build possible.
    ///
    /// The check matters because the failure is otherwise silent. `tapCreate`
    /// hands back a usable port without permission; it is the *enable* that
    /// fails, which is why `installGlobalMonitor` checks `tapIsEnabled` rather
    /// than trusting a non-nil port.
    static var isPermitted: Bool { CGPreflightListenEventAccess() }

    /// Asks the system for Input Monitoring, with its prompt.
    ///
    /// The prompt is what puts the app in front of the user with an "Open
    /// System Settings" button; the entry in the list is added by asking at
    /// all. macOS shows it only the first time a given process asks and
    /// answers from cache afterwards, which is why the caller also offers the
    /// System Settings door directly.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestListenEventAccess()
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
/// A `CGEventTap` callback is a C function pointer and cannot capture at all,
/// which is a stronger version of the same problem the `NSEvent` handlers had.
/// A
/// single main-actor-isolated reference is the cheapest way to get back to it
/// without weakening the isolation of `GlobalKeySound` itself — and "one at a
/// time" is not a limitation here, it is the requirement: two taps would
/// mean two clicks per keystroke.
@MainActor
enum KeySoundMonitors {
    static weak var shared: GlobalKeySound?
}

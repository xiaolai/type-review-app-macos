import Carbon.HIToolbox

/// A key combination that works when TYPE is not the front app.
///
/// `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`, and
/// the difference matters: the keystroke monitor needs Input Monitoring, which
/// means a trip to System Settings and a prompt that reads like the app wants
/// to watch everything you type. This app *is* a typing app, so that is the
/// last permission dialog it should ever raise. The Carbon call needs no
/// permission at all, because it registers one specific combination with the
/// window server rather than asking to see every key.
///
/// The API is C, which shapes the code: the handler is a static trampoline
/// because a C callback cannot capture, so registrations are kept in a table
/// keyed by the id the trampoline is handed.
@MainActor
final class GlobalHotKey {
    /// Live registrations, by the id passed back to the trampoline.
    private static var registry: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var ref: EventHotKeyRef?

    /// Registers `keyCode` with `modifiers` (Carbon masks — `cmdKey`,
    /// `optionKey`, `controlKey`, `shiftKey`). Returns nil when the
    /// combination is already spoken for by another app, which is not an
    /// error worth failing over: the menu item still works.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        // Before registering, not after. A hot key with no handler behind it
        // registers perfectly well and then does nothing when pressed — the
        // combination is claimed system-wide and silently dead, which is worse
        // than not claiming it.
        guard Self.installHandlerIfNeeded() else { return nil }
        id = Self.nextID
        Self.nextID += 1

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        // Exclusive, which is what the comment above already promised.
        // Registering with `0` asks for *non*-exclusive ownership: another
        // app's binding fires alongside this one, and an exclusive owner
        // elsewhere suppresses this one while registration still reports
        // success — the one outcome the nil return exists to rule out.
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKeyRef)
        guard status == noErr, let hotKeyRef else { return nil }
        ref = hotKeyRef
        Self.registry[id] = action
    }

    // No `deinit`. A nonisolated deinit cannot touch main-actor state, and
    // reaching for the Carbon handle from one is exactly the race the
    // compiler is describing. `unregister()` is the contract instead — and
    // the only instance lives as long as the app does, so the window in
    // which this matters is the app already being torn down.

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.registry[id] = nil
    }

    /// `'TYPE'`, the four-character signature this app's hot keys carry.
    private static let signature = OSType(0x5459_5045)

    /// Installs the shared Carbon handler, and says whether there is one.
    ///
    /// The status used to be discarded, so a failed installation left every
    /// subsequent registration reporting success over a hot key that could
    /// never fire.
    @discardableResult
    private static func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return status }
                // Ours, and one we still have. The signature check keeps this
                // handler from answering for another hot-key producer in the
                // same process, and reporting `noErr` for an event it did not
                // act on swallowed that other producer's key.
                guard hotKeyID.signature == GlobalHotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                // Carbon delivers this on the main thread, which is what the
                // application event target means. Asserting it is cheaper than
                // hopping, and it traps rather than racing if that ever stops
                // being true.
                return MainActor.assumeIsolated {
                    guard let action = GlobalHotKey.registry[hotKeyID.id] else {
                        return OSStatus(eventNotHandledErr)
                    }
                    action()
                    return noErr
                }
            }, 1, &spec, nil, &eventHandler)
        return eventHandler != nil
    }
}

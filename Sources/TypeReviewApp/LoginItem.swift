import AppKit
import ServiceManagement

/// Whether TYPE starts with the Mac.
///
/// The point of the setting is not convenience. Keystroke sound in every app
/// is only useful if it is there before you start typing, and an app you have
/// to remember to launch is one you will be typing in silence beside for the
/// first ten minutes of every day.
///
/// `SMAppService` rather than the deprecated shared-file-list API: since
/// Ventura an app registers its own login item, it appears under General ▸
/// Login Items with the app's own name, and the user can revoke it there.
///
/// That last part is why nothing here is mirrored into `UserDefaults`. The
/// system owns this state and the user can change it behind the app's back;
/// a cached copy would go on claiming the app starts at login after they
/// switched it off in System Settings.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Whether the user has asked for this, whether or not macOS has finished
    /// agreeing. `.requiresApproval` is a registration in flight, not an off
    /// state — a switch that shows it as off cannot be used to cancel it.
    static var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// The system's own word for where registration stands. Worth surfacing
    /// rather than reducing to a bool: `.requiresApproval` is not `.enabled`
    /// and not a failure either — it means macOS took the request and is
    /// waiting for the user to confirm it in System Settings, which is a
    /// different sentence than "it did not work".
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Throws rather than swallowing. An unsigned or relocated bundle can be
    /// refused registration, and a switch that silently slid back would be
    /// the worst version of that.
    static func setEnabled(_ enabled: Bool) throws {
        guard enabled else {
            // Unregistering something that was never registered is not a
            // failure worth reporting to anyone. A registration still awaiting
            // approval *is* unregistered, which is how the switch cancels it.
            guard status != .notRegistered, status != .notFound else { return }
            try SMAppService.mainApp.unregister()
            return
        }
        switch status {
        case .enabled:
            return
        case .requiresApproval:
            // Already registered and waiting on the user. Calling `register()`
            // again throws — and the caller would replace the "approve this in
            // System Settings" note with that error, which is the one message
            // that would have told them what to do.
            return
        default:
            try SMAppService.mainApp.register()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// True when launchd started this process at login rather than the user
    /// opening it.
    ///
    /// Read from the launch Apple event, which is the only place the
    /// distinction exists — `SMAppService` registers the app but passes no
    /// arguments, so there is nothing on the command line to look at. It has
    /// to be read early: `currentAppleEvent` is the event being dispatched
    /// right now, and by the time the app is idle there is no longer one.
    ///
    /// What it buys: starting at login should leave a menu-bar icon and a
    /// machine that clicks when you type, not a window across whatever you
    /// were about to do. Opening TYPE yourself still opens the window.
    static var launchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
            == keyAELaunchedAsLogInItem
    }
}

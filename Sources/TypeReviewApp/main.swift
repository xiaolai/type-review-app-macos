import AppKit

// Explicit setup rather than @main: the executable target is a plain SPM
// product, and the Makefile assembles the bundle around it.
let app = NSApplication.shared
// Before anything is built, and before any audio device or event tap is
// claimed. A second copy of this build has nothing to add and one thing to
// break — see `Channel.deferToRunningCopy`.
//
// The rule holds for a check too, and for a heavier reason than two event taps:
// both copies read and write the same profile on disk, so a check that records
// a run while the other copy saves over it has corrupted the thing it was
// running to verify. What a check must *not* do is the deferral itself —
// activating the copy already running throws that window to the front and takes
// the keyboard from whoever was using it, and then exits 0 with no output, so a
// check that never ran reads as one that passed.
if Diagnostics.isRunningCheck {
    if Channel.duplicate != nil {
        print("error: TYPE is already running — quit it before running a check")
        exit(2)
    }
} else if Channel.deferToRunningCopy() {
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
// Accessory for a check: no Dock tile, no menu bar, nothing that pulls focus
// away from whoever is using the machine. See `Diagnostics.isRunningCheck`.
app.setActivationPolicy(Diagnostics.isRunningCheck ? .accessory : .regular)
app.run()

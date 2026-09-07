import AppKit

// Explicit setup rather than @main: the executable target is a plain SPM
// product, and the Makefile assembles the bundle around it.
let app = NSApplication.shared
// Before anything is built, and before any audio device or event tap is
// claimed. A second copy of this build has nothing to add and one thing to
// break — see `Channel.deferToRunningCopy`.
if Channel.deferToRunningCopy() { exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

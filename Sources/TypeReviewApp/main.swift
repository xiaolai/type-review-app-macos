import AppKit

// Explicit setup rather than @main: the executable target is a plain SPM
// product, and the Makefile assembles the bundle around it.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

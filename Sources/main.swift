import AppKit

#if DEBUG
NotificationDeliverySelfCheck.installIfRequested()
#endif

// A main.swift file is the entry point, so no type in this target may use
// @main. The libghostty example app is structured the same way.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

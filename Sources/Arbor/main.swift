import AppKit

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// ARBOR_HEADLESS=1 runs scripted tests without a Dock icon or visible windows.
app.setActivationPolicy(ProcessInfo.processInfo.environment["ARBOR_HEADLESS"] == nil ? .regular : .accessory)
app.run()

import AppKit
import BetterExplorerCore

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// BETTER_EXPLORER_HEADLESS=1 runs scripted tests without a Dock icon or visible windows.
app.setActivationPolicy(Automation.environment["BETTER_EXPLORER_HEADLESS"] == nil ? .regular : .accessory)
app.run()

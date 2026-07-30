import Cocoa

// 必须强持有 AppDelegate 实例，否则会被立即释放
let appDelegate = AppDelegate.shared

let app = NSApplication.shared
app.delegate = appDelegate

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

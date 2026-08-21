import AppKit

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                      styleMask: [.titled, .closable],
                      backing: .buffered, defer: false)
window.title = "FlyCommander"
let label = NSTextField(labelWithString: "FlyCommander skeleton")
label.frame = NSRect(x: 40, y: 110, width: 400, height: 20)
window.contentView?.addSubview(label)
window.center()
window.makeKeyAndOrderFront(nil)
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()

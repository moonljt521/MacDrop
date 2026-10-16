import AppKit

// SPM 可执行目标没有 Info.plist 里的 NSPrincipalClass，
// 所以手写入口：先建 NSApplication，再挂 delegate。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
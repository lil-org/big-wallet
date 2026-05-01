// ∅ 2026 lil org

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    private let walletsManager = WalletsManager.shared
    private var quitKeyboardShortcutMonitor: Any?
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        installQuitKeyboardShortcutMonitor()
        agent.start(openOnLaunch: true)
        gasService.start()
        priceService.start()
        walletsManager.start()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.open()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let quitKeyboardShortcutMonitor {
            NSEvent.removeMonitor(quitKeyboardShortcutMonitor)
        }
    }

    private func installQuitKeyboardShortcutMonitor() {
        quitKeyboardShortcutMonitor = NSEvent.addCommandQShortcutMonitor { _ in
            NSApplication.shared.terminate(nil)
            return nil
        }
    }
    
}

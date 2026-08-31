// ∅ 2026 lil org

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    private let legacyAmbientHelperCleanup = LegacyAmbientHelperCleanup.live
    private let agent = Agent.shared
    private let priceService = PriceService.shared
    private let walletsManager = WalletsManager.shared
    private var quitKeyboardShortcutMonitor: Any?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // TODO: Remove this migration cleanup after one compatibility release.
        legacyAmbientHelperCleanup.run()
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        installQuitKeyboardShortcutMonitor()
        agent.open()
        priceService.start()
        walletsManager.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        walletsManager.handleExternalWalletStoreChange()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWallet()
        return true
    }

    @IBAction func openWallet(_ sender: Any?) {
        openWallet()
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

    private func openWallet() {
        let windows = NSApplication.shared.windows.filter {
            $0.contentViewController != nil && ($0.isVisible || $0.isMiniaturized)
        }
        guard !windows.isEmpty else {
            agent.open()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.deminiaturize(nil) }
        NSApp.arrangeInFront(nil)
    }

}

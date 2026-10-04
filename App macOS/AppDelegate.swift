// ∅ 2026 lil org

import Cocoa

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let priceService = PriceService.shared
    private let walletsManager = WalletsManager.shared
    private var quitKeyboardShortcutMonitor: Any?
    private var startupTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        clearAmbientPseudoLocalizationLaunchMode()
        return .terminateNow
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
#if DEBUG
        AmbientPseudoLocalizationLaunchMode.recordFromEnvironment()
#endif
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        installQuitKeyboardShortcutMonitor()
        priceService.start()
        startupTask = Task { [walletsManager, agent] in
            await walletsManager.start()
            guard !Task.isCancelled else { return }
            agent.open()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        foregroundTask?.cancel()
        foregroundTask = Task { [walletsManager] in
            await walletsManager.handleExternalWalletStoreChange()
            guard !Task.isCancelled else { return }
            await ExtensionBridge.shared.performMaintenance()
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWallet()
        return true
    }

    @IBAction func openWallet(_ sender: Any?) {
        openWallet()
    }

    func applicationWillTerminate(_ notification: Notification) {
        startupTask?.cancel()
        foregroundTask?.cancel()
        clearAmbientPseudoLocalizationLaunchMode()
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

    private func clearAmbientPseudoLocalizationLaunchMode() {
#if DEBUG
        AmbientPseudoLocalizationLaunchMode.clear()
#endif
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

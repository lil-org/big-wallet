// ∅ 2026 lil org

import Cocoa

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private lazy var agent = Agent.shared
    private lazy var priceService = PriceService.shared
    private lazy var walletsManager = WalletsManager.shared
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
        guard !isTestHost else { return }
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
        guard !isTestHost else { return }
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        agent.applicationDidBecomeActive()
        foregroundTask?.cancel()
        foregroundTask = Task { [walletsManager] in
            await walletsManager.handleExternalWalletStoreChange()
            guard !Task.isCancelled else { return }
            await ExtensionBridge.shared.performMaintenance()
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTestHost else { return false }
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
        guard !isTestHost else { return }
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
        windows.filter(\.isMiniaturized).forEach { $0.deminiaturize(nil) }
        NSApp.arrangeInFront(nil)
    }
    
}

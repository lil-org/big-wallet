import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private lazy var agent = Agent.shared
    private lazy var priceService = ApplicationServices.shared.prices
    private lazy var walletsManager = ApplicationServices.shared.wallets
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
#if BW_SAFARI_VM_TESTING
        if let preparation = SafariVMFixtures.shared.activationPreparation {
            installQuitKeyboardShortcutMonitor()
            startupTask = Agent.prepareSafariVMExtension(preparation)
            return
        }
#endif
#if DEBUG
        AmbientPseudoLocalizationLaunchMode.recordFromEnvironment()
#endif
        ApplicationServices.shared.prewarm()
        installQuitKeyboardShortcutMonitor()
        priceService.start()
        startupTask = Task { [walletsManager, agent] in
            await walletsManager.start()
#if BW_SAFARI_VM_TESTING
            await SafariVMMutations.shared.processPending()
#endif
            guard !Task.isCancelled else { return }
            agent.open()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTestHost else { return }
#if BW_SAFARI_VM_TESTING
        guard SafariVMFixtures.shared.activationPreparation == nil else { return }
#endif
        ApplicationServices.shared.prewarm()
        agent.applicationDidBecomeActive()
        foregroundTask?.cancel()
        foregroundTask = Task { [walletsManager] in
            _ = await walletsManager.reloadFromStore()
#if BW_SAFARI_VM_TESTING
            await SafariVMMutations.shared.processPending()
#endif
            guard !Task.isCancelled else { return }
            await ApplicationServices.shared.requests.performMaintenance()
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTestHost else { return false }
#if BW_SAFARI_VM_TESTING
        guard SafariVMFixtures.shared.activationPreparation == nil else { return false }
#endif
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
#if BW_SAFARI_VM_TESTING
        guard SafariVMFixtures.shared.activationPreparation == nil else { return }
#endif
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

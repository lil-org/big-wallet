// ∅ 2026 lil org

import Cocoa
import Darwin

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let priceService = PriceService.shared
    private let walletsManager = WalletsManager.shared
    private let ambientTerminationRequestId = UUID().uuidString
    private var quitKeyboardShortcutMonitor: Any?
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        clearAmbientPseudoLocalizationLaunchMode()
        terminateAmbientHelpers()
        return .terminateNow
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
#if DEBUG
        AmbientPseudoLocalizationLaunchMode.recordFromEnvironment()
#endif
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
        installQuitKeyboardShortcutMonitor()
        agent.start(openOnLaunch: true)
        priceService.start()
        walletsManager.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWallet()
        return true
    }

    @IBAction func openWallet(_ sender: Any?) {
        openWallet()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clearAmbientPseudoLocalizationLaunchMode()
        terminateAmbientHelpers()
        if let quitKeyboardShortcutMonitor {
            NSEvent.removeMonitor(quitKeyboardShortcutMonitor)
        }
    }

    private func installQuitKeyboardShortcutMonitor() {
        quitKeyboardShortcutMonitor = NSEvent.addCommandQShortcutMonitor { _ in
            self.terminateAmbientHelpers()
            NSApplication.shared.terminate(nil)
            return nil
        }
    }

    private func terminateAmbientHelpers() {
        DistributedNotificationCenter.default().postNotificationName(.ambientAgentMustTerminate,
                                                                     object: ambientTerminationRequestId,
                                                                     userInfo: AmbientAgentTerminationRequest.notificationUserInfo(from: AmbientAgentTerminationRequest.userInfo(for: .main)),
                                                                     deliverImmediately: true)
        NSRunningApplication.runningApplications(withBundleIdentifier: Identifiers.macOSAmbientBundle).forEach {
            _ = Darwin.kill($0.processIdentifier, SIGKILL)
            _ = $0.forceTerminate()
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

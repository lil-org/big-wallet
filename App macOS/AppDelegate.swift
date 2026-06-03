// ∅ 2026 lil org

import Cocoa
import Darwin

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    private let walletsManager = WalletsManager.shared
    private let ambientTerminationRequestId = UUID().uuidString
    private var quitKeyboardShortcutMonitor: Any?
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminateAmbientHelpers()
        return .terminateNow
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
    
}

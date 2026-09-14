// ∅ 2026 lil org

import Cocoa
import OSLog

@main
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private static let logger = Logger(subsystem: "org.lil.wallet", category: "AmbientLifecycle")

    static func main() {
#if DEBUG
        AmbientPseudoLocalizationLaunchMode.applyToAmbientProcess()
#endif
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

    private let agent = Agent.shared
    private let walletsManager = WalletsManager.shared
    private let runtimeIdentity = AmbientRuntimeIdentity.current()

    private var commandQBlockerMonitor: Any?
    private var allowsProgrammaticTermination = false

    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(getURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func getURL(_ event: NSAppleEventDescriptor,
                              withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(
            forKeyword: keyDirectObject
        )?.stringValue, let url = URL(string: value) else { return }
        _ = processInput(url: url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prewarmAlchemy()
        installCommandQBlocker()
        guard let runtimeIdentity else {
            Self.logger.error("Cannot establish helper runtime identity")
            allowsProgrammaticTermination = true
            NSApplication.shared.terminate(nil)
            return
        }
        guard runtimeIdentity.persist() else {
            Self.logger.error("Cannot persist helper runtime identity")
            allowsProgrammaticTermination = true
            NSApplication.shared.terminate(nil)
            return
        }
        agent.start(
            openOnLaunch: false,
            runtimeIdentity: runtimeIdentity
        )
        walletsManager.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        prewarmAlchemy()
        agent.applicationDidBecomeActive()
    }

    func application(_ application: NSApplication,
                     open urls: [URL]) {
        urls.forEach { _ = processInput(url: $0) }
    }

    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard let url = userActivity.webpageURL else { return false }
        return processInput(url: url)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !allowsProgrammaticTermination else { return .terminateNow }
        return NSApp.currentEvent?.isCommandQShortcut == true ? .terminateCancel : .terminateNow
    }

    @IBAction func openWallet(_ sender: Any?) {
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(openWallet(_:)) else { return true }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = runtimeIdentity?.clear()
        if let commandQBlockerMonitor {
            NSEvent.removeMonitor(commandQBlockerMonitor)
        }
    }

    private func processInput(url: URL) -> Bool {
        guard let route = NativeAgentRoute(url: url) else { return false }
        process(route: route)
        return true
    }

    private func process(route: NativeAgentRoute) {
        prewarmAlchemy()
        agent.process(route: route)
    }

    private func prewarmAlchemy() {
        AlchemyJWTProvider.prewarmForApplicationLifecycle()
    }

    private func installCommandQBlocker() {
        commandQBlockerMonitor = NSEvent.addCommandQShortcutMonitor { _ in
            NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            return nil
        }
    }

}

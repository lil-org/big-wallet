// ∅ 2026 lil org

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private let agent = Agent.shared
    private let walletsManager = WalletsManager.shared
    private let currentInstanceId = UUID().uuidString

    private var didFinishLaunching = false
    private var initialExternalRequest: Agent.ExternalRequest?

    override init() {
        super.init()
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(self, andSelector: #selector(self.getUrl(_:withReplyEvent:)),
                                forEventClass: AEEventClass(kInternetEventClass),
                                andEventID: AEEventID(kAEGetURL))
    }

    @objc private func getUrl(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        _ = processInput(url: event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        agent.start(openOnLaunch: false)
        walletsManager.start()

        didFinishLaunching = true

        if let externalRequest = initialExternalRequest {
            initialExternalRequest = nil
            agent.showInitialScreen(externalRequest: externalRequest)
        }

        DistributedNotificationCenter.default().post(name: .ambientAgentMustTerminate, object: currentInstanceId)
        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(terminateInstance(_:)),
                                                            name: .ambientAgentMustTerminate,
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        return processInput(url: userActivity.webpageURL?.absoluteString)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    private func processInput(url: String?) -> Bool {
        guard let url = url, let request = SafariRequest(appRequestURLString: url) else { return false }
        processExternalRequest(.safari(request))
        return true
    }

    private func processExternalRequest(_ externalRequest: Agent.ExternalRequest) {
        if didFinishLaunching {
            agent.showInitialScreen(externalRequest: externalRequest)
        } else {
            initialExternalRequest = externalRequest
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self, name: .ambientAgentMustTerminate, object: nil)
    }

    @objc private func terminateInstance(_ notification: Notification) {
        guard let senderId = notification.object as? String, senderId != currentInstanceId else { return }
        NSApplication.shared.terminate(nil)
    }

}

private extension Notification.Name {

    static let ambientAgentMustTerminate = Notification.Name("org.lil.wallet.ambient.terminateOtherInstances")

}

// ∅ 2026 lil org

import Cocoa
import Darwin
import Security

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private let agent = Agent.shared
    private let walletsManager = WalletsManager.shared
    private let currentInstanceId = UUID().uuidString
    private let versionInfo = AmbientAgentTerminationRequest.userInfo(for: .main)

    private var didFinishLaunching = false
    private var initialExternalRequest: Agent.ExternalRequest?
    private var commandQBlockerMonitor: Any?
    private var allowsProgrammaticTermination = false

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
        prewarmAlchemy()
        installCommandQBlocker()
        agent.start(openOnLaunch: false)
        walletsManager.start()

        didFinishLaunching = true

        if let externalRequest = initialExternalRequest {
            initialExternalRequest = nil
            agent.showInitialScreen(externalRequest: externalRequest)
        }

        DistributedNotificationCenter.default().addObserver(self,
                                                            selector: #selector(terminateInstance(_:)),
                                                            name: .ambientAgentMustTerminate,
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(terminateIfDockAppTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
        DistributedNotificationCenter.default().post(name: .ambientAgentMustTerminate,
                                                      object: currentInstanceId,
                                                      userInfo: AmbientAgentTerminationRequest.notificationUserInfo(from: versionInfo))
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        prewarmAlchemy()
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        return processInput(url: userActivity.webpageURL?.absoluteString)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !allowsProgrammaticTermination else { return .terminateNow }
        return NSApp.currentEvent?.isCommandQShortcut == true ? .terminateCancel : .terminateNow
    }

    @IBAction func openWallet(_ sender: Any?) {
        // Disabled for the ambient helper by validateMenuItem(_:).
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(openWallet(_:)) else { return true }
        return false
    }

    private func processInput(url: String?) -> Bool {
        guard let url = url, let request = SafariRequest(appRequestURLString: url) else { return false }
        guard !handOffToNewerAmbientIfNeeded(request, requestURLString: url) else { return true }

        processExternalRequest(.safari(request))
        return true
    }

    private func handOffToNewerAmbientIfNeeded(_ request: SafariRequest, requestURLString: String) -> Bool {
#if DEBUG
        return false
#else
        guard let replacementURL = newerAmbientBundleURL(for: request),
              let requestURL = URL(string: requestURLString) else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.open([requestURL], withApplicationAt: replacementURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil {
                    self.processExternalRequest(.safari(request))
                    return
                }
                self.allowsProgrammaticTermination = true
                NSApplication.shared.terminate(nil)
            }
        }
        return true
#endif
    }

    private func newerAmbientBundleURL(for request: SafariRequest) -> URL? {
#if DEBUG
        return nil
#else
        guard ExtensionBridge.hasPendingRequest(id: request.id),
              let replacementURL = replacementAmbientBundleURL(from: request.ambientAgent),
              let bundleIdentifier = Bundle.main.bundleIdentifier,
              let replacementBundleInfo = AmbientAgentTerminationRequest.bundleInfo(forBundleAt: replacementURL),
              replacementBundleInfo.identifier == bundleIdentifier,
              AmbientAgentTerminationRequest.isNewer(replacementBundleInfo.versionInfo, than: versionInfo),
              replacementAmbientBundleSatisfiesCurrentSignatureRequirement(replacementURL) else {
            return nil
        }
        if let ambientAgent = request.ambientAgent,
           !AmbientAgentTerminationRequest.matches(ambientAgent, versionInfo: replacementBundleInfo.versionInfo) {
            return nil
        }

        return replacementURL
#endif
    }

    private func replacementAmbientBundleSatisfiesCurrentSignatureRequirement(_ replacementURL: URL) -> Bool {
#if DEBUG
        return true
#else
        guard let currentCode = staticCode(at: Bundle.main.bundleURL),
              let replacementCode = staticCode(at: replacementURL),
              let requirement = designatedRequirement(for: currentCode) else {
            return false
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(replacementCode, flags, requirement) == errSecSuccess
#endif
    }

    private func staticCode(at url: URL) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess else { return nil }
        return staticCode
    }

    private func designatedRequirement(for code: SecStaticCode) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement)
        guard status == errSecSuccess else { return nil }
        return requirement
    }

    private func replacementAmbientBundleURL(from ambientAgent: [String: String]?) -> URL? {
        guard let ambientAgent else { return Bundle.main.bundleURL.standardizedFileURL }
        guard let url = AmbientAgentTerminationRequest.bundleURL(from: ambientAgent)?.standardizedFileURL,
              isEmbeddedAmbientBundleURL(url) else {
            return nil
        }
        return url
    }

    private func isEmbeddedAmbientBundleURL(_ url: URL) -> Bool {
        let helpersURL = url.deletingLastPathComponent()
        let contentsURL = helpersURL.deletingLastPathComponent()
        let containingAppURL = contentsURL.deletingLastPathComponent()

        return url.lastPathComponent == Bundle.main.bundleURL.lastPathComponent
            && helpersURL.lastPathComponent == "Helpers"
            && contentsURL.lastPathComponent == "Contents"
            && containingAppURL.pathExtension == "app"
    }

    private func processExternalRequest(_ externalRequest: Agent.ExternalRequest) {
        if didFinishLaunching {
            prewarmAlchemy()
            agent.showInitialScreen(externalRequest: externalRequest)
        } else {
            initialExternalRequest = externalRequest
        }
    }

    private func prewarmAlchemy() {
        _ = AlchemyJWTProvider.prewarmForApplicationLifecycle()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if let commandQBlockerMonitor {
            NSEvent.removeMonitor(commandQBlockerMonitor)
        }
        DistributedNotificationCenter.default().removeObserver(self, name: .ambientAgentMustTerminate, object: nil)
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    @objc private func terminateInstance(_ notification: Notification) {
        guard let senderId = notification.object as? String, senderId != currentInstanceId else { return }
        guard let senderVersionInfo = AmbientAgentTerminationRequest.userInfo(in: notification.userInfo),
              shouldTerminate(forSenderVersionInfo: senderVersionInfo) else {
            return
        }

        allowsProgrammaticTermination = true
        NSApplication.shared.terminate(nil)
    }

    @objc private func terminateIfDockAppTerminated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.bundleIdentifier == Identifiers.macOSAppBundle else {
            return
        }

        Darwin.exit(0)
    }

    private func shouldTerminate(forSenderVersionInfo senderVersionInfo: [String: String]) -> Bool {
        return AmbientAgentTerminationRequest.isNewer(senderVersionInfo, than: versionInfo)
            || AmbientAgentTerminationRequest.isSameBuild(senderVersionInfo, as: versionInfo)
    }

    private func installCommandQBlocker() {
        commandQBlockerMonitor = NSEvent.addCommandQShortcutMonitor { _ in
            NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
            return nil
        }
    }

}

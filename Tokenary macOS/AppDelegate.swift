// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    private let configurationService = ConfigurationService.shared
    private let walletsManager = WalletsManager.shared
    
    private var didFinishLaunching = false
    private var initialExternalRequest: Agent.ExternalRequest?
    
    override init() {
        super.init()
        let manager = NSAppleEventManager.shared()
        manager.setEventHandler(self, andSelector: #selector(self.getUrl(_:withReplyEvent:)),
                                forEventClass: AEEventClass(kInternetEventClass),
                                andEventID: AEEventID(kAEGetURL))
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    @objc private func getUrl(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        processInput(url: event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue)
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {        
        agent.start()
        gasService.start()
        priceService.start()
        walletsManager.start()
        configurationService.check()
        
        didFinishLaunching = true
        
        if let externalRequest = initialExternalRequest {
            initialExternalRequest = nil
            agent.showInitialScreen(externalRequest: externalRequest)
        }
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.open()
        return true
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        processInput(url: userActivity.webpageURL?.absoluteString)
        return true
    }
    
    private func processInput(url: String?) {
        guard let url = url else { return }
        let safariPrefix = "tokenary://safari?request="
        if url.hasPrefix(safariPrefix), let request = SafariRequest(query: String(url.dropFirst(safariPrefix.count))) {
            processExternalRequest(.safari(request))
        }
    }
    
    private func processExternalRequest(_ externalRequest: Agent.ExternalRequest) {
        if didFinishLaunching {
            agent.showInitialScreen(externalRequest: externalRequest)
        } else {
            initialExternalRequest = externalRequest
        }
    }
    
}

// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    private let networkMonitor = NetworkMonitor.shared
    private let walletsManager = WalletsManager.shared
    
    private var didFinishLaunching = false
    private var initialInputLink: String?
    
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
        processInput(url: event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, prefix: "encryptedink://wc?uri=")
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        agent.start()
        gasService.start()
        priceService.start()
        networkMonitor.start()
        walletsManager.start()
        
        didFinishLaunching = true
        if let link = initialInputLink {
            initialInputLink = nil
            agent.processInputLink(link)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.reopen()
        return true
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        processInput(url: userActivity.webpageURL?.absoluteString, prefix: "https://encrypted.ink/wc?uri=")
        return true
    }
    
    private func processInput(url: String?, prefix: String) {
        if let url = url, url.hasPrefix(prefix),
           let link = url.dropFirst(prefix.count).removingPercentEncoding {
            if didFinishLaunching {
                agent.processInputLink(link)
            } else {
                initialInputLink = link
            }
        }
    }
    
}

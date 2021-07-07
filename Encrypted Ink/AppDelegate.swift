// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    private let gasService = GasService.shared
    private let priceService = PriceService.shared
    
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
        if let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue {
            // TODO: handle all kinds of deep link
            // TODO: do something if could not parse input link
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        agent.start()
        gasService.start()
        priceService.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agent.reopen()
        return true
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        let prefix = "https://encrypted.ink/wc?uri="
        if let url = userActivity.webpageURL?.absoluteString, url.hasPrefix(prefix),
           let link = url.dropFirst(prefix.count).removingPercentEncoding {
            agent.processInputLink(link)
        }
        // TODO: do something if could not parse input link
        return true
    }
    
}

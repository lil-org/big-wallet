// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    private let agent = Agent.shared
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        agent.start()
        agent.setupStatusBarItem()
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
    
    @IBAction func didCmdQ(_ sender: Any) {
        Window.closeAll()
        agent.warnBeforeQuitting()
    }
    
}

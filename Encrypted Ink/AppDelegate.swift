// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    let agent = Agent()
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        agent.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // TODO: reopen correct screen
        print("applicationShouldHandleReopen")
        return true
    }
    
}

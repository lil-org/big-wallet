// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        Agent.shared.start()
        Agent.shared.setupStatusBarItem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Agent.shared.reopen()
        return true
    }
    
}

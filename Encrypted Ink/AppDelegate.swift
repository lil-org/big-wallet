// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let account = Account(privateKey: "0x2a7dbf050e133cf172681ca7ca77554179b4c74d1b529dac5534cc35782c7ce3")
        print("@@ signed", try! Ethereum.signPersonal(message: "My email is john@doe.com - 1537836206101", account: account))
        
        // Insert code here to initialize your application
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

}

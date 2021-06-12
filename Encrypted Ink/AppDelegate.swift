// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    private var connectivity: NearbyConnectivity?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let account = Account(privateKey: "0x2a7dbf050e133cf172681ca7ca77554179b4c74d1b529dac5534cc35782c7ce3")
        print("@@ signed", try! Ethereum.signPersonal(message: "My email is john@doe.com - 1537836206101", account: account))
        
        connectivity = NearbyConnectivity(delegate: self)
    }

}

private func showScreen() {
    NSApplication.shared.windows.forEach { $0.close() }
    let storyboard = NSStoryboard(name: "Main", bundle: nil)
    let windowController = storyboard.instantiateInitialController() as? NSWindowController
    windowController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    windowController?.window?.makeKeyAndOrderFront(nil)
}

extension AppDelegate: NearbyConnectivityDelegate {
    
    func didFind(link: String) {
        showScreen()
    }
    
}

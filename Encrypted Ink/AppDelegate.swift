// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var connectivity: NearbyConnectivity?
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
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

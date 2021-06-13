// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

struct Window {
    
    static func showNew() -> NSWindowController {
        closeAll()
        let windowController = new
        activate(windowController)
        return windowController
    }
    
    static func activate(_ windowController: NSWindowController) {
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
    
    static func closeAll() {
        NSApplication.shared.windows.forEach { $0.close() }
    }
    
    static func activateSafari() {
        if let browser = NSWorkspace().runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Safari" }) {
            browser.activate(options: .activateIgnoringOtherApps)
        }
    }
    
    static var current: NSWindowController? {
        return NSApplication.shared.windows.first?.windowController
    }
    
    static var new: NSWindowController {
        return NSStoryboard.main.instantiateInitialController() as! NSWindowController
    }
    
}

extension NSStoryboard {
    static let main = NSStoryboard(name: "Main", bundle: nil)
}

func instantiate<ViewController: NSViewController>(_ type: ViewController.Type) -> ViewController {
    return NSStoryboard.main.instantiateController(withIdentifier: String(describing: type)) as! ViewController
}

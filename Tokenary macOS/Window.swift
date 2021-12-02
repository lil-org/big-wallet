// Copyright © 2021 Tokenary. All rights reserved.

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
        activateWindow(windowController.window)
    }
    
    static func activateWindow(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    
    static func closeAllAndActivateBrowser(force browser: Browser?) {
        closeAll()
        activateBrowser(force: browser)
    }
    
    static func closeAll(updateStatusBarItem: Bool = true) {
        NSApplication.shared.windows.forEach { $0.close() }
        if updateStatusBarItem {
            Agent.shared.setupStatusBarItem()
        }
    }
    
    static func activateBrowser(force browser: Browser?) {
        if let browser = browser {
            activateBrowser(browser)
            return
        }
        
        let browsers = NSWorkspace.shared.runningApplications.filter { app in
            if let bundleId = app.bundleIdentifier {
                return Browser.allBundleIds.contains(bundleId)
            } else {
                return false
            }
        }
        
        guard !browsers.isEmpty else { return }
        
        let browsersPids = Set(browsers.map { $0.processIdentifier })
        let options = CGWindowListOption(arrayLiteral: [.excludeDesktopElements, .optionOnScreenOnly])
        guard let windows = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [[String: AnyObject]] else { return }
        for window in windows {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, browsersPids.contains(pid) {
                browsers.first(where: { $0.processIdentifier == pid })?.activate(options: .activateIgnoringOtherApps)
                return
            }
        }
    }
    
    private static func activateBrowser(_ browser: Browser) {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == browser.rawValue })?.activate(options: .activateIgnoringOtherApps)
    }
    
    static var current: NSWindowController? {
        return NSApplication.shared.windows.first?.windowController
    }
    
    static var new: NSWindowController {
        return NSStoryboard.main.instantiateController(withIdentifier: "initial") as! NSWindowController
    }
    
}

extension NSStoryboard {
    static let main = NSStoryboard(name: "Main", bundle: nil)
}

func instantiate<ViewController: NSViewController>(_ type: ViewController.Type) -> ViewController {
    return NSStoryboard.main.instantiateController(withIdentifier: String(describing: type)) as! ViewController
}

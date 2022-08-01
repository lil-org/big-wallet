// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa

struct Window {
    
    static func showNew(closeOthers: Bool) -> NSWindowController {
        if closeOthers {
            closeAll()
        }
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
    
    static func closeWindow(idToClose: Int?) {
        if let id = idToClose, let windowToClose = NSApplication.shared.windows.first(where: { $0.windowNumber == id }) {
            windowToClose.close()
        }
    }
    
    static func closeWindowAndActivateNext(idToClose: Int?, specificBrowser: Browser?) {
        closeWindow(idToClose: idToClose)
        
        if let window = NSApplication.shared.windows.last(where: { $0.windowNumber != idToClose && $0.isOnActiveSpace && $0.contentViewController != nil }) {
            activateWindow(window)
        } else {
            activateBrowser(specific: specificBrowser)
        }
    }
    
    static func closeAllAndActivateBrowser(specific browser: Browser?) {
        closeAll()
        activateBrowser(specific: browser)
    }
    
    // MARK: - Private
    
    private static func closeAll() {
        NSApplication.shared.windows.forEach { $0.close() }
        Agent.shared.setupStatusBarItem()
    }
    
    private static func activateBrowser(specific browser: Browser?) {
        if let browser = browser, browser != .unknown {
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
    
    private static var new: NSWindowController {
        return NSStoryboard.main.instantiateController(withIdentifier: "initial") as! NSWindowController
    }
    
}

extension NSStoryboard {
    static let main = NSStoryboard(name: "Main", bundle: nil)
}

func instantiate<ViewController: NSViewController>(_ type: ViewController.Type) -> ViewController {
    return NSStoryboard.main.instantiateController(withIdentifier: String(describing: type)) as! ViewController
}

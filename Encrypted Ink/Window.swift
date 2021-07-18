// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

struct Window {
    
    private static let browsersBundleIds = Set([
        "com.apple.Safari",
        "com.google.Chrome",
        "org.torproject.torbrowser",
        "com.operasoftware.Opera",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "com.vivaldi.Vivaldi",
        "ru.yandex.desktop.yandex-browser"
    ])
    
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
    
    static func closeAllAndActivateBrowser() {
        closeAll()
        activateBrowser()
    }
    
    static func closeAll(updateStatusBarItem: Bool = true) {
        NSApplication.shared.windows.forEach { $0.close() }
        if updateStatusBarItem {
            Agent.shared.setupStatusBarItem()
        }
    }
    
    static func activateBrowser() {
        let browsers = NSWorkspace.shared.runningApplications.filter { app in
            if let bundleId = app.bundleIdentifier {
                return browsersBundleIds.contains(bundleId)
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

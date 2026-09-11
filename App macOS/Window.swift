// ∅ 2026 lil org

import Cocoa

final class WalletWindowController: NSWindowController {
    var approvalPeer: PeerMeta?
}

struct Window {
    
    private static var isClosingAllWindows = false
    
    static func showNew(
        closeOthers: Bool,
        approvalPeer: PeerMeta? = nil
    ) -> WalletWindowController {
        if closeOthers {
            closeAll()
        }
        
        let windowController = new
        windowController.approvalPeer = approvalPeer
        activate(windowController)
        
        if !closeOthers {
            if let frame = windowController.window?.frame {
                let stepX: CGFloat = 18
                let stepY: CGFloat = 16
                
                let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
                var validCascadeIndexes = [Int]()
                
                let validateActiveSpace = windowController.window?.isOnActiveSpace == true
                for otherWindow in NSApplication.shared.windows where
                    otherWindow !== windowController.window &&
                    isVisibleContentWindow(otherWindow) {
                    if validateActiveSpace, !otherWindow.isOnActiveSpace { continue }
                    let otherTopLeft = CGPoint(x: otherWindow.frame.minX, y: otherWindow.frame.maxY)
                    
                    let deltaX = otherTopLeft.x - topLeft.x
                    let deltaY = otherTopLeft.y - topLeft.y
                    
                    if deltaX.truncatingRemainder(dividingBy: stepX).isZero, deltaY.truncatingRemainder(dividingBy: stepY).isZero {
                        let xIndex = deltaX / stepX
                        let yIndex = deltaY / stepY
                        if xIndex == yIndex {
                            validCascadeIndexes.append(Int(xIndex))
                        }
                    }
                }
                
                if let previousCascadeIndex = validCascadeIndexes.max() {
                    let cascadeIndex = CGFloat(previousCascadeIndex + 1)
                    let newTopLeft = CGPoint(x: topLeft.x + stepX * cascadeIndex, y: topLeft.y + stepY * cascadeIndex)
                    windowController.window?.setFrameTopLeftPoint(newTopLeft)
                }
            }
        }
        
        return windowController
    }
    
    static private func activate(_ windowController: NSWindowController) {
        windowController.showWindow(nil)
        activateWindow(windowController.window)
    }
    
    static func activateWindow(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    
    static func reactivateWindow(_ windowController: NSWindowController) {
        windowController.showWindow(nil)
        windowController.window?.deminiaturize(nil)
        activateWindow(windowController.window)
    }

    static func isVisibleContentWindow(_ window: NSWindow) -> Bool {
        window.contentViewController != nil &&
            (window.isVisible || window.isMiniaturized)
    }

    static func closeWindow(idToClose: Int?) {
        guard !isClosingAllWindows else { return }
        if let id = idToClose, let windowToClose = NSApplication.shared.windows.first(where: { $0.windowNumber == id }) {
            windowToClose.close()
        }
    }
    
    static func closeWindowAndActivateNext(idToClose: Int?, specificBrowser: Browser?) {
        guard !isClosingAllWindows else { return }
        closeWindow(idToClose: idToClose)
        
        if let window = NSApplication.shared.windows.last(where: {
            $0.windowNumber != idToClose &&
                $0.isOnActiveSpace &&
                isVisibleContentWindow($0)
        }) {
            activateWindow(window)
        } else {
            activateBrowser(specific: specificBrowser)
        }
    }
    
    private static func closeAll() {
        isClosingAllWindows = true
        NSApplication.shared.windows.filter(isVisibleContentWindow).forEach { window in
            window.close()
        }
        isClosingAllWindows = false
    }
    
    static func activateBrowser(specific browser: Browser?) {
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
                browsers.first(where: { $0.processIdentifier == pid })?.activate()
                return
            }
        }
    }
    
    private static func activateBrowser(_ browser: Browser) {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == browser.rawValue })?.activate()
    }
    
    private static var new: WalletWindowController {
        return NSStoryboard.main.instantiateController(
            withIdentifier: "initial"
        ) as! WalletWindowController
    }
    
}

extension NSStoryboard {
    static let main = NSStoryboard(name: "Main", bundle: nil)
}

func instantiate<ViewController: NSViewController>(_ type: ViewController.Type) -> ViewController {
    return NSStoryboard.main.instantiateController(withIdentifier: String(describing: type)) as! ViewController
}

// ∅ 2026 lil org

import Cocoa

struct Window {
    
    private static var isClosingAllWindows = false
    
    static func showNew(closeOthers: Bool) -> NSWindowController {
        if closeOthers {
            closeAll()
        }
        
        let windowController = new
        activate(windowController)
        
        if !closeOthers {
            if let frame = windowController.window?.frame {
                let stepX: CGFloat = 18
                let stepY: CGFloat = 16
                
                let topLeft = CGPoint(x: frame.minX, y: frame.maxY)
                var validCascadeIndexes = [Int]()
                
                let validateActiveSpace = windowController.window?.isOnActiveSpace == true
                for otherWindow in NSApplication.shared.windows where otherWindow !== windowController.window {
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
    
    static func closeWindow(idToClose: Int?) {
        guard !isClosingAllWindows else { return }
        if let id = idToClose, let windowToClose = NSApplication.shared.windows.first(where: { $0.windowNumber == id }) {
            windowToClose.close()
        }
    }
    
    private static func closeAll() {
        isClosingAllWindows = true
        NSApplication.shared.windows.forEach { window in
            window.close()
        }
        isClosingAllWindows = false
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

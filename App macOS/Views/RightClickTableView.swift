// ∅ 2026 lil org

import Cocoa

class RightClickTableView: NSTableView {
    
    weak var menuSource: TableViewMenuSource?
    var deselectedRow = -1
    var keyboardActivation: (() -> Void)?
    private(set) var isHandlingKeyDown = false

    override func keyDown(with event: NSEvent) {
        if activateFromKeyboard(event) { return }
        isHandlingKeyDown = true
        defer { isHandlingKeyDown = false }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, activateFromKeyboard(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func activateFromKeyboard(_ event: NSEvent) -> Bool {
        guard isEnabled,
              [36, 49, 76].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let keyboardActivation else { return false }
        if !event.isARepeat {
            keyboardActivation()
        }
        return true
    }
    
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        if index >= 0, let menu = menuSource?.menuForRow(index) {
            selectRowIndexes([index], byExtendingSelection: true)
            return menu
        } else {
            return nil
        }
    }
    
}

protocol TableViewMenuSource: AnyObject {
    
    func menuForRow(_ row: Int) -> NSMenu?
    
}

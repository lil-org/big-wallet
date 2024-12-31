// ∅ 2025 lil org

import Cocoa

extension NSTableView {
    
    func makeViewOfType<RowView: NSTableRowView>(_ type: RowView.Type, owner: Any?) -> RowView {
        return makeView(withIdentifier: NSUserInterfaceItemIdentifier(String(describing: type)), owner: self) as! RowView
    }
    
}

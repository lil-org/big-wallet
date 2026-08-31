// ∅ 2026 lil org

import Cocoa

extension NSViewController {

    func endAllSheets() {
        if let sheets = view.window?.sheets, !sheets.isEmpty {
            for sheet in sheets {
                view.window?.endSheet(sheet)
            }
        }
    }

}

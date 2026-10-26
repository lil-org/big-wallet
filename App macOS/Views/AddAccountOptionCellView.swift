import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa

class AddAccountOptionCellView: NSTableRowView {

    @IBOutlet weak var titleLabel: NSTextField!
    
    func setup(title: String) {
        titleLabel.stringValue = title
    }
    
}

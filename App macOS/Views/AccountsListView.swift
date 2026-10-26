import WalletDomain
import WalletAuthority
import WalletNetworking
import Cocoa

final class AccountsListView: NSView {
    @IBOutlet weak var addButton: NSButton!
    @IBOutlet weak var secondaryButton: NSButton!
    @IBOutlet weak var primaryButton: NSButton!
    @IBOutlet weak var bottomButtonsStackView: NSStackView!
    @IBOutlet weak var accountsListBottomConstraint: NSLayoutConstraint!
    @IBOutlet weak var titleLabelTopConstraint: NSLayoutConstraint!
    @IBOutlet weak var websiteNameStackView: NSStackView!
    @IBOutlet weak var websiteNameLabel: NSTextField!
    @IBOutlet weak var networkButton: NSButton!
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var tableView: RightClickTableView!

    static func load() -> AccountsListView {
        var objects: NSArray?
        let nib = NSNib(nibNamed: "AccountsListView", bundle: .main)!
        precondition(nib.instantiate(withOwner: nil, topLevelObjects: &objects))
        return objects!.compactMap { $0 as? AccountsListView }.first!
    }
}

enum WalletAccountListRow {
    case mnemonicWalletHeader(WalletSnapshot)
    case privateKeyWalletsHeader
    case account(wallet: WalletSnapshot, account: WalletAccount)

    var wallet: WalletSnapshot? {
        switch self {
        case .mnemonicWalletHeader(let wallet), .account(let wallet, _): wallet
        case .privateKeyWalletsHeader: nil
        }
    }

    var account: WalletAccount? {
        guard case .account(_, let account) = self else { return nil }
        return account
    }

    static func makeRows(wallets: [WalletSnapshot]) -> [Self] {
        var rows = [Self]()
        var privateKeys = [Self]()
        for wallet in wallets {
            if wallet.isMnemonic {
                rows.append(.mnemonicWalletHeader(wallet))
                rows.append(contentsOf: wallet.accounts.map { .account(wallet: wallet, account: $0) })
            } else if let account = wallet.accounts.first {
                privateKeys.append(.account(wallet: wallet, account: account))
            }
        }
        if !privateKeys.isEmpty {
            rows.append(.privateKeyWalletsHeader)
            rows.append(contentsOf: privateKeys)
        }
        return rows
    }
}

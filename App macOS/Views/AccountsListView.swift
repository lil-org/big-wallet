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

    private(set) var loadStatusView: NSStackView?
    private(set) var loadRetryButton: NSButton?
    private var loadStatusLabel: NSTextField?
    private var loadSpinner: NSProgressIndicator?
    private var retryLoad: (() -> Void)?
    private var loadStatusTopConstraint: NSLayoutConstraint?
    private var loadStatusHeightConstraint: NSLayoutConstraint?
    private var originalListTop: CGFloat = 0
    private var originalListHeight: CGFloat = 0

    func updateLoadState(_ manager: WalletsManager, retry: @escaping () -> Void) {
        if loadStatusView == nil {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            let label = NSTextField(wrappingLabelWithString: "")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            let button = NSButton(title: Strings.tryAgain, target: self, action: #selector(retryWalletLoad))
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("wallet-load-retry")
            let status = NSStackView(views: [spinner, label, button])
            status.orientation = .horizontal
            status.alignment = .centerY
            status.spacing = 8
            status.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            status.translatesAutoresizingMaskIntoConstraints = false
            status.wantsLayer = true
            status.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            addSubview(status)
            if let scroll = tableView.enclosingScrollView {
                loadStatusTopConstraint = constraints.first {
                    ($0.firstItem as? NSView) === scroll && $0.firstAttribute == .top
                }
                loadStatusHeightConstraint = scroll.constraints.first {
                    $0.firstAttribute == .height && $0.secondItem == nil
                }
                originalListTop = loadStatusTopConstraint?.constant ?? 0
                originalListHeight = loadStatusHeightConstraint?.constant ?? 280
                NSLayoutConstraint.activate([
                    status.bottomAnchor.constraint(equalTo: scroll.topAnchor),
                    status.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                    status.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
                    status.heightAnchor.constraint(equalToConstant: 64),
                ])
            }
            loadStatusView = status
            loadRetryButton = button
            loadStatusLabel = label
            loadSpinner = spinner
        }
        retryLoad = retry
        let failed: Bool
        switch manager.loadState {
        case .failed: failed = true
        case .idle, .loading, .ready: failed = false
        }
        let hidden = manager.isStoreReady
        loadStatusView?.isHidden = hidden
        loadStatusLabel?.stringValue = failed ? Strings.failedToLoad : Strings.loading
        loadRetryButton?.isHidden = !failed
        loadRetryButton?.isEnabled = failed
        loadSpinner?.isHidden = failed || hidden
        if failed || hidden { loadSpinner?.stopAnimation(nil) }
        else { loadSpinner?.startAnimation(nil) }
        loadStatusTopConstraint?.constant = originalListTop + (hidden ? 0 : 64)
        loadStatusHeightConstraint?.constant = originalListHeight - (hidden ? 0 : 64)
    }

    @objc private func retryWalletLoad() { retryLoad?() }

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

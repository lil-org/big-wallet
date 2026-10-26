import WalletDomain
import WalletAuthority
import WalletNetworking
import Cocoa

final class NativeAccountSelectionViewController: NSViewController {
    let accountSelection: NativeAccountSelectionSession
    let walletsManager: WalletsManager
    var openWalletManagement: @MainActor () async -> Bool
    private var managementTask: Task<Void, Never>?
    private var isOpeningWalletManagement = false
    private var cellModels = [CellModel]()

    private enum CellModel {
        case wallet(WalletAccountListRow)
        case manageWallets
        case approvalGuidance
    }

    var content: AccountsListView { view as! AccountsListView }
    var tableView: RightClickTableView { content.tableView }
    var primaryButton: NSButton { content.primaryButton }
    var secondaryButton: NSButton { content.secondaryButton }
    var networkButton: NSButton { content.networkButton }
    var titleLabel: NSTextField { content.titleLabel }
    private var wallets: [WalletSnapshot] { walletsManager.wallets }
    private var acceptsUserActions: Bool { accountSelection.review.isActive && !accountSelection.hasCompleted }
    private var canSelectEthereumNetwork: Bool { accountSelection.canSelectEthereumNetwork }

    init(
        accountSelection: NativeAccountSelectionSession,
        walletsManager: WalletsManager = ApplicationServices.shared.wallets,
        openWalletManagement: @escaping @MainActor () async -> Bool = DockAppLauncher.openDockApp
    ) {
        self.accountSelection = accountSelection
        self.walletsManager = walletsManager
        self.openWalletManagement = openWalletManagement
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    isolated deinit {
        managementTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() { view = AccountsListView.load() }

    override func viewDidLoad() {
        super.viewDidLoad()
        accountSelection.review.register(self)
        guard acceptsUserActions else { return }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.keyboardActivation = { [weak self] in
            guard let self else { return }
            activateRow(at: tableView.selectedRow)
        }
        primaryButton.target = self
        primaryButton.action = #selector(didClickPrimaryButton(_:))
        secondaryButton.target = self
        secondaryButton.action = #selector(didClickSecondaryButton(_:))
        networkButton.target = self
        networkButton.action = #selector(networkButtonTapped(_:))
        networkButton.image = Images.network.with(pointSize: 14, weight: .regular)
        networkButton.imagePosition = .imageOnly
        networkButton.setAccessibilityLabel(Strings.network)
        networkButton.setAccessibilityHelp(Strings.selectNetwork)
        primaryButton.title = Strings.connect
        secondaryButton.title = Strings.cancel
        primaryButton.setAccessibilityIdentifier("safari.approval.approve")
        secondaryButton.setAccessibilityIdentifier("safari.approval.reject")
#if BW_SAFARI_VM_TESTING
        tableView.setAccessibilityIdentifier("safari.approval.accounts")
#endif
        validateSelectedAccounts()
        reloadHeader()
        updateBottomButtons()
        updateCellModels()
        tableView.reloadData()
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        if let account = accountSelection.selectedAccounts.first { scrollTo(specificWalletAccount: account) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reloadHeader()
    }

    private func reloadHeader() {
        let title = accountSelection.mode == .selectAccount ? Strings.selectAccount : Strings.switchAccount
        titleLabel.stringValue = title.replacingOccurrences(of: " ", with: "\n")
        content.addButton.isHidden = true
        if let peer = nativeApprovalPeer {
            content.websiteNameLabel.stringValue = peer.name
            content.titleLabelTopConstraint.constant = 14
            content.websiteNameStackView.isHidden = false
        } else {
            content.titleLabelTopConstraint.constant = 8
            content.websiteNameStackView.isHidden = true
        }
    }

    private func updateBottomButtons() {
        content.accountsListBottomConstraint.constant = 62
        content.bottomButtonsStackView.isHidden = false
        if !accountSelection.initiallyConnectedProviders.isEmpty {
            primaryButton.title = Strings.ok
            secondaryButton.title = Strings.disconnect
            secondaryButton.keyEquivalent = ""
        }
        updateNetworkButtonVisibility()
        updatePrimaryButton()
    }

    private func updatePrimaryButton() {
        primaryButton.isEnabled = acceptsUserActions && accountSelection.canSubmitSelection()
    }

    private func setAccountSelectionControlsEnabled(_ enabled: Bool) {
        content.addButton.isEnabled = enabled
        networkButton.isEnabled = enabled
        primaryButton.isEnabled = enabled
        secondaryButton.isEnabled = enabled
        tableView.isEnabled = enabled
    }

    private func cancelMenuTracking() {
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? AccountsHeaderRowView)?.cancelMenuTracking()
        }
    }

    private func updateCellModels() {
        cellModels = WalletAccountListRow.makeRows(wallets: wallets).map(CellModel.wallet)
        if !wallets.contains(where: { $0.accounts.contains(where: accountCanBeSelected) }) {
            cellModels.append(.approvalGuidance)
        }
        cellModels.append(.manageWallets)
    }

    private func walletForRow(_ row: Int) -> WalletSnapshot? {
        guard cellModels.indices.contains(row), case .wallet(let item) = cellModels[row] else { return nil }
        return item.wallet
    }

    private func accountForRow(_ row: Int) -> WalletAccount? {
        guard cellModels.indices.contains(row), case .wallet(let item) = cellModels[row] else { return nil }
        return item.account
    }

    private func scrollTo(specificWalletAccount: SpecificWalletAccount) {
        guard let row = cellModels.firstIndex(where: {
            guard case .wallet(.account(let wallet, let account)) = $0 else { return false }
            return wallet.id == specificWalletAccount.walletId && account == specificWalletAccount.account
        }) else { return }
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func rowClicked(_ tableView: NSTableView) {
        guard acceptsUserActions else { return }
        activateRow(at: tableView.clickedRow)
    }

    private func activateRow(at row: Int) {
        guard acceptsUserActions, cellModels.indices.contains(row) else { return }
        switch cellModels[row] {
        case .manageWallets:
            tableView.deselectAll(nil)
            manageWallets()
        case .wallet(.account):
            toggleAccount(at: row)
        case .wallet, .approvalGuidance:
            break
        }
    }

    private func callCompletion(specificWalletAccounts: [SpecificWalletAccount]?) {
        guard acceptsUserActions else { return }
        accountSelection.complete(accounts: specificWalletAccounts) {
            setAccountSelectionControlsEnabled(false)
            cancelMenuTracking()
            endAllSheets()
        }
    }

    @IBAction func networkButtonTapped(_ sender: NSButton) {
        guard acceptsUserActions, canSelectEthereumNetwork else { return }
        showNetworksList()
    }

    private func showNetworksList() {
        let networksList = NetworksListView(selectedNetwork: accountSelection.network) { [weak self] selectedNetwork in
            guard let self, acceptsUserActions else { return }
            endAllSheets()
            if let selectedNetwork {
                selectNetwork(selectedNetwork)
            }
        }
        
        let popupWindow = makeHostingWindow(content: networksList, title: Strings.selectNetwork)
        view.window?.beginSheet(popupWindow)
    }

    @IBAction func didClickSecondaryButton(_ sender: Any) {
        guard acceptsUserActions else { return }
        if accountSelection.initiallyConnectedProviders.isEmpty == false {
            callCompletion(specificWalletAccounts: [])
        } else {
            callCompletion(specificWalletAccounts: nil)
        }
    }

    @IBAction func didClickPrimaryButton(_ sender: Any) {
        guard acceptsUserActions else { return }
        callCompletion(specificWalletAccounts: accountSelection.selectedAccounts.map { $0 })
    }

    private func selectNetwork(_ network: EthereumNetwork) {
        guard acceptsUserActions else { return }
        accountSelection.network = network
        updateNetworkButton(network)
        updatePrimaryButton()
    }

    private func updateNetworkButton(_ network: EthereumNetwork) {
        let identity = "\(network.chainIdHexString) · \(network.name)"
        networkButton.image = Images.network.with(
            pointSize: 14,
            weight: .semibold,
            color: .controlAccentColor.withSystemEffect(.pressed)
        )
        networkButton.toolTip = identity
        networkButton.setAccessibilityValue(identity)
    }

    private func updateNetworkButtonVisibility() {
        let isVisible = canSelectEthereumNetwork
        networkButton.isHidden = !isVisible
        if isVisible, let network = accountSelection.network {
            if !network.isEthMainnet {
                updateNetworkButton(network)
            } else {
                let identity = "\(network.chainIdHexString) · \(network.name)"
                networkButton.toolTip = identity
                networkButton.setAccessibilityValue(identity)
            }
        }
    }

    @objc private func manageWallets() {
        guard acceptsUserActions,
              !isOpeningWalletManagement else { return }
        isOpeningWalletManagement = true
        tableView.reloadData()
        managementTask = Task { [weak self, openWalletManagement] in
            let succeeded = await openWalletManagement()
            guard let self, !Task.isCancelled else { return }
            isOpeningWalletManagement = false
            guard acceptsUserActions else { return }
            tableView.reloadData()
            if !succeeded {
                presentMessageAlert(Strings.somethingWentWrong, style: .informational)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard acceptsUserActions else { return }
        if accountSelection.initiallyConnectedProviders.isEmpty == false {
            callCompletion(specificWalletAccounts: nil)
        }
    }

    @objc private func walletsChanged() {
        guard acceptsUserActions else { return }
        validateSelectedAccounts()
        reloadHeader()
        updateBottomButtons()
        updateCellModels()
        tableView.reloadData()
    }

    private func validateSelectedAccounts() {
        let specificWalletAccounts = accountSelection.selectedAccounts
        for specificWalletAccount in specificWalletAccounts {
            if let wallet = wallets.first(where: { $0.id == specificWalletAccount.walletId }),
               wallet.accounts.contains(specificWalletAccount.account) {
                continue
            } else {
                accountSelection.selectedAccounts.remove(specificWalletAccount)
            }
        }
    }

    private func didClickAccountInSelectionMode(specificWalletAccount: SpecificWalletAccount) {
        let wasSelected = accountSelection.selectedAccounts.contains(specificWalletAccount) == true
        
        if !wasSelected, let toDeselect = accountSelection.selectedAccounts.first(where: { $0.account.coin == specificWalletAccount.account.coin }) {
            accountSelection.selectedAccounts.remove(toDeselect)
        }
        
        if wasSelected {
            accountSelection.selectedAccounts.remove(specificWalletAccount)
        } else {
            accountSelection.selectedAccounts.insert(specificWalletAccount)
        }
        
        updatePrimaryButton()
        updateNetworkButtonVisibility()
    }

    private func toggleAccount(at row: Int) {
        guard acceptsUserActions,
              cellModels.indices.contains(row),
              let wallet = walletForRow(row),
              let account = accountForRow(row),
              accountCanBeSelected(account) else { return }
        didClickAccountInSelectionMode(specificWalletAccount: SpecificWalletAccount(
            walletId: wallet.id,
            account: account
        ))
        tableView.reloadData()
        tableView.selectRowIndexes([row], byExtendingSelection: false)
    }

    private func accountCanBeSelected(_ account: WalletAccount) -> Bool {
        return accountSelection.coinType == nil || accountSelection.coinType == account.coin
    }
}

extension NativeAccountSelectionViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard acceptsUserActions, cellModels.indices.contains(row) else { return false }
        if case .manageWallets = cellModels[row] {
            return !isOpeningWalletManagement && self.tableView.isHandlingKeyDown
        }
        guard let account = accountForRow(row) else { return false }
        return self.tableView.isHandlingKeyDown && accountCanBeSelected(account)
    }
}

extension NativeAccountSelectionViewController: NSTableViewDataSource {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        switch cellModels[row] {
        case .wallet(.account(let wallet, let account)):
            let rowView = tableView.makeViewOfType(AccountCellView.self)
            let selected = accountSelection.selectedAccounts.contains(SpecificWalletAccount(walletId: wallet.id, account: account))
            rowView.setup(account: account, walletId: wallet.id, isSelected: selected,
                isDisabled: !accountCanBeSelected(account), showsAccountSelection: true)
            return rowView
        case .wallet(.mnemonicWalletHeader(let wallet)):
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self)
            rowView.setup(walletName: ApplicationServices.shared.metadata.getWalletName(wallet: wallet), multicoinWallet: true, delegate: nil)
            return rowView
        case .wallet(.privateKeyWalletsHeader):
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self)
            rowView.setup(walletName: nil, multicoinWallet: false, delegate: nil)
            return rowView
        case .manageWallets:
            let rowView = tableView.makeViewOfType(AddAccountOptionCellView.self)
            rowView.setup(title: Strings.manageWallets)
            rowView.titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            rowView.titleLabel.maximumNumberOfLines = 2
            rowView.titleLabel.lineBreakMode = .byWordWrapping
            rowView.alphaValue = isOpeningWalletManagement ? 0.5 : 1
            return rowView
        case .approvalGuidance:
            let rowView = NSTableRowView()
            let label = NSTextField(wrappingLabelWithString: Strings.manageWalletsToConnect)
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            rowView.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -8),
            ])
            return rowView
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch cellModels[row] {
        case .wallet(.account): return 50
        case .wallet: return 27
        case .manageWallets: return 44
        case .approvalGuidance:
            let bounds = (Strings.manageWalletsToConnect as NSString).boundingRect(
                with: NSSize(width: max(1, tableView.bounds.width - 24), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
            return ceil(bounds.height) + 16
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { cellModels.count }
}

extension NativeAccountSelectionViewController: NativeApprovalReviewTeardown {
    func invalidateNativeApprovalReview() {
        managementTask?.cancel()
        managementTask = nil
        cancelMenuTracking()
        endAllSheets()
    }
}

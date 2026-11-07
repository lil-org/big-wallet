import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import Cocoa
import SafariServices

class AccountsListViewController: NSViewController, NativeWalletProtectedContent {

    var walletsManager = ApplicationServices.shared.wallets
    var authenticate: @MainActor (NSWindow?, AuthenticationReason, WalletAuthenticationChallenge) async -> WalletAuthenticationGrant? = {
        await Window.authenticate(in: $0, reason: $1, challenge: $2)
    }
    var walletAccess = NativeWalletAccess()
    private var cellModels = [CellModel]()
    private var preferencesButton: NSButton?
    private var loadTask: Task<Void, Never>?
    private var deletionAuthenticationTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var safariPreferencesTask: Task<Void, Never>?
    private var walletMutationTasks = [UUID: Task<Void, Never>]()
    private var secretPresentation: NativeSecretAlertPresentation?
    private var isClosed = false
    var newWalletId: String?
    var getBackToRect: CGRect?
    
    private enum CellModel {
        case wallet(WalletAccountListRow)
        case addAccountOption(AddAccountOption)
    }
    
    enum AddAccountOption {
        case createNew, importExisting
        
        var title: String {
            switch self {
            case .createNew:
                return Strings.createNew
            case .importExisting:
                return Strings.importExisting
            }
        }
    }
    
    var content: AccountsListView { view as! AccountsListView }
    private var addButton: NSButton { content.addButton }
    private var titleLabel: NSTextField { content.titleLabel }
    var tableView: RightClickTableView { content.tableView }

    override func loadView() {
        view = AccountsListView.load()
    }

    private var wallets: [WalletSnapshot] {
        return walletsManager.wallets
    }

    private var shouldShowPreferencesButton: Bool { CurrentApp.isDockApp }

    private var acceptsManagementActions: Bool { walletAccess.isCurrent && !isClosed }
    private var acceptsStoreActions: Bool { acceptsManagementActions && walletsManager.isStoreReady }
    private var hasCurrentPresentation: Bool { !isClosed && walletAccess.hasCurrentPresentation }
    private var showsEnabledStoreActions: Bool { hasCurrentPresentation && walletsManager.isStoreReady }

    func retire() {
        retireManagement()
    }

    private func retireManagement() {
        guard !isClosed else { return }
        isClosed = true
        if isViewLoaded {
            closeManagement()
            cellModels.removeAll()
            tableView.reloadData()
            Window.clearText(in: view)
        }
        newWalletId = nil
        getBackToRect = nil
        NotificationCenter.default.removeObserver(self)
    }

    isolated deinit {
        loadTask?.cancel()
        secretPresentation?.invalidate()
        safariPreferencesTask?.cancel()
        walletMutationTasks.values.forEach { $0.cancel() }
        deletionAuthenticationTask?.cancel()
        menuTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard acceptsManagementActions else { return }
        secretPresentation = NativeSecretAlertPresentation(
            sourceIsCurrent: { [weak self] window in
                guard let self else { return false }
                return acceptsStoreActions && viewIfLoaded?.window === window && window.contentViewController === self
            },
            copy: { [weak self] secret in
                guard self?.walletAccess.beginAction() == true else { return }
                SecretClipboard.shared.copy(secret)
            }
        )
        (tableView.enclosingScrollView?.verticalScroller as? WalletActivityScroller)?.accessibilityInteraction = { [weak self] in
            guard let self, !isClosed, viewIfLoaded?.window?.contentViewController === self else { return false }
            return walletAccess.beginAction()
        }
        addButton.target = self
        addButton.action = #selector(addButtonTapped(_:))
        addButton.menu = NSMenu()
        addButton.menu?.delegate = self
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self
        tableView.menuSource = self
        tableView.keyboardActivation = { [weak self] in
            guard let self else { return }
            activateRow(at: tableView.selectedRow)
        }
        content.accountsListBottomConstraint.constant = 0
        content.bottomButtonsStackView.isHidden = true
        content.networkButton.isHidden = true
        content.primaryButton.isEnabled = false
        setupPreferencesButtonIfNeeded()
        reloadHeader()
        updateCellModels()
        tableView.reloadData()
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletLoadStateChanged), name: .walletsLoadStateChanged, object: walletsManager)
        updateLoadPresentation()
        startLoadingIfNeeded()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        guard acceptsManagementActions else { return }
        reloadHeader()
        startLoadingIfNeeded()
        getBackToRectIfNeeded()
        blinkNewWalletCellIfNeeded()
        view.window?.delegate = self
        
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        loadTask?.cancel()
        loadTask = nil
        secretPresentation?.sourceWillDisappear()
    }

    private func reloadHeader() {
        titleLabel.stringValue = Strings.wallets
        addButton.isHidden = wallets.isEmpty
        addButton.isEnabled = showsEnabledStoreActions
        preferencesButton?.isHidden = !shouldShowPreferencesButton
        content.titleLabelTopConstraint.constant = 8
        content.websiteNameStackView.isHidden = true
    }

    private func setupPreferencesButtonIfNeeded() {
        guard shouldShowPreferencesButton else { return }

        let button = NSButton(image: Images.preferences.with(pointSize: 18, weight: .regular) ?? Images.preferences,
                              target: self,
                              action: #selector(preferencesButtonTapped(_:)))
        button.bezelStyle = .inline
        button.focusRingType = .none
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = Strings.bigWallet
        button.translatesAutoresizingMaskIntoConstraints = false

        let menu = NSMenu(title: Strings.bigWallet)
        menu.delegate = self
        button.menu = menu

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            button.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 35),
            button.heightAnchor.constraint(equalToConstant: 34)
        ])
        preferencesButton = button
    }
    
    @IBAction func addButtonTapped(_ sender: NSButton) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let menu = sender.menu
        let createItem = NSMenuItem(title: AddAccountOption.createNew.title, action: #selector(didClickCreateAccount), keyEquivalent: "")
        let importItem = NSMenuItem(title: AddAccountOption.importExisting.title, action: #selector(didClickImportAccount), keyEquivalent: "")
        importItem.target = self
        createItem.target = self
        menu?.addItem(createItem)
        menu?.addItem(.separator())
        menu?.addItem(importItem)
        
        var origin = sender.frame.origin
        origin.x += sender.frame.width
        origin.y += sender.frame.height
        menu?.popUp(positioning: nil, at: origin, in: view)
    }

    @objc private func preferencesButtonTapped(_ sender: NSButton) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions,
              shouldShowPreferencesButton,
              let menu = sender.menu else { return }

        menu.addItem(preferencesMenuItem(title: Strings.enableSafariExtension, action: #selector(didClickEnableSafariExtension)))
        menu.addItem(preferencesMenuItem(title: Strings.rateOnTheAppStore, action: #selector(didClickRateOnTheAppStore)))
        menu.addItem(.separator())
        menu.addItem(preferencesMenuItem(title: Strings.viewOnGithub, action: #selector(didClickViewOnGithub)))
        menu.addItem(preferencesMenuItem(title: Strings.dropUsALine, action: #selector(didClickDropUsALine)))
        menu.addItem(preferencesMenuItem(title: Strings.viewOnX, action: #selector(didClickViewOnX)))

        var origin = sender.frame.origin
        origin.y += sender.frame.height
        menu.popUp(positioning: nil, at: origin, in: view)
    }

    private func preferencesMenuItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func didClickCreateAccount() {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let alert = NSAlert()
        alert.messageText = Strings.backUpNewWallet
        alert.informativeText = Strings.youWillSeeSecretWords
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  acceptsStoreActions else { return }
            if response == .alertFirstButtonReturn, walletAccess.beginAction() {
                createNewAccountAndShowSecretWords()
            }
        }
    }
    
    private func startWalletMutation(
        showsFailure: Bool = true,
        revealToken: NativeSecretAlertPresentation.Token? = nil,
        _ operation: @escaping @MainActor (WalletAccessSession) async throws -> WalletSnapshot?
    ) {
        guard acceptsStoreActions else { return }
        let id = UUID()
        let access = walletAccess
        walletMutationTasks[id] = Task { [weak self] in
            defer { self?.walletMutationTasks.removeValue(forKey: id) }
            guard !Task.isCancelled, self?.acceptsStoreActions == true else { return }
            do {
                let session = try access.requireCurrentAccess()
                let created = try await operation(session)
                guard let self, !Task.isCancelled, acceptsStoreActions else { return }
                if let created {
                    newWalletId = created.id
                    blinkNewWalletCellIfNeeded()
                    let authorization = walletsManager.takeInitialBackupAuthorization(wallet: created)
                    guard let revealToken, let authorization, let secretPresentation else {
                        authorization?.invalidate()
                        return
                    }
                    secretPresentation.reveal(for: revealToken, authorization: authorization,
                        export: secretExport(wallet: created, specificAccount: nil))
                }
            } catch {
                if let revealToken { self?.secretPresentation?.invalidate(ifCurrent: revealToken) }
                guard let self, !Task.isCancelled, acceptsStoreActions, showsFailure else { return }
                presentMessageAlert(Strings.somethingWentWrong, style: .informational)
            }
        }
    }

    private func createNewAccountAndShowSecretWords() {
        guard acceptsStoreActions, let window = viewIfLoaded?.window,
              let token = secretPresentation?.begin(in: window, title: Strings.secretWords) else { return }
        startWalletMutation(showsFailure: false, revealToken: token) { [walletsManager] session in
            try await walletsManager.createWallet(access: session)
        }
    }

    private func getBackToRectIfNeeded() {
        guard let rect = getBackToRect else { return }
        getBackToRect = nil
        tableView.scrollToVisible(rect)
    }
    
    private func blinkNewWalletCellIfNeeded() {
        guard let id = newWalletId else { return }
        newWalletId = nil
        let blinkIndexes = cellModels.enumerated().compactMap { index, model -> Int? in
            guard case .wallet(.account(let wallet, _)) = model, wallet.id == id else { return nil }
            return index
        }
        if let last = blinkIndexes.last { tableView.scrollRowToVisible(last) }
        for row in blinkIndexes {
            (tableView.rowView(atRow: row, makeIfNecessary: true) as? AccountCellView)?.blink()
        }
    }
    
    @objc private func didClickImportAccount() {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions, let destination = viewIfLoaded?.window else { return }
        let importViewController = instantiate(ImportViewController.self)
        importViewController.walletAccess = walletAccess
        if let window = destination.windowController as? WalletWindowController {
            window.installProtectedContent(importViewController, access: walletAccess)
        } else {
            destination.contentViewController = importViewController
        }
        retireManagement()
    }

    private func walletForRow(_ row: Int) -> WalletSnapshot? {
        guard cellModels.indices.contains(row), case .wallet(let item) = cellModels[row] else { return nil }
        return item.wallet
    }
    
    private func accountForRow(_ row: Int) -> WalletAccount? {
        guard cellModels.indices.contains(row), case .wallet(let item) = cellModels[row] else { return nil }
        return item.account
    }
    
    @objc private func didClickViewOnExplorer(_ sender: NSMenuItem) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func didClickEnableSafariExtension() {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        safariPreferencesTask?.cancel()
        safariPreferencesTask = Task { [weak self] in
            guard let self, !Task.isCancelled, acceptsManagementActions else { return }
            do {
                try await SFSafariApplication.showPreferencesForExtension(withIdentifier: Identifiers.safariExtensionBundle)
            } catch {
                guard !Task.isCancelled, acceptsManagementActions else { return }
                NSWorkspace.shared.open(URL.iosSafariGuide)
            }
        }
    }

    @objc private func didClickRateOnTheAppStore() {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        ReviewRequster.didClickAppStoreReviewButton()
    }

    @objc private func didClickViewOnGithub() {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        NSWorkspace.shared.open(URL.github)
    }

    @objc private func didClickDropUsALine() {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        NSWorkspace.shared.open(URL.email)
    }

    @objc private func didClickViewOnX() {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        NSWorkspace.shared.open(URL.x)
    }
    
    @objc private func didClickCopyAddress(_ sender: AnyObject) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions else { return }
        let row = tableView.deselectedRow
        guard let address = accountForRow(row)?.address else { return }
        NSPasteboard.general.clearAndSetString(address)
    }

    @objc private func didClickRemoveWallet(_ sender: AnyObject) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.deselectedRow
        if let wallet = walletForRow(row) {
            warnBeforeRemoving(wallet: wallet)
        }
    }
    
    @objc private func didClickRemoveAccount(_ sender: AnyObject) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        
        guard wallet.accounts.count > 1 else {
            warnOnLastAccountRemovalAttempt(wallet: wallet)
            return
        }
        
        startWalletMutation { [walletsManager] session in
            try await walletsManager.update(wallet: wallet, removeAccounts: [account], access: session)
            return nil
        }
    }
    
    private func warnOnLastAccountRemovalAttempt(wallet: WalletSnapshot) {
        guard acceptsStoreActions else { return }
        let alert = NSAlert()
        alert.messageText = Strings.removingTheLastAccount
        alert.alertStyle = .critical
        
        alert.addButton(withTitle: Strings.cancel)
        alert.addButton(withTitle: Strings.removeAnyway)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  acceptsStoreActions else { return }
            if response == .alertSecondButtonReturn, walletAccess.beginAction() {
                warnBeforeRemoving(wallet: wallet)
            }
        }
    }
    
    private func warnBeforeRemoving(wallet: WalletSnapshot) {
        guard acceptsStoreActions else { return }
        let alert = NSAlert()
        alert.messageText = Strings.removedWalletsCantBeRecovered
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.removeAnyway)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  acceptsStoreActions else { return }
            if response == .alertFirstButtonReturn, walletAccess.beginAction() {
                let window = viewIfLoaded?.window
                secretPresentation?.cancelAuthentication()
                deletionAuthenticationTask?.cancel()
                deletionAuthenticationTask = Task { [weak self, weak window] in
                    guard let self, !Task.isCancelled, acceptsStoreActions else { return }
                    let credentials = ApplicationServices.shared.credentials
                    let challenge = credentials.makeWalletAccessChallenge()
                    defer { challenge.invalidate() }
                    let result = await authenticate(window, .removeWallet, challenge)
                    let authorization = await Self.finishAuthentication(result, walletsManager: walletsManager) { [weak self] in
                        self?.acceptsManagementActions == true
                    }
                    guard let authorization, !Task.isCancelled, acceptsStoreActions,
                          let access = credentials.accessSession(authorization: authorization) else { return }
                    defer { access.invalidate() }
                    Window.activateWindow(view.window)
                    removeWallet(wallet)
                }
            }
        }
    }
    
    private func removeWallet(_ wallet: WalletSnapshot) {
        startWalletMutation(showsFailure: false) { [walletsManager] session in
            try await walletsManager.delete(wallet: wallet, access: session)
            return nil
        }
    }
    
    @objc private func walletsChanged() {
        guard acceptsManagementActions else { return }
        let scroll = tableView.enclosingScrollView
        let origin = scroll?.contentView.bounds.origin
        reloadHeader()
        updateCellModels()
        tableView.reloadData()
        updateLoadPresentation()
        if let scroll, let origin {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func walletLoadStateChanged() {
        guard acceptsManagementActions else { return }
        if !walletsManager.isStoreReady {
            let isRefreshing = walletsManager.loadState == .loading
            secretPresentation?.walletLoadStateChanged(walletsManager.loadState)
            if !isRefreshing {
                deletionAuthenticationTask?.cancel()
                deletionAuthenticationTask = nil
            }
            cancelMenuTracking()
        }
        updateLoadPresentation()
    }

    private static func finishAuthentication(
        _ authorization: WalletAuthenticationGrant?,
        walletsManager: WalletsManager,
        isCurrent: @MainActor () -> Bool
    ) async -> WalletAuthenticationGrant? {
        guard let authorization else { return nil }
        if !Task.isCancelled, isCurrent(), walletsManager.loadState == .loading {
            _ = await walletsManager.reloadFromStore()
        }
        guard !Task.isCancelled, isCurrent(), walletsManager.isStoreReady else {
            authorization.invalidate()
            return nil
        }
        return authorization
    }

    private func updateLoadPresentation() {
        guard hasCurrentPresentation else { return }
        reloadHeader()
        content.updateLoadState(walletsManager) { [weak self] in self?.retryWalletLoad() }
        if wallets.isEmpty {
            updateCellModels()
            tableView.reloadData()
        } else {
            tableView.enumerateAvailableRowViews { [weak self] rowView, row in
                guard let self, let header = rowView as? AccountsHeaderRowView,
                      let wallet = walletForRow(row) else { return }
                header.setup(walletName: ApplicationServices.shared.metadata.getWalletName(wallet: wallet),
                    multicoinWallet: true, delegate: showsEnabledStoreActions ? self : nil)
            }
        }
    }

    private func startLoadingIfNeeded() {
        switch walletsManager.loadState {
        case .idle, .loading: loadWallets(retry: false)
        case .ready, .failed: break
        }
    }

    @objc private func retryWalletLoad() {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        loadWallets(retry: true)
    }

    private func loadWallets(retry: Bool) {
        guard acceptsManagementActions, loadTask == nil else { return }
        loadTask = Task { [weak self, walletsManager] in
            if retry { await walletsManager.reloadFromStore() }
            else { await walletsManager.start() }
            guard let self, !Task.isCancelled, acceptsManagementActions else { return }
            loadTask = nil
            updateLoadPresentation()
        }
    }
    
    @objc private func didClickShowKey(_ sender: AnyObject) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: nil)
    }
    
    @objc private func didClickEditAccountName(_ sender: AnyObject) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        let initialText = account.name(walletId: wallet.id)
        let nameActionTitle = initialText == nil ? Strings.setName : Strings.editName
        presentTextInputAlert(
            title: nameActionTitle,
            initialText: initialText,
            placeholder: account.croppedAddress
        ) { [weak self] newName in
            guard let self,
                  acceptsStoreActions else { return }
            if let newName, walletAccess.beginAction() {
                ApplicationServices.shared.metadata.saveAccountName(newName, wallet: wallet, account: account)
                tableView.reloadData()
            }
        }
    }
    
    @objc private func didClickShowSpecificPrivateKey(_ sender: AnyObject) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: account)
    }
    
    private func warnBeforeShowingKey(wallet: WalletSnapshot, specificAccount: WalletAccount?) {
        guard acceptsStoreActions else { return }
        let alert = NSAlert()
        let showingMnemonic = wallet.isMnemonic && specificAccount == nil
        alert.messageText = showingMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.iUnderstandTheRisks)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self, acceptsStoreActions else { return }
            guard response == .alertFirstButtonReturn, walletAccess.beginAction(),
                  let window = viewIfLoaded?.window, let secretPresentation,
                  let token = secretPresentation.begin(in: window, title: showingMnemonic ? Strings.secretWords : Strings.privateKey)
            else { return }
            deletionAuthenticationTask?.cancel()
            deletionAuthenticationTask = nil
            let reason: AuthenticationReason = showingMnemonic ? .showSecretWords : .showPrivateKey
            secretPresentation.authenticateAndReveal(for: token, authenticate: { [weak self, weak window, walletsManager, authenticate] in
                let challenge: WalletAuthenticationChallenge
                do {
                    challenge = try await walletsManager.makeExportChallenge(
                        wallet: wallet, account: specificAccount,
                        kind: showingMnemonic ? .mnemonic : .privateKey
                    )
                } catch { return nil }
                guard !Task.isCancelled, self != nil else { challenge.invalidate(); return nil }
                let result = await authenticate(window, reason, challenge)
                let authorization = await Self.finishAuthentication(result, walletsManager: walletsManager) { [weak self] in
                    self?.acceptsManagementActions == true
                }
                if authorization == nil { challenge.invalidate() }
                return authorization
            }, export: secretExport(wallet: wallet, specificAccount: specificAccount))
        }
    }

    private func secretExport(wallet: WalletSnapshot, specificAccount: WalletAccount?) -> NativeSecretAlertPresentation.Export {
        let walletsManager = walletsManager
        return { authorization in
            guard let current = walletsManager.currentWallet(id: wallet.id) else {
                throw WalletCredentialError.authorizationUnavailable
            }
            if current.isMnemonic && specificAccount == nil {
                return try await walletsManager.exportMnemonic(wallet: current, authorization: authorization)
            }
            return try await walletsManager.exportPrivateKey(wallet: current, account: specificAccount, authorization: authorization)
        }
    }

    private func updateCellModels() {
        guard !isClosed else { return }
        if wallets.isEmpty {
            cellModels = walletsManager.isStoreReady ? [.addAccountOption(.createNew), .addAccountOption(.importExisting)] : []
        } else {
            cellModels = WalletAccountListRow.makeRows(wallets: wallets).map(CellModel.wallet)
        }
    }
    
    private func showMenuOnCellSelection(row: Int) {
        guard !isClosed else { return }
        menuTask?.cancel()
        menuTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            guard let self, !Task.isCancelled, acceptsManagementActions,
                  tableView.selectedRow == row else { return }
            var point = NSEvent.mouseLocation
            point.x += 1
            menuForRow(row)?.popUp(positioning: nil, at: point, in: nil)
        }
    }

    private func cancelMenuTracking() {
        addButton.menu?.cancelTrackingWithoutAnimation()
        tableView.menu?.cancelTrackingWithoutAnimation()
        preferencesButton?.menu?.cancelTrackingWithoutAnimation()
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? AccountsHeaderRowView)?.cancelMenuTracking()
        }
    }

    @objc private func rowClicked(_ tableView: NSTableView) {
        guard acceptsManagementActions else { return }
        if !wallets.isEmpty,
           tableView.selectedRow >= 0,
           tableView.selectedRow != tableView.clickedRow {
            tableView.deselectAll(nil)
            return
        }
        activateRow(at: tableView.clickedRow)
    }

    private func activateRow(at row: Int) {
        guard acceptsManagementActions, walletAccess.beginAction() else { return }
        guard acceptsManagementActions, cellModels.indices.contains(row) else { return }
        switch cellModels[row] {
        case .addAccountOption(let option):
            tableView.deselectAll(nil)
            switch option {
            case .createNew: didClickCreateAccount()
            case .importExisting: didClickImportAccount()
            }
        case .wallet(.account):
            guard tableView.selectedRow == row else { return }
            showMenuOnCellSelection(row: row)
        case .wallet:
            break
        }
    }

}

extension AccountsListViewController: TableViewMenuSource {
    
    func menuForRow(_ row: Int) -> NSMenu? {
        guard acceptsManagementActions, cellModels.indices.contains(row) else { return nil }
        guard let menu = tableView.menu else { return nil }

        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return nil }

        menu.removeAllItems()
        menu.autoenablesItems = false
        let nameItem = NSMenuItem(title: account.coin.name, action: nil, keyEquivalent: "")
        menu.addItem(nameItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: Strings.copyAddress, action: #selector(didClickCopyAddress(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        
        for (name, url) in account.coin.explorersFor(address: account.address) {
            let menuItem = NSMenuItem(title: name, action: #selector(didClickViewOnExplorer(_:)), keyEquivalent: "")
            menuItem.representedObject = url
            menu.addItem(menuItem)
        }
        
        menu.addItem(.separator())
        let currentName = account.name(walletId: wallet.id)
        let nameActionTitle = currentName == nil ? Strings.setName : Strings.editName
        menu.addItem(NSMenuItem(title: nameActionTitle, action: #selector(didClickEditAccountName(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: wallet.isMnemonic ? Strings.showSecretWords : Strings.showPrivateKey, action: #selector(didClickShowKey(_:)), keyEquivalent: ""))
        
        if wallet.isMnemonic {
            menu.addItem(NSMenuItem(title: Strings.showPrivateKey, action: #selector(didClickShowSpecificPrivateKey(_:)), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: Strings.removeAccount, action: #selector(didClickRemoveAccount(_:)), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: Strings.removeWallet, action: #selector(didClickRemoveWallet(_:)), keyEquivalent: ""))
        }
        
        if !walletsManager.isStoreReady {
            for item in menu.items where item.action != #selector(didClickCopyAddress(_:)) &&
                item.action != #selector(didClickViewOnExplorer(_:)) {
                item.isEnabled = false
            }
        }
        return menu
    }
    
}

extension AccountsListViewController: AccountsHeaderDelegate {
    
    func didClickEditName(sender: NSTableRowView) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        
        let initialText = ApplicationServices.shared.metadata.getWalletName(wallet: wallet)
        let nameActionTitle = initialText == nil ? Strings.setName : Strings.editName
        presentTextInputAlert(
            title: nameActionTitle,
            initialText: initialText,
            placeholder: Strings.multicoinWallet
        ) { [weak self] newName in
            guard let self,
                  acceptsStoreActions else { return }
            if let newName, walletAccess.beginAction() {
                ApplicationServices.shared.metadata.saveWalletName(newName, wallet: wallet)
                tableView.reloadData()
            }
        }
    }
    
    func didClickEditAccounts(sender: NSTableRowView) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions, let destination = viewIfLoaded?.window else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        
        let editAccountsViewController = instantiate(EditAccountsViewController.self)
        editAccountsViewController.walletAccess = walletAccess
        editAccountsViewController.wallet = wallet
        editAccountsViewController.getBackToRect = tableView.visibleRect
        if let window = destination.windowController as? WalletWindowController {
            window.installProtectedContent(editAccountsViewController, access: walletAccess)
        } else {
            destination.contentViewController = editAccountsViewController
        }
        retireManagement()
    }
    
    func didClickShowSecretWords(sender: NSTableRowView) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: nil)
    }
    
    func didClickRemoveWallet(sender: NSTableRowView) {
        guard acceptsStoreActions, walletAccess.beginAction() else { return }
        guard acceptsStoreActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeRemoving(wallet: wallet)
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isClosed,
              NSApp.currentEvent?.type == .keyDown,
              tableView.selectedRow >= 0,
              accountForRow(tableView.selectedRow) != nil else { return }
        showMenuOnCellSelection(row: tableView.selectedRow)
    }
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard !isClosed, cellModels.indices.contains(row) else { return false }
        if case .addAccountOption = cellModels[row] { return self.tableView.isHandlingKeyDown }
        guard accountForRow(row) != nil else { return false }
        return tableView.selectedRow < 0
    }
    
}

extension AccountsListViewController: NSTableViewDataSource {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard !isClosed, cellModels.indices.contains(row) else { return nil }
        switch cellModels[row] {
        case .wallet(.account(let wallet, let account)):
            let rowView = tableView.makeViewOfType(AccountCellView.self)
            rowView.setup(account: account, walletId: wallet.id, isSelected: false, isDisabled: false)
            return rowView
        case .wallet(.mnemonicWalletHeader(let wallet)):
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self)
            rowView.setup(walletName: ApplicationServices.shared.metadata.getWalletName(wallet: wallet),
                multicoinWallet: true, delegate: showsEnabledStoreActions ? self : nil)
            return rowView
        case .wallet(.privateKeyWalletsHeader):
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self)
            rowView.setup(walletName: nil, multicoinWallet: false, delegate: nil)
            return rowView
        case .addAccountOption(let option):
            let rowView = tableView.makeViewOfType(AddAccountOptionCellView.self)
            rowView.setup(title: option.title)
            return rowView
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard !isClosed, cellModels.indices.contains(row) else { return tableView.rowHeight }
        return switch cellModels[row] {
        case .wallet(.account): 50
        case .wallet: 27
        case .addAccountOption: 44
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { isClosed ? 0 : cellModels.count }
}

extension AccountsListViewController {

    private func closeManagement() {
        loadTask?.cancel()
        loadTask = nil
        secretPresentation?.invalidate()
        safariPreferencesTask?.cancel()
        safariPreferencesTask = nil
        walletMutationTasks.values.forEach { $0.cancel() }
        walletMutationTasks.removeAll()
        cancelMenuTracking()
        deletionAuthenticationTask?.cancel()
        deletionAuthenticationTask = nil
        menuTask?.cancel()
        menuTask = nil
        endAllSheets()
    }

}

extension AccountsListViewController: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        if menu === addButton.menu {
            menu.removeAllItems()
        } else if let preferencesMenu = preferencesButton?.menu, menu === preferencesMenu {
            menu.removeAllItems()
        } else if menu === tableView.menu {
            tableView.deselectedRow = tableView.selectedRow
            tableView.deselectAll(nil)
        }
    }
    
}

extension AccountsListViewController: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        closeManagement()
    }
    
}

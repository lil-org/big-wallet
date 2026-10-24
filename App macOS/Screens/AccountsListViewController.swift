// ∅ 2026 lil org

import Cocoa
import SafariServices

class AccountsListViewController: NSViewController {

    var walletsManager = WalletsManager.shared
    private var cellModels = [CellModel]()
    private var preferencesButton: NSButton?
    private var authenticationTask: Task<Void, Never>?
    private var keyExportTask: Task<Void, Never>?
    private var menuTask: Task<Void, Never>?
    private var safariPreferencesTask: Task<Void, Never>?
    private var walletMutationTasks = [UUID: Task<Void, Never>]()
    private let secretSession = SecretPresentationSession()
    private var secretToken: SecretPresentationSession.Token?
    private var secretAuthenticationToken: SecretPresentationSession.Token?
    private weak var secretOwnerWindow: NSWindow?
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

    private var acceptsManagementActions: Bool { !isClosed }

    isolated deinit {
        secretSession.invalidate()
        secretPresentation?.dismiss()
        keyExportTask?.cancel()
        safariPreferencesTask?.cancel()
        walletMutationTasks.values.forEach { $0.cancel() }
        authenticationTask?.cancel()
        menuTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard acceptsManagementActions else { return }
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
        for name in [NSApplication.willResignActiveNotification, NSApplication.willHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(secretApplicationWillDeactivate), name: name, object: nil)
        }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(secretWindowWillDisappear), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(secretWindowDidResignKey), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(secretWindowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: nil)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        reloadHeader()
        getBackToRectIfNeeded()
        blinkNewWalletCellIfNeeded()
        view.window?.delegate = self
        
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        if secretAuthenticationToken == nil { invalidateSecretPresentation() }
    }

    private var secretOwnerIsActive: Bool {
        guard acceptsManagementActions, NSApp.isActive,
              let window = secretOwnerWindow,
              window.isVisible, !window.isMiniaturized,
              window.contentViewController === self,
              viewIfLoaded?.window === window else { return false }
        return NativeSecretAlertPresentation.acceptsKeyWindow(
            NSApp.keyWindow,
            owner: window,
            presentation: secretPresentation
        )
    }

    private func beginSecretPresentation() -> SecretPresentationSession.Token? {
        invalidateSecretPresentation()
        secretOwnerWindow = viewIfLoaded?.window
        guard secretOwnerIsActive else {
            secretOwnerWindow = nil
            return nil
        }
        let token = secretSession.begin()
        secretToken = token
        return token
    }

    private func canPresentSecret(for token: SecretPresentationSession.Token) -> Bool {
        secretToken == token && secretSession.isCurrent(token) && secretOwnerIsActive
    }

    private func invalidateSecretPresentation() {
        secretSession.invalidate()
        secretToken = nil
        if secretAuthenticationToken != nil {
            authenticationTask?.cancel()
            authenticationTask = nil
        }
        secretAuthenticationToken = nil
        keyExportTask?.cancel()
        keyExportTask = nil
        let presentation = secretPresentation
        secretPresentation = nil
        secretOwnerWindow = nil
        presentation?.dismiss()
    }

    @objc private func secretApplicationWillDeactivate() {
        guard secretAuthenticationToken == nil else { return }
        invalidateSecretPresentation()
    }

    @objc private func secretWindowWillDisappear(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === secretOwnerWindow || window === secretPresentation?.alert.window else { return }
        invalidateSecretPresentation()
    }

    @objc private func secretWindowDidResignKey(_ notification: Notification) {
        guard secretAuthenticationToken == nil, let token = secretToken,
              let window = notification.object as? NSWindow,
              window === secretOwnerWindow || window === secretPresentation?.alert.window else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, secretToken == token, !secretOwnerIsActive else { return }
            invalidateSecretPresentation()
        }
    }

    @objc private func secretWindowDidBecomeKey(_ notification: Notification) {
        guard secretAuthenticationToken == nil, secretToken != nil,
              let window = notification.object as? NSWindow,
              window !== secretOwnerWindow, window !== secretPresentation?.alert.window else { return }
        invalidateSecretPresentation()
    }

    private func reloadHeader() {
        titleLabel.stringValue = Strings.wallets
        addButton.isHidden = wallets.isEmpty
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
        guard acceptsManagementActions else { return }
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
        guard acceptsManagementActions else { return }
        let alert = Alert()
        alert.messageText = Strings.backUpNewWallet
        alert.informativeText = Strings.youWillSeeSecretWords
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  acceptsManagementActions else { return }
            if response == .alertFirstButtonReturn {
                createNewAccountAndShowSecretWords()
            }
        }
    }
    
    private func startWalletMutation(
        showsFailure: Bool = true,
        revealToken: SecretPresentationSession.Token? = nil,
        _ operation: @escaping @MainActor () async throws -> WalletSnapshot?
    ) {
        let id = UUID()
        walletMutationTasks[id] = Task { [weak self] in
            defer { self?.walletMutationTasks.removeValue(forKey: id) }
            do {
                let created = try await operation()
                guard let self, !Task.isCancelled, acceptsManagementActions else { return }
                if let created {
                    newWalletId = created.id
                    blinkNewWalletCellIfNeeded()
                    guard let revealToken, canPresentSecret(for: revealToken) else { return }
                    showKey(wallet: created, specificAccount: nil, token: revealToken)
                }
            } catch {
                if let revealToken, self?.secretToken == revealToken {
                    self?.invalidateSecretPresentation()
                }
                guard let self, !Task.isCancelled, acceptsManagementActions, showsFailure else { return }
                presentMessageAlert(Strings.somethingWentWrong, style: .informational)
            }
        }
    }

    private func createNewAccountAndShowSecretWords() {
        guard acceptsManagementActions, let token = beginSecretPresentation() else { return }
        startWalletMutation(showsFailure: false, revealToken: token) { [walletsManager] in
            try await walletsManager.createWallet()
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
        guard acceptsManagementActions else { return }
        let importViewController = instantiate(ImportViewController.self)
        view.window?.contentViewController = importViewController
        endAllSheets()
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
        guard acceptsManagementActions else { return }
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func didClickEnableSafariExtension() {
        guard acceptsManagementActions else { return }
        safariPreferencesTask?.cancel()
        safariPreferencesTask = Task { [weak self] in
            do {
                try await SFSafariApplication.showPreferencesForExtension(withIdentifier: Identifiers.safariExtensionBundle)
            } catch {
                guard let self, !Task.isCancelled, acceptsManagementActions else { return }
                NSWorkspace.shared.open(URL.iosSafariGuide)
            }
        }
    }

    @objc private func didClickRateOnTheAppStore() {
        guard acceptsManagementActions else { return }
        ReviewRequster.didClickAppStoreReviewButton()
    }

    @objc private func didClickViewOnGithub() {
        guard acceptsManagementActions else { return }
        NSWorkspace.shared.open(URL.github)
    }

    @objc private func didClickDropUsALine() {
        guard acceptsManagementActions else { return }
        NSWorkspace.shared.open(URL.email)
    }

    @objc private func didClickViewOnX() {
        guard acceptsManagementActions else { return }
        NSWorkspace.shared.open(URL.x)
    }
    
    @objc private func didClickCopyAddress(_ sender: AnyObject) {
        guard acceptsManagementActions else { return }
        let row = tableView.deselectedRow
        guard let address = accountForRow(row)?.address else { return }
        NSPasteboard.general.clearAndSetString(address)
    }

    @objc private func didClickRemoveWallet(_ sender: AnyObject) {
        guard acceptsManagementActions else { return }
        let row = tableView.deselectedRow
        if let wallet = walletForRow(row) {
            warnBeforeRemoving(wallet: wallet)
        }
    }
    
    @objc private func didClickRemoveAccount(_ sender: AnyObject) {
        guard acceptsManagementActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        
        guard wallet.accounts.count > 1 else {
            warnOnLastAccountRemovalAttempt(wallet: wallet)
            return
        }
        
        startWalletMutation { [walletsManager] in
            try await walletsManager.update(wallet: wallet, removeAccounts: [account])
            return nil
        }
    }
    
    private func warnOnLastAccountRemovalAttempt(wallet: WalletSnapshot) {
        let alert = Alert()
        alert.messageText = Strings.removingTheLastAccount
        alert.alertStyle = .critical
        
        alert.addButton(withTitle: Strings.cancel)
        alert.addButton(withTitle: Strings.removeAnyway)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  acceptsManagementActions else { return }
            if response != .alertFirstButtonReturn {
                warnBeforeRemoving(wallet: wallet)
            }
        }
    }
    
    private func warnBeforeRemoving(wallet: WalletSnapshot) {
        let alert = Alert()
        alert.messageText = Strings.removedWalletsCantBeRecovered
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.removeAnyway)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  acceptsManagementActions else { return }
            if response == .alertFirstButtonReturn {
                let window = viewIfLoaded?.window
                authenticationTask?.cancel()
                authenticationTask = Task { [weak self, weak window] in
                    let allowed = await Window.authenticate(in: window, reason: .removeWallet)
                    guard let self, allowed, !Task.isCancelled, acceptsManagementActions else { return }
                    Window.activateWindow(view.window)
                    removeWallet(wallet)
                }
            }
        }
    }
    
    private func removeWallet(_ wallet: WalletSnapshot) {
        startWalletMutation(showsFailure: false) { [walletsManager] in
            try await walletsManager.delete(wallet: wallet)
            return nil
        }
    }
    
    @objc private func walletsChanged() {
        guard acceptsManagementActions else { return }
        reloadHeader()
        updateCellModels()
        tableView.reloadData()
    }
    
    @objc private func didClickShowKey(_ sender: AnyObject) {
        guard acceptsManagementActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: nil)
    }
    
    @objc private func didClickEditAccountName(_ sender: AnyObject) {
        guard acceptsManagementActions else { return }
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
                  acceptsManagementActions else { return }
            if let newName {
                WalletsMetadataService.saveAccountName(newName, wallet: wallet, account: account)
                tableView.reloadData()
            }
        }
    }
    
    @objc private func didClickShowSpecificPrivateKey(_ sender: AnyObject) {
        guard acceptsManagementActions else { return }
        let row = tableView.deselectedRow
        guard let wallet = walletForRow(row), let account = accountForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: account)
    }
    
    private func warnBeforeShowingKey(wallet: WalletSnapshot, specificAccount: WalletAccount?) {
        let alert = Alert()
        let showingMnemonic = wallet.isMnemonic && specificAccount == nil
        alert.messageText = showingMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        alert.alertStyle = .critical
        alert.addButton(withTitle: Strings.iUnderstandTheRisks)
        alert.addButton(withTitle: Strings.cancel)
        presentAlert(alert) { [weak self] response in
            guard let self,
                  acceptsManagementActions else { return }
            if response == .alertFirstButtonReturn {
                guard let token = beginSecretPresentation() else { return }
                let reason: AuthenticationReason = showingMnemonic
                    ? .showSecretWords
                    : .showPrivateKey
                let window = viewIfLoaded?.window
                authenticationTask?.cancel()
                secretAuthenticationToken = token
                authenticationTask = Task { [weak self, weak window] in
                    let allowed = await Window.authenticate(in: window, reason: reason)
                    guard let self, secretToken == token else { return }
                    secretAuthenticationToken = nil
                    authenticationTask = nil
                    guard allowed, !Task.isCancelled, canPresentSecret(for: token) else {
                        invalidateSecretPresentation()
                        return
                    }
                    showKey(
                        wallet: wallet,
                        specificAccount: specificAccount,
                        token: token
                    )
                }
            }
        }
    }
    
    private func showKey(wallet: WalletSnapshot, specificAccount: WalletAccount?, token: SecretPresentationSession.Token) {
        guard canPresentSecret(for: token),
              let wallet = walletsManager.currentWallet(id: wallet.id) else { return }
        let showingMnemonic = wallet.isMnemonic && specificAccount == nil
        keyExportTask?.cancel()
        keyExportTask = Task { [weak self, walletsManager] in
            let secret: String
            do {
                if showingMnemonic {
                    secret = try await walletsManager.exportMnemonic(wallet: wallet)
                } else {
                    secret = try await walletsManager.exportPrivateKey(wallet: wallet, account: specificAccount)
                }
            } catch {
                if self?.secretToken == token { self?.invalidateSecretPresentation() }
                return
            }
            guard let self, !Task.isCancelled, canPresentSecret(for: token) else { return }
            keyExportTask = nil
            presentSecret(secret, showingMnemonic: showingMnemonic, token: token)
        }
    }

    private func presentSecret(_ secret: String, showingMnemonic: Bool, token: SecretPresentationSession.Token) {
        guard canPresentSecret(for: token), let window = secretOwnerWindow,
              secretSession.store(secret, for: token) else { return }
        let presentation = NativeSecretAlertPresentation(
            session: secretSession,
            token: token,
            title: showingMnemonic ? Strings.secretWords : Strings.privateKey,
            canCopy: { [weak self] in self?.canPresentSecret(for: token) == true },
            didEnd: { [weak self] in
                guard let self, secretToken == token else { return }
                invalidateSecretPresentation()
            }
        )
        secretPresentation = presentation
        presentation.present(for: window)
    }
    
    private func updateCellModels() {
        cellModels = wallets.isEmpty
            ? [.addAccountOption(.createNew), .addAccountOption(.importExisting)]
            : WalletAccountListRow.makeRows(wallets: wallets).map(CellModel.wallet)
    }
    
    private func showMenuOnCellSelection(row: Int) {
        guard acceptsManagementActions else { return }
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
        
        return menu
    }
    
}

extension AccountsListViewController: AccountsHeaderDelegate {
    
    func didClickEditName(sender: NSTableRowView) {
        guard acceptsManagementActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        
        let initialText = WalletsMetadataService.getWalletName(wallet: wallet)
        let nameActionTitle = initialText == nil ? Strings.setName : Strings.editName
        presentTextInputAlert(
            title: nameActionTitle,
            initialText: initialText,
            placeholder: Strings.multicoinWallet
        ) { [weak self] newName in
            guard let self,
                  acceptsManagementActions else { return }
            if let newName {
                WalletsMetadataService.saveWalletName(newName, wallet: wallet)
                tableView.reloadData()
            }
        }
    }
    
    func didClickEditAccounts(sender: NSTableRowView) {
        guard acceptsManagementActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        
        let editAccountsViewController = instantiate(EditAccountsViewController.self)
        editAccountsViewController.wallet = wallet
        editAccountsViewController.getBackToRect = tableView.visibleRect
        view.window?.contentViewController = editAccountsViewController
        endAllSheets()
    }
    
    func didClickShowSecretWords(sender: NSTableRowView) {
        guard acceptsManagementActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeShowingKey(wallet: wallet, specificAccount: nil)
    }
    
    func didClickRemoveWallet(sender: NSTableRowView) {
        guard acceptsManagementActions else { return }
        let row = tableView.row(for: sender)
        guard let wallet = walletForRow(row) else { return }
        warnBeforeRemoving(wallet: wallet)
    }
    
}

extension AccountsListViewController: NSTableViewDelegate {

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard acceptsManagementActions,
              NSApp.currentEvent?.type == .keyDown,
              tableView.selectedRow >= 0,
              accountForRow(tableView.selectedRow) != nil else { return }
        showMenuOnCellSelection(row: tableView.selectedRow)
    }
    
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard acceptsManagementActions, cellModels.indices.contains(row) else { return false }
        if case .addAccountOption = cellModels[row] { return self.tableView.isHandlingKeyDown }
        guard accountForRow(row) != nil else { return false }
        return tableView.selectedRow < 0
    }
    
}

extension AccountsListViewController: NSTableViewDataSource {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        switch cellModels[row] {
        case .wallet(.account(let wallet, let account)):
            let rowView = tableView.makeViewOfType(AccountCellView.self)
            rowView.setup(account: account, walletId: wallet.id, isSelected: false, isDisabled: false)
            return rowView
        case .wallet(.mnemonicWalletHeader(let wallet)):
            let rowView = tableView.makeViewOfType(AccountsHeaderRowView.self)
            rowView.setup(walletName: WalletsMetadataService.getWalletName(wallet: wallet),
                multicoinWallet: true, delegate: acceptsManagementActions ? self : nil)
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
        switch cellModels[row] {
        case .wallet(.account): 50
        case .wallet: 27
        case .addAccountOption: 44
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { cellModels.count }
}

extension AccountsListViewController {

    private func closeManagement() {
        invalidateSecretPresentation()
        safariPreferencesTask?.cancel()
        safariPreferencesTask = nil
        walletMutationTasks.values.forEach { $0.cancel() }
        walletMutationTasks.removeAll()
        cancelMenuTracking()
        authenticationTask?.cancel()
        authenticationTask = nil
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

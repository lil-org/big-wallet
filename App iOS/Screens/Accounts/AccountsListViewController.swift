import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

import UIKit

class AccountsListViewController: WalletAccessViewController, DataStateContainer {
    
    enum Section {
        case privateKeyWallets(cellModels: [CellModel])
        case mnemonicWallet(cellModels: [CellModel], walletIndex: Int)
        
        var items: [CellModel] {
            switch self {
            case let .mnemonicWallet(cellModels: cellModels, _):
                return cellModels
            case let .privateKeyWallets(cellModels: cellModels):
                return cellModels
            }
        }
    }
    
    enum CellModel {
        case mnemonicAccount(walletIndex: Int, accountIndex: Int)
        case privateKeyAccount(walletIndex: Int, account: WalletAccount)
    }
    
    private var sections = [Section]()
    var walletsManager = ApplicationServices.shared.wallets
    var authenticate: @MainActor (UIViewController, String, String?, WalletAuthenticationChallenge) async -> WalletAuthenticationGrant? = {
        controller, reason, passwordReason, challenge in
        await LocalAuthentication.authorize(reason: reason, presentPasswordAlertFrom: { controller },
            passwordReason: passwordReason, challenge: challenge, credentials: ApplicationServices.shared.credentials)
    }
    private var layoutTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var keyExportTask: Task<Void, Never>?
    private var walletMutationTask: Task<Void, Never>?
    private var isVisibleForSecretPresentation = false
    private var storeActions = [UIAlertAction]()
    private var loadStatusView: UIStackView?
    private var loadStatusLabel: UILabel?
    private var loadSpinner: UIActivityIndicatorView?
    private(set) var loadRetryButton: UIButton?
    private var statusBottomInset: CGFloat = 0
    private weak var secretScene: UIWindowScene?
    private(set) lazy var secretPresentation = SecretAlertPresentation(isActive: { [weak self] in
        self?.canPresentSecret == true
    }, copy: { [weak self] secret in
        guard self?.beginWalletAction() == true else { return }
        SecretClipboard.shared.copy(secret)
    })

    var canPresentSecret: Bool {
        guard hasWalletAccess, walletsManager.isStoreReady, isVisibleForSecretPresentation, let window = viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive,
              secretScene == nil || window.windowScene === secretScene else { return false }
        return !isBeingDismissed && !isMovingFromParent &&
            navigationController?.isBeingDismissed != true
    }
    
    private var wallets: [WalletSnapshot] {
        return walletsManager.wallets
    }
    
    private var preferencesItem: UIBarButtonItem?
    private var addWalletItem: UIBarButtonItem?

    @IBOutlet weak var tableView: UITableView! {
        didSet {
            (tableView as? WalletActivityTableView)?.accessibilityInteraction = { [weak self] in
                self?.beginWalletAction() == true
            }
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: AccountTableViewCell.self)
            tableView.registerReusableHeaderFooter(type: AccountsHeaderView.self)
        }
    }
    
    isolated deinit {
        keyExportTask?.cancel()
        layoutTask?.cancel()
        loadTask?.cancel()
        authenticationTask?.cancel()
        walletMutationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisibleForSecretPresentation = false
        invalidateSecretPresentation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        layoutTask?.cancel()
        if isBeingDismissed || isMovingFromParent || view.window == nil {
            loadTask?.cancel()
            loadTask = nil
            authenticationTask?.cancel()
            keyExportTask?.cancel()
            walletMutationTask?.cancel()
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return screenshotMode ? true : super.prefersHomeIndicatorAutoHidden
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        configureAdaptiveLargeTitle(Strings.wallets, tableView: tableView)
        
        isModalInPresentation = true
        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addWallet))
        let preferencesItem = UIBarButtonItem(image: Images.preferences, style: UIBarButtonItem.Style.plain, target: self, action: #selector(preferencesButtonTapped))
        self.addWalletItem = addItem
        self.preferencesItem = preferencesItem
        navigationItem.rightBarButtonItems = [addItem, preferencesItem]
        configureDataState(.noData, description: Strings.nothingHere, buttonTitle: Strings.addWallet) { [weak self] in
            self?.addWallet()
        }
        configureDataState(.failedToLoad, description: Strings.failedToLoad, buttonTitle: Strings.tryAgain) { [weak self] in
            self?.retryWalletLoad()
        }
        dataStateShouldMoveWithKeyboard(false)
        setupLoadStatus()
        reloadData()
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: .walletsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletLoadStateChanged), name: .walletsLoadStateChanged, object: walletsManager)
        startLoadingIfNeeded()
        NotificationCenter.default.addObserver(self, selector: #selector(secretSceneDeactivated(_:)), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(secretSceneExited(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(secretSceneExited(_:)), name: UIScene.didDisconnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(secretProtectedDataUnavailable), name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdaptiveLargeTitleLayout(Strings.wallets, tableView: tableView)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisibleForSecretPresentation = true
        startLoadingIfNeeded()
    }

    override func walletAccessDidLock() {
        super.walletAccessDidLock()
        isVisibleForSecretPresentation = false
        invalidateSecretPresentation()
        authenticationTask?.cancel()
        authenticationTask = nil
        walletMutationTask?.cancel()
        walletMutationTask = nil
        loadTask?.cancel()
        loadTask = nil
        layoutTask?.cancel()
    }
    
    private func walletForIndexPath(_ indexPath: IndexPath) -> WalletSnapshot {
        let section = sections[indexPath.section]
        let items = section.items
        
        guard !items.isEmpty else {
            if case let .mnemonicWallet(_, walletIndex) = section {
                return wallets[walletIndex]
            } else {
                fatalError("no wallet")
            }
        }
        
        let item = items[indexPath.row]
        switch item {
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: _):
            return wallets[walletIndex]
        case let .privateKeyAccount(walletIndex: walletIndex, account: _):
            return wallets[walletIndex]
        }
    }
    
    private func accountForIndexPath(_ indexPath: IndexPath) -> WalletAccount {
        let item = sections[indexPath.section].items[indexPath.row]
        switch item {
        case let .mnemonicAccount(walletIndex: walletIndex, accountIndex: accountIndex):
            return wallets[walletIndex].accounts[accountIndex]
        case let .privateKeyAccount(walletIndex: _, account: account):
            return account
        }
    }
    
    private func updateCellModels() {
        sections = []
        var privateKeyAccountCellModels = [CellModel]()
        
        for index in 0..<wallets.count {
            let wallet = wallets[index]
            
            guard wallet.isMnemonic else {
                if let account = wallet.accounts.first {
                    privateKeyAccountCellModels.append(.privateKeyAccount(walletIndex: index, account: account))
                }
                continue
            }
            
            let accounts = wallet.accounts
            let cellModels = (0..<accounts.count).map { CellModel.mnemonicAccount(walletIndex: index, accountIndex: $0) }
            sections.append(.mnemonicWallet(cellModels: cellModels, walletIndex: index))
        }
        
        if !privateKeyAccountCellModels.isEmpty {
            sections.append(.privateKeyWallets(cellModels: privateKeyAccountCellModels))
        }
    }
    
    @objc private func walletsChanged() {
        guard hasWalletAccess else { return }
        reloadData()
    }
    
    private func updateDataState() {
        let failed: Bool
        switch walletsManager.loadState {
        case .failed: failed = true
        case .idle, .loading, .ready: failed = false
        }
        if walletsManager.isStoreReady {
            dataState = sections.isEmpty ? .noData : .hasData
        } else if !walletsManager.hasLoadedSnapshot || sections.isEmpty {
            dataState = failed ? .failedToLoad : .loading
        } else {
            dataState = .hasData
        }
        let showStatus = !sections.isEmpty && !walletsManager.isStoreReady
        loadStatusView?.isHidden = !showStatus
        loadStatusLabel?.text = failed ? Strings.failedToLoad : Strings.loading
        loadRetryButton?.isHidden = !failed
        loadRetryButton?.isEnabled = failed && loadTask == nil
        loadSpinner?.isHidden = failed
        if showStatus && !failed { loadSpinner?.startAnimating() }
        else { loadSpinner?.stopAnimating() }
        let inset: CGFloat = showStatus ? 68 : 0
        tableView.contentInset.bottom += inset - statusBottomInset
        tableView.verticalScrollIndicatorInsets.bottom += inset - statusBottomInset
        statusBottomInset = inset
        tableView.isScrollEnabled = !sections.isEmpty
        addWalletItem?.isEnabled = walletsManager.isStoreReady && view.isUserInteractionEnabled
        for action in storeActions { action.isEnabled = walletsManager.isStoreReady }
        for section in sections.indices {
            (tableView.headerView(forSection: section) as? AccountsHeaderView)?.editSectionButton.isEnabled = walletsManager.isStoreReady
        }
    }

    private func setupLoadStatus() {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        let spinner = UIActivityIndicatorView(style: .medium)
        let button = UIButton(type: .system)
        button.setTitle(Strings.tryAgain, for: .normal)
        button.accessibilityIdentifier = "wallet-load-retry"
        button.addTarget(self, action: #selector(retryWalletLoad), for: .touchUpInside)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let status = UIStackView(arrangedSubviews: [spinner, label, button])
        status.axis = .horizontal
        status.alignment = .center
        status.spacing = 12
        status.isLayoutMarginsRelativeArrangement = true
        status.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        status.backgroundColor = .secondarySystemGroupedBackground
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 68),
        ])
        loadStatusView = status
        loadStatusLabel = label
        loadSpinner = spinner
        loadRetryButton = button
    }

    @objc private func walletLoadStateChanged() {
        guard hasWalletAccess else { return }
        if !walletsManager.isStoreReady {
            invalidateSecretPresentation()
            if walletsManager.loadState != .loading {
                authenticationTask?.cancel()
                authenticationTask = nil
            }
        }
        updateDataState()
    }

    private func authenticateWhenStoreReady(
        reason: String, passwordReason: String?, challenge: WalletAuthenticationChallenge
    ) async -> WalletAuthenticationGrant? {
        guard let authorization = await authenticate(self, reason, passwordReason, challenge) else {
            challenge.invalidate()
            return nil
        }
        if !Task.isCancelled, hasWalletAccess, walletsManager.loadState == .loading {
            _ = await walletsManager.reloadFromStore()
        }
        guard !Task.isCancelled, hasWalletAccess, walletsManager.isStoreReady else {
            authorization.invalidate()
            return nil
        }
        return authorization
    }

    private func startLoadingIfNeeded() {
        switch walletsManager.loadState {
        case .idle, .loading: loadWallets(retry: false)
        case .ready, .failed: break
        }
    }

    @objc private func retryWalletLoad() {
        guard beginWalletAction() else { return }
        loadWallets(retry: true)
    }

    private func loadWallets(retry: Bool) {
        guard hasWalletAccess, loadTask == nil else { return }
        loadTask = Task { [weak self, walletsManager] in
            if retry { await walletsManager.reloadFromStore() }
            else { await walletsManager.start() }
            guard let self, !Task.isCancelled, hasWalletAccess else { return }
            loadTask = nil
            updateDataState()
        }
        updateDataState()
    }

    private func beginStoreAction() -> Bool {
        walletsManager.isStoreReady && beginWalletAction()
    }

    private func trackStoreActions(_ actions: [UIAlertAction]) {
        storeActions = actions
        for action in actions { action.isEnabled = walletsManager.isStoreReady }
    }
    
    private func reloadData() {
        let offset = tableView.contentOffset
        updateCellModels()
        tableView.reloadData()
        updateDataState()
        tableView.setContentOffset(offset, animated: false)
    }
    
    @objc private func preferencesButtonTapped() {
        guard beginWalletAction() else { return }
        let actionSheet = UIAlertController(title: Strings.bigWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = preferencesItem
        
        let appStoreAction = UIAlertAction(title: Strings.rateOnTheAppStore, style: .default) { [weak self] _ in
            guard self?.beginWalletAction() == true else { return }
            ReviewRequster.didClickAppStoreReviewButton()
        }
        
        let xAction = UIAlertAction(title: Strings.viewOnX, style: .default) { [weak self] _ in
            guard self?.beginWalletAction() == true else { return }
            UIApplication.shared.open(URL.x)
        }
        let githubAction = UIAlertAction(title: Strings.viewOnGithub, style: .default) { [weak self] _ in
            guard self?.beginWalletAction() == true else { return }
            UIApplication.shared.open(URL.github)
        }
        let emailAction = UIAlertAction(title: Strings.dropUsALine, style: .default) { [weak self] _ in
            guard self?.beginWalletAction() == true else { return }
            UIApplication.shared.open(URL.email)
        }
        let howToEnableSafariExtension = UIAlertAction(title: Strings.enableSafariExtension, style: .default) { [weak self] _ in
            guard self?.beginWalletAction() == true else { return }
            UIApplication.shared.open(URL.iosSafariGuide)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(howToEnableSafariExtension)
        actionSheet.addAction(appStoreAction)
        
        actionSheet.addAction(githubAction)
        actionSheet.addAction(emailAction)
        actionSheet.addAction(xAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    @objc private func addWallet() {
        guard beginStoreAction() else { return }
        let actionSheet = UIAlertController(title: Strings.addWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = addWalletItem
        let newAccountAction = UIAlertAction(title: Strings.createNew, style: .default) { [weak self] _ in
            self?.createNewWallet()
        }
        let importAccountAction = UIAlertAction(title: Strings.importExisting, style: .default) { [weak self] _ in
            self?.importExistingWallet()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(newAccountAction)
        actionSheet.addAction(importAccountAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func createNewWallet() {
        guard beginStoreAction() else { return }
        let alert = UIAlertController(title: Strings.backUpNewWallet, message: Strings.youWillSeeSecretWords, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { [weak self] _ in
            self?.createNewWalletAndShowSecretWords()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    private func createNewWalletAndShowSecretWords() {
        guard beginStoreAction(), let token = beginSecretPresentation() else { return }
        performWalletMutation(revealToken: token) { [walletsManager] session in
            try await walletsManager.createWallet(access: session)
        }
    }
    

    private func showKey(wallet: WalletSnapshot, specificAccount: WalletAccount?, authorization: WalletAuthenticationGrant) {
        guard hasWalletAccess, walletsManager.isStoreReady, let token = beginSecretPresentation() else {
            authorization.invalidate()
            return
        }
        let showingMnemonic = wallet.isMnemonic && specificAccount == nil
        keyExportTask?.cancel()
        keyExportTask = Task { [weak self, walletsManager] in
            guard let self, !Task.isCancelled, hasWalletAccess else { authorization.invalidate(); return }
            let secret: WalletExportedSecret
            do {
                if showingMnemonic {
                    secret = try await walletsManager.exportMnemonic(wallet: wallet, authorization: authorization)
                } else {
                    secret = try await walletsManager.exportPrivateKey(wallet: wallet, account: specificAccount, authorization: authorization)
                }
            } catch {
                secretPresentation.finish(token, copying: false)
                return
            }
            guard !Task.isCancelled, hasWalletAccess, secretPresentation.accepts(token) else { secret.invalidate(); return }
            presentSecret(secret, showingMnemonic: showingMnemonic, token: token)
        }
    }

    private func presentSecret(_ secret: WalletExportedSecret, showingMnemonic: Bool, token: SecretAlertPresentation.Token) {
        secretPresentation.show(secret, title: showingMnemonic ? Strings.secretWords : Strings.privateKey, token: token, from: self)
    }

    func beginSecretPresentation() -> SecretAlertPresentation.Token? {
        keyExportTask?.cancel()
        keyExportTask = nil
        secretScene = viewIfLoaded?.window?.windowScene
        return secretPresentation.begin()
    }

    private func invalidateSecretPresentation() {
        secretPresentation.invalidate()
        keyExportTask?.cancel()
        keyExportTask = nil
    }

    @objc private func secretSceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === secretScene || scene === viewIfLoaded?.window?.windowScene else { return }
        invalidateSecretPresentation()
    }

    @objc private func secretSceneExited(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene,
              scene === secretScene || scene === viewIfLoaded?.window?.windowScene else { return }
        invalidateSecretPresentation()
        authenticationTask?.cancel()
    }

    @objc private func secretProtectedDataUnavailable() {
        invalidateSecretPresentation()
        authenticationTask?.cancel()
    }
    
    private func importExistingWallet() {
        guard beginStoreAction() else { return }
        let importViewController = instantiate(ImportViewController.self, from: .main)
        importViewController.access = access
        present(importViewController.inNavigationController, animated: true)
    }
    
    private func showActionsForWallet(wallet: WalletSnapshot, headerView: AccountsHeaderView) {
        guard beginWalletAction() else { return }
        let currentName = ApplicationServices.shared.metadata.getWalletName(wallet: wallet)
        
        let actionSheet = UIAlertController(title: currentName ?? Strings.multicoinWallet, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = headerView.editSectionButton
        actionSheet.popoverPresentationController?.sourceRect = headerView.editSectionButton.bounds
        
        let editAction = UIAlertAction(title: Strings.editAccounts, style: .default) { [weak self] _ in
            guard let self, beginStoreAction() else { return }
            let editAccountsViewController = instantiate(EditAccountsViewController.self, from: .main)
            editAccountsViewController.wallet = wallet
            editAccountsViewController.access = access
            present(editAccountsViewController.inNavigationController, animated: true)
        }
        
        let nameActionTitle = currentName == nil ? Strings.setName : Strings.editName
        let nameAction = UIAlertAction(title: nameActionTitle, style: .default) { [weak self] _ in
            self?.didSelectNameActionForWallet(wallet)
        }
        
        let showKeyAction = UIAlertAction(title: Strings.showSecretWords, style: .default) { [weak self] _ in
            self?.didTapExportWallet(wallet, specificAccount: nil)
        }
        
        let removeAction = UIAlertAction(title: Strings.removeWallet, style: .destructive) { [weak self] _ in
            self?.askBeforeRemoving(wallet: wallet)
        }
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        
        trackStoreActions([editAction, nameAction, showKeyAction, removeAction])
        actionSheet.addAction(editAction)
        actionSheet.addAction(nameAction)
        actionSheet.addAction(showKeyAction)
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func didSelectNameActionForWallet(_ wallet: WalletSnapshot) {
        guard beginStoreAction() else { return }
        let initialText = ApplicationServices.shared.metadata.getWalletName(wallet: wallet)
        showTextInputAlert(title: initialText == nil ? Strings.setName : Strings.editName, message: nil, initialText: initialText, placeholder: Strings.multicoinWallet) { [weak self] newName in
            guard let self, beginStoreAction() else { return }
            if let newName = newName {
                ApplicationServices.shared.metadata.saveWalletName(newName, wallet: wallet)
                tableView.reloadData()
            }
        }
    }
    
    private func didSelectNameActionForAccount(_ account: WalletAccount, wallet: WalletSnapshot) {
        guard beginStoreAction() else { return }
        let initialText = account.name(walletId: wallet.id)
        let nameActionTitle = initialText == nil ? Strings.setName : Strings.editName
        showTextInputAlert(title: nameActionTitle, message: nil, initialText: initialText, placeholder: account.croppedAddress) { [weak self] newName in
            guard let self, beginStoreAction() else { return }
            if let newName = newName {
                ApplicationServices.shared.metadata.saveAccountName(newName, wallet: wallet, account: account)
                tableView.reloadData()
            }
        }
    }
    
    private func showActionsForAccount(_ account: WalletAccount, wallet: WalletSnapshot, cell: AccountTableViewCell?) {
        guard beginWalletAction() else { return }
        let actionSheet = UIAlertController(title: account.coin.name, message: account.address, preferredStyle: .actionSheet)
        let sourceView = cell?.moreButton ?? cell
        actionSheet.popoverPresentationController?.sourceView = sourceView
        actionSheet.popoverPresentationController?.sourceRect = sourceView?.bounds ?? .zero
        
        let copyAddressAction = UIAlertAction(title: Strings.copyAddress, style: .default) { [weak self] _ in
            guard self?.beginWalletAction() == true else { return }
            UIPasteboard.general.string = account.address
        }
        
        let showKeyTitle = wallet.isMnemonic ? Strings.showSecretWords : Strings.showPrivateKey
        let showKeyAction = UIAlertAction(title: showKeyTitle, style: .default) { [weak self] _ in
            self?.didTapExportWallet(wallet, specificAccount: nil)
        }
        
        let removeTitle = wallet.isMnemonic ? Strings.removeAccount : Strings.removeWallet
        let removeAction = UIAlertAction(title: removeTitle, style: .destructive) { [weak self] _ in
            if wallet.isMnemonic {
                self?.attemptToRemoveAccount(account, fromWallet: wallet)
            } else {
                self?.askBeforeRemoving(wallet: wallet)
            }
        }
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        
        for (name, url) in account.coin.explorersFor(address: account.address) {
            let explorerAction = UIAlertAction(title: name, style: .default) { [weak self] _ in
                guard self?.beginWalletAction() == true else { return }
                UIApplication.shared.open(url)
            }
            actionSheet.addAction(explorerAction)
        }
        
        actionSheet.addAction(copyAddressAction)
        
        let currentName = account.name(walletId: wallet.id)
        let nameActionTitle = currentName == nil ? Strings.setName : Strings.editName
        let nameAction = UIAlertAction(title: nameActionTitle, style: .default) { [weak self] _ in
            self?.didSelectNameActionForAccount(account, wallet: wallet)
        }
        actionSheet.addAction(nameAction)
        
        actionSheet.addAction(showKeyAction)
        var restricted = [nameAction, showKeyAction, removeAction]
        if wallet.isMnemonic {
            let showPrivateKeyAction = UIAlertAction(title: Strings.showPrivateKey, style: .default) { [weak self] _ in
                self?.didTapExportWallet(wallet, specificAccount: account)
            }
            actionSheet.addAction(showPrivateKeyAction)
            restricted.append(showPrivateKeyAction)
        }
        trackStoreActions(restricted)
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func attemptToRemoveAccount(_ account: WalletAccount, fromWallet wallet: WalletSnapshot) {
        guard beginStoreAction() else { return }
        guard wallet.accounts.count > 1 else {
            warnOnLastAccountRemovalAttempt(wallet: wallet)
            return
        }
        
        performWalletMutation { [walletsManager] session in
            try await walletsManager.update(wallet: wallet, removeAccounts: [account], access: session)
            return nil
        }
    }
    
    private func warnOnLastAccountRemovalAttempt(wallet: WalletSnapshot) {
        guard beginStoreAction() else { return }
        let alert = UIAlertController(title: Strings.removingTheLastAccount, message: nil, preferredStyle: .alert)
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            self?.askBeforeRemoving(wallet: wallet)
        }
        
        alert.addAction(cancelAction)
        alert.addAction(removeAction)
        
        present(alert, animated: true)
    }
    
    private func askBeforeRemoving(wallet: WalletSnapshot) {
        guard beginStoreAction() else { return }
        let alert = UIAlertController(title: Strings.removedWalletsCantBeRecovered, message: nil, preferredStyle: .alert)
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            self?.authenticateForRemoval(wallet)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(removeAction)
        present(alert, animated: true)
    }

    func authenticateForRemoval(_ wallet: WalletSnapshot) {
        guard beginStoreAction(), let scene = viewIfLoaded?.window?.windowScene else { return }
        authenticationTask?.cancel()
        authenticationTask = Task { [weak self, weak scene] in
            guard let self, !Task.isCancelled, hasWalletAccess else { return }
            let credentials = ApplicationServices.shared.credentials
            let challenge = credentials.makeWalletAccessChallenge()
            defer { challenge.invalidate() }
            let authorization = await authenticateWhenStoreReady(
                reason: Strings.removeWallet, passwordReason: Strings.toRemoveWallet, challenge: challenge)
            guard let authorization else { return }
            defer { authorization.invalidate() }
            guard let scene, !Task.isCancelled, hasWalletAccess, walletsManager.isStoreReady,
                  viewIfLoaded?.window?.windowScene === scene, scene.activationState == .foregroundActive,
                  let session = credentials.accessSession(authorization: authorization) else { return }
            defer { session.invalidate() }
            removeWallet(wallet)
        }
    }
    
    private func removeWallet(_ wallet: WalletSnapshot) {
        performWalletMutation { [walletsManager] session in
            try await walletsManager.delete(wallet: wallet, access: session)
            return nil
        }
    }

    private func performWalletMutation(
        revealToken: SecretAlertPresentation.Token? = nil,
        _ operation: @escaping @MainActor (WalletAccessSession) async throws -> WalletSnapshot?
    ) {
        guard beginStoreAction(), view.isUserInteractionEnabled else { return }
        setWalletMutationActive(true)
        walletMutationTask = Task { [weak self] in
            guard let self, !Task.isCancelled, hasWalletAccess else { return }
            do {
                let session = try requireCurrentAccess()
                let created = try await operation(session)
                guard !Task.isCancelled, hasWalletAccess else { return }
                setWalletMutationActive(false)
                reloadData()
                if let created, let revealToken, secretPresentation.accepts(revealToken) {
                    exportCreatedWalletSecret(created, token: revealToken)
                }
            } catch {
                if let revealToken { secretPresentation.finish(revealToken, copying: false) }
                guard !Task.isCancelled, hasWalletAccess else { return }
                setWalletMutationActive(false)
                showMessageAlert(text: Strings.somethingWentWrong)
            }
        }
    }

    private func exportCreatedWalletSecret(_ wallet: WalletSnapshot, token: SecretAlertPresentation.Token) {
        guard hasWalletAccess, let authorization = walletsManager.takeInitialBackupAuthorization(wallet: wallet) else {
            secretPresentation.finish(token, copying: false)
            return
        }
        keyExportTask?.cancel()
        keyExportTask = Task { [weak self, walletsManager] in
            guard let self, !Task.isCancelled, hasWalletAccess else { authorization.invalidate(); return }
            let secret = try? await walletsManager.exportMnemonic(wallet: wallet, authorization: authorization)
            guard !Task.isCancelled, hasWalletAccess, secretPresentation.accepts(token) else { secret?.invalidate(); return }
            guard let secret else {
                secretPresentation.finish(token, copying: false)
                return
            }
            presentSecret(secret, showingMnemonic: true, token: token)
        }
    }

    private func setWalletMutationActive(_ active: Bool) {
        view.isUserInteractionEnabled = !active
        addWalletItem?.isEnabled = !active && walletsManager.isStoreReady
        preferencesItem?.isEnabled = !active
    }
    

    private func didTapExportWallet(_ wallet: WalletSnapshot, specificAccount: WalletAccount?) {
        guard beginStoreAction() else { return }
        let willExportMnemonic = wallet.isMnemonic && specificAccount == nil
        let title = willExportMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        let alert = UIAlertController(title: title, message: specificAccount?.nameOrCroppedAddress(walletId: wallet.id), preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.iUnderstandTheRisks, style: .default) { [weak self] _ in
            self?.authenticateForExport(wallet, specificAccount: specificAccount)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }

    func authenticateForExport(_ wallet: WalletSnapshot, specificAccount: WalletAccount?) {
        guard beginStoreAction(), let scene = viewIfLoaded?.window?.windowScene else { return }
        let willExportMnemonic = wallet.isMnemonic && specificAccount == nil
        let reason = willExportMnemonic ? Strings.showSecretWords : Strings.showPrivateKey
        let passwordReason = willExportMnemonic ? Strings.toShowSecretWords : Strings.toShowPrivateKey
        authenticationTask?.cancel()
        authenticationTask = Task { [weak self, weak scene, walletsManager] in
            guard let self, !Task.isCancelled, hasWalletAccess else { return }
            let challenge: WalletAuthenticationChallenge
            do {
                challenge = try await walletsManager.makeExportChallenge(
                    wallet: wallet, account: specificAccount,
                    kind: willExportMnemonic ? .mnemonic : .privateKey
                )
            } catch { return }
            guard !Task.isCancelled, hasWalletAccess else { challenge.invalidate(); return }
            let authorization = await authenticateWhenStoreReady(
                reason: reason, passwordReason: passwordReason, challenge: challenge)
            guard let scene, let authorization, !Task.isCancelled, hasWalletAccess,
                  viewIfLoaded?.window?.windowScene === scene, canPresentSecret else {
                authorization?.invalidate()
                return
            }
            showKey(wallet: wallet, specificAccount: specificAccount, authorization: authorization)
        }
    }
    
}

extension AccountsListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return hasCurrentWalletPresentation && walletsManager.isStoreReady
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, beginStoreAction() else { return }
        let wallet = walletForIndexPath(indexPath)
        let account = accountForIndexPath(indexPath)
        
        if wallet.isMnemonic {
            attemptToRemoveAccount(account, fromWallet: wallet)
        } else {
            askBeforeRemoving(wallet: wallet)
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard beginWalletAction() else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        let wallet = walletForIndexPath(indexPath)
        let account = accountForIndexPath(indexPath)
        showActionsForAccount(account, wallet: wallet, cell: tableView.cellForRow(at: indexPath) as? AccountTableViewCell)
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return 15
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 37
    }
    
}

extension AccountsListViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].items.count
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(AccountTableViewCell.self, for: indexPath)
        let account = accountForIndexPath(indexPath)
        let wallet = walletForIndexPath(indexPath)
        cell.setup(title: account.nameOrCroppedAddress(walletId: wallet.id),
                   image: account.image,
                   delegate: self)
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let item = sections[section]
        let title: String
        let showsButton: Bool
        switch item {
        case .privateKeyWallets:
            title = Strings.privateKeyWallets
            showsButton = false
        case .mnemonicWallet(_, let index):
            let wallet = wallets[index]
            let name = ApplicationServices.shared.metadata.getWalletName(wallet: wallet)
            title = name ?? Strings.multicoinWallet
            showsButton = true
        }
        
        let headerView = tableView.dequeueReusableHeaderFooterOfType(AccountsHeaderView.self)
        headerView.set(title: title, showsButton: showsButton, sectionIndex: section, delegate: self)
        headerView.editSectionButton.isEnabled = walletsManager.isStoreReady
        return headerView
    }
    
}

extension AccountsListViewController: AccountsHeaderViewDelegate {
    
    func didTapEditButton(_ sender: AccountsHeaderView, sectionIndex: Int) {
        guard beginWalletAction() else { return }
        let wallet = walletForIndexPath(IndexPath(row: 0, section: sectionIndex))
        showActionsForWallet(wallet: wallet, headerView: sender)
    }
    
}

extension AccountsListViewController: AccountTableViewCellDelegate {
    
    func didTapMoreButton(accountCell: AccountTableViewCell) {
        guard beginWalletAction(), let indexPath = tableView.indexPath(for: accountCell) else { return }
        showActionsForAccount(accountForIndexPath(indexPath), wallet: walletForIndexPath(indexPath), cell: accountCell)
    }
    
}

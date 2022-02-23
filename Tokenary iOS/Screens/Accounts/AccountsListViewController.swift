// Copyright © 2021 Tokenary. All rights reserved.

import UIKit
// вызывается только из паролей
class AccountsListViewController: UIViewController, DataStateContainer {
    
    private let walletsManager = WalletsManager.shared // service
    private let keychain = Keychain.shared // service
    private let ethereum = Ethereum.shared // service
    
    private var chain = EthereumChain.ethereum // desimination
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)? // when used for presenting request from extension to select wallet
    // показывает когда меняем
    var forWalletSelection: Bool { // isCurrentlyUsed for wallet selection process
        return onSelectedWallet != nil
    }
    
    private var wallets: [TokenaryWallet] {
        return walletsManager.wallets // все волеты
    }
    
    private var toDismissAfterResponse = [Int: UIViewController]()
    private var preferencesItem: UIBarButtonItem? // кнопки в нав-баре
    private var addAccountItem: UIBarButtonItem?
    
    @IBOutlet weak var chainButton: UIButton! // кнопка выбора сетей эфира
    @IBOutlet weak var chainSelectionHeader: UIView! // хэдер содержащий эту кнопка
    @IBOutlet weak var tableView: UITableView! {
        didSet {
            tableView.delegate = self
            tableView.dataSource = self
            tableView.registerReusableCell(type: AccountTableViewCell.self)
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Be sure to call here (Keychain bug #)
        //  Or maybe there is problem with permissions
        if walletsManager.wallets.isEmpty {
            walletsManager.start()
        }
        // настройки тайтла
        navigationItem.title = forWalletSelection ? Strings.selectAccount : Strings.accounts
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        isModalInPresentation = true
        // добавление айтемов в нав-бар
        let addItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addAccount))
        let preferencesItem = UIBarButtonItem(image: Images.preferences, style: UIBarButtonItem.Style.plain, target: self, action: #selector(preferencesButtonTapped))
        let cancelItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelButtonTapped))
        self.addAccountItem = addItem
        self.preferencesItem = preferencesItem
        navigationItem.rightBarButtonItems = forWalletSelection ? [addItem] : [addItem, preferencesItem]
        if forWalletSelection {
            navigationItem.leftBarButtonItem = cancelItem
        }
        // сконфигурировать бэкграунд для вью - через DataStateContainer(просто добавить вью)
        configureDataState(.noData, description: Strings.tokenaryIsEmpty, buttonTitle: Strings.addAccount) { [weak self] in
            self?.addAccount()
        }
        // убираем кейборд, обновляем состояние бэкграунда
        updateDataState()
        // подписываемся на обновления
        NotificationCenter.default.addObserver(self, selector: #selector(processInput), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(walletsChanged), name: Notification.Name.walletsChanged, object: nil)
        // убираем кнопку если другой экран
        if !forWalletSelection {
            hideChainSelectionHeader()
        }
    }
    // при показе тоже процесим инпут, потому что
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        processInput()
        DispatchQueue.main.async { [weak self] in
            self?.navigationController?.navigationBar.sizeToFit()
        }
    }
    
    @objc private func processInput() {
        guard
            let url = launchURL?.absoluteString, url.hasPrefix(Constants.tokenarySchemePrefix),
            let request = SafariRequest(query: String(url.dropFirst(Constants.tokenarySchemePrefix.count)))
        else { return }
        
        launchURL = nil
        
        guard ExtensionBridge.hasRequest(id: request.id) else {
            respondTo(request: request, error: Strings.somethingWentWrong)
            return
        }
        
        let peerMeta = PeerMeta(title: request.host, iconURLString: request.iconURLString)
        switch request.method {
        case .switchAccount, .requestAccounts:
            let selectAccountViewController = instantiate(AccountsListViewController.self, from: .main)
            selectAccountViewController.onSelectedWallet = { [weak self] (chain, wallet) in
                guard let chain = chain, let address = wallet?.ethereumAddress else {
                    self?.respondTo(request: request, error: Strings.canceled)
                    return
                }
                let response = ResponseToExtension(id: request.id,
                                                   name: request.name,
                                                   results: [address],
                                                   chainId: chain.hexStringId,
                                                   rpcURL: chain.nodeURLString)
                self?.respondTo(request: request, response: response)
            }
            presentForSafariRequest(selectAccountViewController.inNavigationController, id: request.id)
        case .signTypedMessage:
            guard let raw = request.raw,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                respondTo(request: request, error: Strings.somethingWentWrong)
                return
            }
            showApprove(id: request.id, subject: .signTypedData, address: address, meta: raw, peerMeta: peerMeta) { [weak self] approved in
                if approved {
                    self?.signTypedData(wallet: wallet, raw: raw, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.failedToSign)
                }
            }
        case .signMessage:
            guard let data = request.message,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                respondTo(request: request, error: Strings.somethingWentWrong)
                return
            }
            showApprove(id: request.id, subject: .signMessage, address: address, meta: data.hexString, peerMeta: peerMeta) { [weak self] approved in
                if approved {
                    self?.signMessage(wallet: wallet, data: data, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.failedToSign)
                }
            }
        case .signPersonalMessage:
            guard let data = request.message,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                respondTo(request: request, error: Strings.somethingWentWrong)
                return
            }
            let text = String(data: data, encoding: .utf8) ?? data.hexString
            showApprove(id: request.id, subject: .signPersonalMessage, address: address, meta: text, peerMeta: peerMeta) { [weak self] approved in
                if approved {
                    self?.signPersonalMessage(wallet: wallet, data: data, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.failedToSign)
                }
            }
        case .signTransaction:
            guard let transaction = request.transaction,
                  let chain = request.chain,
                  let wallet = walletsManager.getWallet(address: request.address),
                  let address = wallet.ethereumAddress else {
                      respondTo(request: request, error: Strings.somethingWentWrong)
                      return
                  }
            showApprove(id: request.id, transaction: transaction, chain: chain, address: address, peerMeta: peerMeta) { [weak self] transaction in
                if let transaction = transaction {
                    self?.sendTransaction(wallet: wallet, transaction: transaction, chain: chain, request: request)
                } else {
                    self?.respondTo(request: request, error: Strings.canceled)
                }
            }
        case .ecRecover:
            if let (signature, message) = request.signatureAndMessage,
               let recovered = ethereum.recover(signature: signature, message: message) {
                let response = ResponseToExtension(id: request.id, name: request.name, result: recovered)
                respondTo(request: request, response: response)
            } else {
                respondTo(request: request, error: Strings.failedToVerify)
            }
        case .addEthereumChain, .switchEthereumChain, .watchAsset:
            respondTo(request: request, error: Strings.somethingWentWrong)
        }
    }
    // апрвувнуть эфир-транзакцию
    func showApprove(id: Int, transaction: Transaction, chain: EthereumChain, address: String, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) {
        let approveTransactionViewController = ApproveTransactionViewController.with(transaction: transaction,
                                                                                     chain: chain,
                                                                                     address: address,
                                                                                     peerMeta: peerMeta,
                                                                                     completion: completion)
        presentForSafariRequest(approveTransactionViewController.inNavigationController, id: id)
    }
    // апрувнуть эфир-действие на подписаниие чего-то(ApprovalSubject)
    func showApprove(id: Int, subject: ApprovalSubject, address: String, meta: String, peerMeta: PeerMeta?, completion: @escaping (Bool) -> Void) {
        let approveViewController = ApproveViewController.with(subject: subject, address: address, meta: meta, peerMeta: peerMeta, completion: completion)
        presentForSafariRequest(approveViewController.inNavigationController, id: id)
    }
    // идем до самого последнего презентованного контролера и показываем из него
    //  если самый верхний UIAlertController - мы его дисмисим
    // maybe rethink this logic
    private func presentForSafariRequest(_ viewController: UIViewController, id: Int) {
        var presentFrom: UIViewController = self
        while let presented = presentFrom.presentedViewController, !(presented is UIAlertController) {
            presentFrom = presented
        }
        if let alert = presentFrom.presentedViewController as? UIAlertController {
            alert.dismiss(animated: false)
        }
        presentFrom.present(viewController, animated: true)
        toDismissAfterResponse[id] = viewController
    }
    // запихивает в экстеншен ответ на респонс
    //  делает редирект на страницу
    //  и скрывает контролеры которые были вызваны в ответ на сафари-запрос
    //  а так же удаляет их из списка запроса
    private func respondTo(request: SafariRequest, response: ResponseToExtension) {
        ExtensionBridge.respond(id: request.id, response: response)
        UIApplication.shared.open(URL.blankRedirect(id: request.id)) { [weak self] _ in
            self?.toDismissAfterResponse[request.id]?.dismiss(animated: false)
            self?.toDismissAfterResponse.removeValue(forKey: request.id)
        }
    }
    // отправляет сафари что респонс завершился ошибкой
    private func respondTo(request: SafariRequest, error: String) {
        let response = ResponseToExtension(id: request.id, name: request.name, error: error)
        respondTo(request: request, response: response)
    }
    // прячет хэдер, если не происходит выбора чейна(значит обычный показ экрана)
    private func hideChainSelectionHeader() {
        chainSelectionHeader.isHidden = true
        chainSelectionHeader.frame = CGRect(origin: CGPoint.zero, size: CGSize.zero)
    }
    // нажатие на кнопку выбора чейнов, на самом деле существует только для сабчейнов эфира(или других штук где есть саб-чейны) 
    @IBAction func chainButtonTapped(_ sender: Any) {
        let actionSheet = UIAlertController(title: Strings.selectNetwork, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = chainButton
        for chain in EthereumChain.allMainnets {
            let action = UIAlertAction(title: chain.name, style: .default) { [weak self] _ in
                self?.didSelectChain(chain)
            }
            actionSheet.addAction(action)
        }
        let testnetsAction = UIAlertAction(title: Strings.testnets.withEllipsis, style: .default) { [weak self] _ in
            self?.showTestnets()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(testnetsAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    // показать тестнеты после того как мы показали все чейны
    private func showTestnets() {
        let actionSheet = UIAlertController(title: Strings.selectTestnet, message: nil, preferredStyle: .actionSheet)
        
//#if os(iPadOS)
        actionSheet.modalPresentationStyle = .popover
        if let presenter = actionSheet.popoverPresentationController {
            presenter.sourceView = chainButton
            presenter.sourceRect = chainButton.bounds
        }
//#endif
        
        for chain in EthereumChain.allTestnets {
            let action = UIAlertAction(title: chain.name, style: .default) { [weak self] _ in
                self?.didSelectChain(chain)
            }
            actionSheet.addAction(action)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    // выбрали чейн на котором мы хотим наши аккаунты
    // there is one special case here - when we come to change/request accounts
    //  with an empty provider -> this way we should have shown both both all-chains and their sub-chain info
    //  however for now, we just drop side-chain choosing and will implement this functionality later
    private func didSelectChain(_ chain: EthereumChain) {
        chainButton.configuration?.title = chain.name
        self.chain = chain
    }
    
    // This button is shown, only when we are in modal view, for selecting .change/.request action
    //  if cancel -> we send cancel event
    @objc private func cancelButtonTapped() {
        onSelectedWallet?(nil, nil)
    }
    // специальный кейс перезагрузить ячейки после того как добавили волет(создали/импорт)
    @objc private func walletsChanged() {
        reloadData()
    }
    // обновить дата-стейт, бэкграунд экрана - если будет .hasData, то скрыт, в противном случае будет показана заглушка
    //  и еще уберется скрол
    private func updateDataState() {
        let isEmpty = wallets.isEmpty
        dataState = isEmpty ? .noData : .hasData
        let canScroll = !isEmpty
        if tableView.isScrollEnabled != canScroll {
            tableView.isScrollEnabled = canScroll
        }
    }
    // вызывается каждый раз когда обновляется данные экрана
    private func reloadData() {
        updateDataState()
        tableView.reloadData()
    }
    // показывается когда нажимаем на префернсы
    //  в большистве своем, проосто открывает ссылки
    @objc private func preferencesButtonTapped() {
        let actionSheet = UIAlertController(title: "❤️ " + Strings.tokenary + " ❤️", message: "Show love 4269.eth", preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = preferencesItem
        let twitterAction = UIAlertAction(title: Strings.viewOnTwitter, style: .default) { _ in
            UIApplication.shared.open(URL.twitter)
        }
        let githubAction = UIAlertAction(title: Strings.viewOnGithub, style: .default) { _ in
            UIApplication.shared.open(URL.github)
        }
        let emailAction = UIAlertAction(title: Strings.dropUsALine.withEllipsis, style: .default) { _ in
            UIApplication.shared.open(URL.email)
        }
        let shareInvite = UIAlertAction(title: Strings.shareInvite.withEllipsis, style: .default) { [weak self] _ in
            let shareViewController = UIActivityViewController(activityItems: [URL.appStore], applicationActivities: nil)
            shareViewController.popoverPresentationController?.barButtonItem = self?.preferencesItem
            shareViewController.excludedActivityTypes = [.addToReadingList, .airDrop, .assignToContact, .openInIBooks, .postToFlickr, .postToVimeo, .markupAsPDF]
            self?.present(shareViewController, animated: true)
        }
        let howToEnableSafariExtension = UIAlertAction(title: Strings.howToEnableSafariExtension, style: .default) { _ in
            UIApplication.shared.open(URL.iosSafariGuide)
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(twitterAction)
        actionSheet.addAction(githubAction)
        actionSheet.addAction(emailAction)
        actionSheet.addAction(shareInvite)
        actionSheet.addAction(howToEnableSafariExtension)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    // добавить аккаунт дейсвие
    @objc private func addAccount() {
        let actionSheet = UIAlertController(title: Strings.addAccount, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.barButtonItem = addAccountItem
        let newAccountAction = UIAlertAction(title: "🌱 " + Strings.createNew, style: .default) { [weak self] _ in
            self?.createNewAccount()
        }
        let importAccountAction = UIAlertAction(title: Strings.importExisting, style: .default) { [weak self] _ in
            self?.importExistingAccount()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        actionSheet.addAction(newAccountAction)
        actionSheet.addAction(importAccountAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    // создать новый аккаунт из мнемоника
    private func createNewAccount() {
        let alert = UIAlertController(title: Strings.backUpNewAccount, message: Strings.youWillSeeSecretWords, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default) { [weak self] _ in
            self?.createNewAccountAndShowSecretWords()
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    // функция создает реальный аккаунт
    private func createNewAccountAndShowSecretWords() {
        guard let wallet = try? walletsManager.createWallet() else { return }
//        reloadData() - это не нужно, потому что walletsChange
        showKey(wallet: wallet, mnemonic: true)
    }
    // показывает реальный ключ
    private func showKey(wallet: TokenaryWallet, mnemonic: Bool) {
        let secret: String
        if mnemonic, let mnemonicString = try? walletsManager.exportMnemonic(wallet: wallet) {
            secret = mnemonicString
        } else if let data = try? walletsManager.exportPrivateKey(wallet: wallet) {
            secret = data.hexString
        } else {
            return
        }
        
        let alert = UIAlertController(title: mnemonic ? Strings.secretWords : Strings.privateKey, message: secret, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.ok, style: .default)
        let cancelAction = UIAlertAction(title: Strings.copy, style: .default) { _ in
            UIPasteboard.general.string = secret
        }
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    // импортировать существующий аккаунт 
    private func importExistingAccount() {
        let importAccountViewController = instantiate(ImportViewController.self, from: .main)
        present(importAccountViewController.inNavigationController, animated: true)
    }
    // при нажатии на ячейку или на more
    private func showActionsForWallet(_ wallet: TokenaryWallet, cell: UITableViewCell?) {
        let address = wallet.ethereumAddress ?? ""
        let actionSheet = UIAlertController(title: address, message: nil, preferredStyle: .actionSheet)
        actionSheet.popoverPresentationController?.sourceView = cell
        
        let copyAddressAction = UIAlertAction(title: Strings.copyAddress, style: .default) { _ in
            UIPasteboard.general.string = address
        }
        
        let etherscanAction = UIAlertAction(title: Strings.viewOnEtherscan, style: .default) { _ in
            UIApplication.shared.open(URL.etherscan(address: address))
        }
        
        let showKeyAction = UIAlertAction(title: Strings.showAccountKey, style: .default) { [weak self] _ in
            self?.didTapExportAccount(wallet)
        }
        
        let removeAction = UIAlertAction(title: Strings.removeAccount, style: .destructive) { [weak self] _ in
            self?.didTapRemoveAccount(wallet)
        }
        
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        
        actionSheet.addAction(copyAddressAction)
        actionSheet.addAction(etherscanAction)
        actionSheet.addAction(showKeyAction)
        actionSheet.addAction(removeAction)
        actionSheet.addAction(cancelAction)
        present(actionSheet, animated: true)
    }
    
    private func didTapRemoveAccount(_ wallet: TokenaryWallet) {
        askBeforeRemoving(wallet: wallet)
    }
    // спрашиваем хотим ли точно удалить аккаунт
    private func askBeforeRemoving(wallet: TokenaryWallet) {
        let alert = UIAlertController(title: Strings.removedAccountsCantBeRecovered, message: nil, preferredStyle: .alert)
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            LocalAuthentication.attempt(reason: Strings.removeAccount, presentPasswordAlertFrom: self, passwordReason: Strings.toRemoveAccount) { success in
                if success {
                    self?.removeWallet(wallet)
                }
            }
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(removeAction)
        present(alert, animated: true)
    }
    // удаляем аккаунт
    private func removeWallet(_ wallet: TokenaryWallet) {
        try? walletsManager.delete(wallet: wallet)
//        reloadData() не нужно потому что walletsChange
    }
    // экспортируем аккаунт
    // в конце просто получает ключ и показывает его
    private func didTapExportAccount(_ wallet: TokenaryWallet) {
        let isMnemonic = wallet.isMnemonic
        let title = isMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.iUnderstandTheRisks, style: .default) { [weak self] _ in
            LocalAuthentication.attempt(reason: Strings.removeAccount, presentPasswordAlertFrom: self, passwordReason: Strings.toShowAccountKey) { success in
                if success {
                    self?.showKey(wallet: wallet, mnemonic: isMnemonic)
                }
            }
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    // подписать персональное сообщение
    private func signPersonalMessage(wallet: TokenaryWallet, data: Data, request: SafariRequest) {
        if let signed = try? ethereum.signPersonalMessage(data: data, wallet: wallet) {
            let response = ResponseToExtension(id: request.id, name: request.name, result: signed)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSign)
        }
    }
    
    // подписать данные
    private func signTypedData(wallet: TokenaryWallet, raw: String, request: SafariRequest) {
        if let signed = try? ethereum.sign(typedData: raw, wallet: wallet) {
            let response = ResponseToExtension(id: request.id, name: request.name, result: signed)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSign)
        }
    }
    // подписать просто сообщение
    private func signMessage(wallet: TokenaryWallet, data: Data, request: SafariRequest) {
        if let signed = try? ethereum.sign(data: data, wallet: wallet) {
            let response = ResponseToExtension(id: request.id, name: request.name, result: signed)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSign)
        }
    }
    // подписать транзакицю
    private func sendTransaction(wallet: TokenaryWallet, transaction: Transaction, chain: EthereumChain, request: SafariRequest) {
        if let transactionHash = try? ethereum.send(transaction: transaction, wallet: wallet, chain: chain) {
            let response = ResponseToExtension(id: request.id, name: request.name, result: transactionHash)
            respondTo(request: request, response: response)
        } else {
            respondTo(request: request, error: Strings.failedToSend)
        }
    }
    
}

extension AccountsListViewController: UITableViewDelegate {
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    // удаляем элемент таблицы
    // использоваттся для ForEach в листе в виде onDelete(perform: )
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            askBeforeRemoving(wallet: wallets[indexPath.row])
        }
    }
    // что делам при нажатии
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let wallet = wallets[indexPath.row]
        if forWalletSelection {
            onSelectedWallet?(chain, wallet)
        } else {
            showActionsForWallet(wallet, cell: tableView.cellForRow(at: indexPath))
        }
    }
}

extension AccountsListViewController: UITableViewDataSource {
    // сколько акканутов
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return walletsManager.wallets.count
    }
    // просто сетап ечеек, и проксируем в них делегат
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCellOfType(AccountTableViewCell.self, for: indexPath)
        let wallet = wallets[indexPath.row]
        cell.setup(address: wallet.ethereumAddress ?? "", delegate: self)
        return cell
    }
    
}

extension AccountsListViewController: AccountTableViewCellDelegate {
    
    func didTapMoreButton(accountCell: AccountTableViewCell) {
        guard let index = tableView.indexPath(for: accountCell)?.row else { return }
        showActionsForWallet(wallets[index], cell: accountCell)
    }
    
}

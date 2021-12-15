// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa
import WalletConnect
import SafariServices
import LocalAuthentication

class Agent: NSObject {
    
    enum ExternalRequest {
        case wcSession(WCSession)
        case safari(SafariRequest)
    }
    
    static let shared = Agent()
    private lazy var statusImage = NSImage(named: "Status")
    
    private let walletConnect = WalletConnect.shared
    private let walletsManager = WalletsManager.shared
    private let ethereum = Ethereum.shared
    
    private override init() { super.init() }
    private var statusBarItem: NSStatusItem!
    private lazy var hasPassword = Keychain.shared.password != nil
    private var didEnterPasswordOnStart = false
    
    private var didStartInitialLAEvaluation = false
    private var didCompleteInitialLAEvaluation = false
    private var initialExternalRequest: ExternalRequest?
    
    var statusBarButtonIsBlocked = false
    
    func start() {
        checkPasteboardAndOpen()
        setupStatusBarItem()
    }
    
    func reopen() {
        checkPasteboardAndOpen()
    }
    
    func showInitialScreen(externalRequest: ExternalRequest?) {
        let isEvaluatingInitialLA = didStartInitialLAEvaluation && !didCompleteInitialLAEvaluation
        guard !isEvaluatingInitialLA else {
            if externalRequest != nil {
                initialExternalRequest = externalRequest
            }
            return
        }
        
        guard hasPassword else {
            let welcomeViewController = WelcomeViewController.new { [weak self] createdPassword in
                guard createdPassword else { return }
                self?.didEnterPasswordOnStart = true
                self?.didCompleteInitialLAEvaluation = true
                self?.hasPassword = true
                self?.showInitialScreen(externalRequest: externalRequest)
            }
            let windowController = Window.showNew()
            windowController.contentViewController = welcomeViewController
            return
        }
        
        guard didEnterPasswordOnStart else {
            askAuthentication(on: nil, onStart: true, reason: .start) { [weak self] success in
                if success {
                    self?.didEnterPasswordOnStart = true
                    self?.showInitialScreen(externalRequest: externalRequest)
                    self?.walletConnect.restartSessions()
                }
            }
            return
        }
        
        let request = externalRequest ?? initialExternalRequest
        initialExternalRequest = nil
        
        if case let .safari(request) = request {
            processSafariRequest(request)
        } else {
            let windowController = Window.showNew()
            let accountsList = instantiate(AccountsListViewController.self)
            
            if case let .wcSession(session) = request {
                accountsList.onSelectedWallet = onSelectedWallet(session: session)
            }
            
            windowController.contentViewController = accountsList
        }
    }
    
    func showApprove(transaction: Transaction, chain: EthereumChain, peerMeta: PeerMeta?, browser: Browser?, completion: @escaping (Transaction?) -> Void) {
        let windowController = Window.showNew()
        let approveViewController = ApproveTransactionViewController.with(transaction: transaction, chain: chain, peerMeta: peerMeta) { [weak self] transaction in
            if transaction != nil {
                self?.askAuthentication(on: windowController.window, onStart: false, reason: .sendTransaction) { success in
                    completion(success ? transaction : nil)
                    Window.closeAllAndActivateBrowser(force: browser)
                }
            } else {
                Window.closeAllAndActivateBrowser(force: browser)
                completion(nil)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func showApprove(subject: ApprovalSubject, meta: String, peerMeta: PeerMeta?, browser: Browser?, completion: @escaping (Bool) -> Void) {
        let windowController = Window.showNew()
        let approveViewController = ApproveViewController.with(subject: subject, meta: meta, peerMeta: peerMeta) { [weak self] result in
            if result {
                self?.askAuthentication(on: windowController.window, onStart: false, reason: subject.asAuthenticationReason) { success in
                    completion(success)
                    Window.closeAllAndActivateBrowser(force: browser)
                }
            } else {
                Window.closeAllAndActivateBrowser(force: browser)
                completion(result)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func showErrorMessage(_ message: String) {
        let windowController = Window.showNew()
        windowController.contentViewController = ErrorViewController.withMessage(message)
    }
    
    func getWalletSelectionCompletionIfShouldSelect() -> ((EthereumChain?, TokenaryWallet?) -> Void)? {
        let session = getSessionFromPasteboard()
        return onSelectedWallet(session: session)
    }
    
    lazy private var statusBarMenu: NSMenu = {
        let menu = NSMenu(title: Strings.tokenary)
        
        let showItem = NSMenuItem(title: Strings.showTokenary, action: #selector(didSelectShowMenuItem), keyEquivalent: "")
        let safariItem = NSMenuItem(title: Strings.enableSafariExtension.withEllipsis, action: #selector(enableSafariExtension), keyEquivalent: "")
        let mailItem = NSMenuItem(title: Strings.dropUsALine.withEllipsis, action: #selector(didSelectMailMenuItem), keyEquivalent: "")
        let githubItem = NSMenuItem(title: Strings.viewOnGithub.withEllipsis, action: #selector(didSelectGitHubMenuItem), keyEquivalent: "")
        let twitterItem = NSMenuItem(title: Strings.viewOnTwitter.withEllipsis, action: #selector(didSelectTwitterMenuItem), keyEquivalent: "")
        let quitItem = NSMenuItem(title: Strings.quit, action: #selector(didSelectQuitMenuItem), keyEquivalent: "q")
        showItem.attributedTitle = NSAttributedString(string: "👀 " + Strings.showTokenary, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
        
        showItem.target = self
        safariItem.target = self
        githubItem.target = self
        twitterItem.target = self
        mailItem.target = self
        quitItem.target = self
        
        menu.delegate = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(safariItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(twitterItem)
        menu.addItem(githubItem)
        menu.addItem(mailItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)
        return menu
    }()
    
    func warnBeforeQuitting(updateStatusBarAfterwards: Bool = false) {
        Window.activateWindow(nil)
        let alert = Alert()
        alert.messageText = Strings.quitTokenary
        alert.informativeText = Strings.youWontBeAbleToSignRequests
        alert.alertStyle = .warning
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
        if updateStatusBarAfterwards {
            setupStatusBarItem()
        }
    }
    
    @objc private func didSelectTwitterMenuItem() {
        NSWorkspace.shared.open(URL.twitter)
    }
    
    @objc private func didSelectGitHubMenuItem() {
        NSWorkspace.shared.open(URL.github)
    }
    
    @objc func enableSafariExtension() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Identifiers.safariExtensionBundle)
    }
    
    @objc private func didSelectMailMenuItem() {
        NSWorkspace.shared.open(URL.email)
    }
    
    @objc private func didSelectShowMenuItem() {
        checkPasteboardAndOpen()
    }
    
    @objc private func didSelectQuitMenuItem() {
        warnBeforeQuitting()
    }
    
    func setupStatusBarItem() {
        let statusBar = NSStatusBar.system
        statusBarItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.button?.image = statusImage
        statusBarItem.button?.target = self
        statusBarItem.button?.action = #selector(statusBarButtonClicked(sender:))
        statusBarItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    
    @objc private func statusBarButtonClicked(sender: NSStatusBarButton) {
        guard !statusBarButtonIsBlocked, let event = NSApp.currentEvent, event.type == .rightMouseUp || event.type == .leftMouseUp else { return }
        
        if let session = getSessionFromPasteboard() {
            showInitialScreen(externalRequest: .wcSession(session))
        } else {
            statusBarItem.menu = statusBarMenu
            statusBarItem.button?.performClick(nil)
        }
    }
    
    private func onSelectedWallet(session: WCSession?) -> ((EthereumChain?, TokenaryWallet?) -> Void)? {
        guard let session = session else { return nil }
        return { [weak self] chain, wallet in
            guard let chain = chain, let wallet = wallet else { return }
            self?.connectWallet(session: session, chainId: chain.id, wallet: wallet)
        }
    }
    
    private func getSessionFromPasteboard() -> WCSession? {
        let pasteboard = NSPasteboard.general
        let link = pasteboard.string(forType: .string) ?? ""
        let session = walletConnect.sessionWithLink(link)
        if session != nil {
            pasteboard.clearContents()
        }
        return session
    }
    
    private func checkPasteboardAndOpen() {
        let request: ExternalRequest?
        
        if let session = getSessionFromPasteboard() {
            request = .wcSession(session)
        } else {
            request = .none
        }
        
        showInitialScreen(externalRequest: request)
    }
    
    func askAuthentication(on: NSWindow?, getBackTo: NSViewController? = nil, onStart: Bool, reason: AuthenticationReason, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        let canDoLocalAuthentication = context.canEvaluatePolicy(policy, error: &error)
        
        func showPasswordScreen() {
            let window = on ?? Window.showNew().window
            let passwordViewController = PasswordViewController.with(mode: .enter, reason: reason) { [weak window] success in
                if let getBackTo = getBackTo {
                    window?.contentViewController = getBackTo
                } else {
                    Window.closeAll()
                }
                completion(success)
            }
            window?.contentViewController = passwordViewController
        }
        
        if canDoLocalAuthentication {
            context.localizedCancelTitle = Strings.cancel
            didStartInitialLAEvaluation = true
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason.title) { [weak self] success, _ in
                DispatchQueue.main.async {
                    self?.didCompleteInitialLAEvaluation = true
                    if !success, onStart, self?.didEnterPasswordOnStart == false {
                        showPasswordScreen()
                    }
                    completion(success)
                }
            }
        } else {
            showPasswordScreen()
        }
    }
    
    private func connectWallet(session: WCSession, chainId: Int, wallet: TokenaryWallet) {
        let windowController = Window.showNew()
        let window = windowController.window
        windowController.contentViewController = WaitingViewController.withReason(Strings.connecting)
        
        walletConnect.connect(session: session, chainId: chainId, walletId: wallet.id) { [weak window] _ in
            if window?.isVisible == true {
                Window.closeAllAndActivateBrowser(force: nil)
            }
        }
    }
    
    private func processSafariRequest(_ safariRequest: SafariRequest) {
        guard ExtensionBridge.hasRequest(id: safariRequest.id) else {
            respondToSafariRequest(safariRequest, error: Strings.somethingWentWrong)
            return
        }
                
        let peerMeta = PeerMeta(title: safariRequest.host, iconURLString: safariRequest.iconURLString)
        switch safariRequest.method {
        case .signPersonalMessage:
            guard let data = safariRequest.message else {
                respondToSafariRequest(safariRequest, error: Strings.somethingWentWrong)
                return
            }
            let text = String(data: data, encoding: .utf8) ?? data.hexString
            showApprove(subject: .signPersonalMessage, meta: text, peerMeta: peerMeta, browser: .safari) { [weak self] approved in
                if approved {
                    self?.signPersonalMessage(address: safariRequest.address, data: data, request: safariRequest)
                } else {
                    self?.respondToSafariRequest(safariRequest, error: Strings.failedToSign)
                }
            }
        case .requestAccounts, .switchAccount:
            let windowController = Window.showNew()
            let accountsList = instantiate(AccountsListViewController.self)
            
            accountsList.onSelectedWallet = { [weak self] chain, wallet in
                if let chain = chain, let wallet = wallet, let ethereumAddress = wallet.ethereumAddress {
                    let response = ResponseToExtension(id: safariRequest.id,
                                                       name: safariRequest.name,
                                                       results: [ethereumAddress],
                                                       chainId: chain.hexStringId,
                                                       rpcURL: chain.nodeURLString)
                    ExtensionBridge.respond(id: safariRequest.id, response: response)
                } else {
                    self?.respondToSafariRequest(safariRequest, error: Strings.canceled)
                }
                Window.closeAllAndActivateBrowser(force: .safari)
            }
            windowController.contentViewController = accountsList
        case .signMessage:
            guard let data = safariRequest.message else {
                respondToSafariRequest(safariRequest, error: Strings.somethingWentWrong)
                return
            }
            showApprove(subject: .signMessage, meta: data.hexString, peerMeta: peerMeta, browser: .safari) { [weak self] approved in
                if approved {
                    self?.signMessage(address: safariRequest.address, data: data, request: safariRequest)
                } else {
                    self?.respondToSafariRequest(safariRequest, error: Strings.failedToSign)
                }
            }
        case .signTypedMessage:
            guard let raw = safariRequest.raw else {
                respondToSafariRequest(safariRequest, error: Strings.somethingWentWrong)
                return
            }
            showApprove(subject: .signTypedData, meta: raw, peerMeta: peerMeta, browser: .safari) { [weak self] approved in
                if approved {
                    self?.signTypedData(address: safariRequest.address, raw: raw, request: safariRequest)
                } else {
                    self?.respondToSafariRequest(safariRequest, error: Strings.failedToSign)
                }
            }
        case .signTransaction:
            guard let transaction = safariRequest.transaction, let chain = safariRequest.chain else {
                respondToSafariRequest(safariRequest, error: Strings.somethingWentWrong)
                return
            }
            showApprove(transaction: transaction, chain: chain, peerMeta: peerMeta, browser: .safari) { [weak self] transaction in
                if let transaction = transaction {
                    self?.sendTransaction(transaction, address: safariRequest.address, chain: chain, request: safariRequest)
                } else {
                    self?.respondToSafariRequest(safariRequest, error: Strings.canceled)
                }
            }
        case .ecRecover:
            if let (signature, message) = safariRequest.signatureAndMessage,
               let recovered = ethereum.recover(signature: signature, message: message) {
                ExtensionBridge.respond(id: safariRequest.id, response: ResponseToExtension(id: safariRequest.id, name: safariRequest.name, result: recovered))
            } else {
                respondToSafariRequest(safariRequest, error: Strings.failedToVerify)
            }
            Window.closeAllAndActivateBrowser(force: .safari)
        case .switchEthereumChain, .addEthereumChain, .watchAsset:
            Window.closeAllAndActivateBrowser(force: .safari)
        }
    }
    
    private func respondToSafariRequest(_ safariRequest: SafariRequest, error: String) {
        ExtensionBridge.respond(id: safariRequest.id, response: ResponseToExtension(id: safariRequest.id, name: safariRequest.name, error: error))
    }
    
    private func sendTransaction(_ transaction: Transaction, address: String, chain: EthereumChain, request: SafariRequest) {
        if let wallet = walletsManager.getWallet(address: address),
           let transactionHash = try? ethereum.send(transaction: transaction, wallet: wallet, chain: chain) {
            ExtensionBridge.respond(id: request.id, response: ResponseToExtension(id: request.id, name: request.name, result: transactionHash))
        } else {
            respondToSafariRequest(request, error: Strings.failedToSend)
        }
    }
    
    private func signTypedData(address: String, raw: String, request: SafariRequest) {
        if let wallet = walletsManager.getWallet(address: address), let signed = try? ethereum.sign(typedData: raw, wallet: wallet) {
            ExtensionBridge.respond(id: request.id, response: ResponseToExtension(id: request.id, name: request.name, result: signed))
        } else {
            respondToSafariRequest(request, error: Strings.failedToSign)
        }
    }
    
    private func signMessage(address: String, data: Data, request: SafariRequest) {
        if let wallet = walletsManager.getWallet(address: address), let signed = try? ethereum.sign(data: data, wallet: wallet) {
            ExtensionBridge.respond(id: request.id, response: ResponseToExtension(id: request.id, name: request.name, result: signed))
        } else {
            respondToSafariRequest(request, error: Strings.failedToSign)
        }
    }
    
    private func signPersonalMessage(address: String, data: Data, request: SafariRequest) {
        if let wallet = walletsManager.getWallet(address: address), let signed = try? ethereum.signPersonalMessage(data: data, wallet: wallet) {
            ExtensionBridge.respond(id: request.id, response: ResponseToExtension(id: request.id, name: request.name, result: signed))
        } else {
            respondToSafariRequest(request, error: Strings.failedToSign)
        }
    }
    
}

extension Agent: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        statusBarItem.menu = nil
    }
    
}

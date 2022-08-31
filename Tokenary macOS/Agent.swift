// Copyright © 2021 Tokenary. All rights reserved.

import Cocoa
import WalletConnect
import SafariServices
import LocalAuthentication
import WalletCore

class Agent: NSObject {
    
    enum ExternalRequest {
        case wcSession(WCSession)
        case safari(SafariRequest)
    }
    
    static let shared = Agent()
    
    private let walletConnect = WalletConnect.shared
    private let walletsManager = WalletsManager.shared
    
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
            let windowController = Window.showNew(closeOthers: true)
            windowController.contentViewController = welcomeViewController
            return
        }
        
        guard didEnterPasswordOnStart else {
            askAuthentication(on: nil, browser: nil, onStart: true, reason: .start) { [weak self] success in
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
            let accountsList = instantiate(AccountsListViewController.self)
            
            if case let .wcSession(session) = request, let completion = onSelectedWallet(session: session) {
                accountsList.selectAccountAction = SelectAccountAction(peer: nil,
                                                                       coinType: .ethereum,
                                                                       selectedAccounts: Set(walletsManager.suggestedAccounts(coin: .ethereum)),
                                                                       initiallyConnectedProviders: Set(),
                                                                       network: nil,
                                                                       source: .walletConnect,
                                                                       completion: completion)
            }
            
            let windowController = Window.showNew(closeOthers: accountsList.selectAccountAction == nil)
            windowController.contentViewController = accountsList
        }
    }
    
    func showApprove(windowController: NSWindowController, browser: Browser?, transaction: Transaction, chain: EthereumChain, peerMeta: PeerMeta?, completion: @escaping (Transaction?) -> Void) {
        let window = windowController.window
        let approveViewController = ApproveTransactionViewController.with(transaction: transaction, chain: chain, peerMeta: peerMeta) { [weak self, weak window] transaction in
            if transaction != nil {
                self?.askAuthentication(on: window, browser: browser, onStart: false, reason: .sendTransaction) { success in
                    completion(success ? transaction : nil)
                }
            } else {
                completion(nil)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func showApprove(windowController: NSWindowController, browser: Browser?, subject: ApprovalSubject, meta: String, peerMeta: PeerMeta?, completion: @escaping (Bool) -> Void) {
        let window = windowController.window
        let approveViewController = ApproveViewController.with(subject: subject, meta: meta, peerMeta: peerMeta) { [weak self, weak window] result in
            if result {
                self?.askAuthentication(on: window, getBackTo: window?.contentViewController, browser: browser, onStart: false, reason: subject.asAuthenticationReason) { success in
                    completion(success)
                    (window?.contentViewController as? ApproveViewController)?.enableWaiting()
                }
            } else {
                completion(result)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func getWalletSelectionCompletionIfShouldSelect() -> ((EthereumChain?, [SpecificWalletAccount]?) -> Void)? {
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
        
        DispatchQueue.main.async { [weak self] in
            if alert.runModal() == .alertFirstButtonReturn {
                NSApp.terminate(nil)
            }
            if updateStatusBarAfterwards {
                self?.setupStatusBarItem()
            }
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
        statusBarItem.button?.image = Images.statusBarIcon
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
    
    private func onSelectedWallet(session: WCSession?) -> ((EthereumChain?, [SpecificWalletAccount]?) -> Void)? {
        guard let session = session else { return nil }
        return { [weak self] chain, specificWalletAccounts in
            guard let chain = chain, let specificWalletAccount = specificWalletAccounts?.first, specificWalletAccount.account.coin == .ethereum else {
                Window.closeAllAndActivateBrowser(specific: nil)
                return
            }
            self?.connectWallet(session: session, chainId: chain.id, walletId: specificWalletAccount.walletId)
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
    
    func askAuthentication(on: NSWindow?, getBackTo: NSViewController? = nil, browser: Browser?, onStart: Bool, reason: AuthenticationReason, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        let canDoLocalAuthentication = context.canEvaluatePolicy(policy, error: &error)
        
        func showPasswordScreen() {
            let window = on ?? Window.showNew(closeOthers: onStart).window
            let passwordViewController = PasswordViewController.with(mode: .enter, reason: reason) { [weak window] success in
                if let getBackTo = getBackTo {
                    window?.contentViewController = getBackTo
                } else if let browser = browser {
                    Window.closeWindowAndActivateNext(idToClose: window?.windowNumber, specificBrowser: browser)
                } else {
                    Window.closeWindow(idToClose: window?.windowNumber)
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
    
    private func connectWallet(session: WCSession, chainId: Int, walletId: String) {
        let windowController = Window.showNew(closeOthers: true)
        let window = windowController.window
        windowController.contentViewController = WaitingViewController.withReason(Strings.connecting)
        
        walletConnect.connect(session: session, chainId: chainId, walletId: walletId) { [weak window] _ in
            if window?.isVisible == true {
                Window.closeAllAndActivateBrowser(specific: nil)
            }
        }
    }

    private func processSafariRequest(_ safariRequest: SafariRequest) {
        var windowNumber: Int?
        let action = DappRequestProcessor.processSafariRequest(safariRequest) {
            Window.closeWindowAndActivateNext(idToClose: windowNumber, specificBrowser: .safari)
        }

        switch action {
        case .none:
            break
        case .selectAccount(let accountAction), .switchAccount(let accountAction):
            let closeOtherWindows: Bool
            if case .selectAccount = action {
                closeOtherWindows = false
            } else {
                closeOtherWindows = true
            }
            
            let windowController = Window.showNew(closeOthers: closeOtherWindows)
            windowNumber = windowController.window?.windowNumber
            let accountsList = instantiate(AccountsListViewController.self)
            accountsList.selectAccountAction = accountAction
            windowController.contentViewController = accountsList
        case .approveMessage(let action):
            let windowController = Window.showNew(closeOthers: false)
            windowNumber = windowController.window?.windowNumber
            showApprove(windowController: windowController, browser: .safari, subject: action.subject, meta: action.meta, peerMeta: action.peerMeta, completion: action.completion)
        case .approveTransaction(let action):
            let windowController = Window.showNew(closeOthers: false)
            windowNumber = windowController.window?.windowNumber
            showApprove(windowController: windowController, browser: .safari, transaction: action.transaction, chain: action.chain, peerMeta: action.peerMeta, completion: action.completion)
        case .justShowApp:
            let windowController = Window.showNew(closeOthers: true)
            windowNumber = windowController.window?.windowNumber
            let accountsList = instantiate(AccountsListViewController.self)
            windowController.contentViewController = accountsList
        }
    }
    
}

extension Agent: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        statusBarItem.menu = nil
    }
    
}

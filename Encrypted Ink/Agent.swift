// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa
import WalletConnect
import LocalAuthentication

class Agent: NSObject {

    static let shared = Agent()
    private lazy var statusImage = NSImage(named: "Status")
    
    private override init() { super.init() }
    private var statusBarItem: NSStatusItem!
    private var hasPassword = Keychain.shared.password != nil
    private var didEnterPasswordOnStart = false
    
    private var didStartInitialLAEvaluation = false
    private var didCompleteInitialLAEvaluation = false
    private var initialWCSession: WCSession?
    
    var statusBarButtonIsBlocked = false
    
    func start() {
        checkPasteboardAndOpen()
        setupStatusBarItem()
    }
    
    func reopen() {
        checkPasteboardAndOpen()
    }
    
    func showInitialScreen(wcSession: WCSession?) {
        let isEvaluatingInitialLA = didStartInitialLAEvaluation && !didCompleteInitialLAEvaluation
        guard !isEvaluatingInitialLA else {
            if wcSession != nil {
                initialWCSession = wcSession
            }
            return
        }
        
        guard hasPassword else {
            let welcomeViewController = WelcomeViewController.new { [weak self] createdPassword in
                guard createdPassword else { return }
                self?.didEnterPasswordOnStart = true
                self?.didCompleteInitialLAEvaluation = true
                self?.hasPassword = true
                self?.showInitialScreen(wcSession: wcSession)
            }
            let windowController = Window.showNew()
            windowController.contentViewController = welcomeViewController
            return
        }
        
        guard didEnterPasswordOnStart else {
            askAuthentication(on: nil, onStart: true, reason: "Start") { [weak self] success in
                if success {
                    self?.didEnterPasswordOnStart = true
                    self?.showInitialScreen(wcSession: wcSession)
                    WalletConnect.shared.restartSessions()
                }
            }
            return
        }
        
        let session: WCSession?
        if wcSession == nil, initialWCSession != nil {
            session = initialWCSession
            initialWCSession = nil
        } else {
            session = wcSession
        }
        
        let windowController = Window.showNew()
        let completion = onSelectedWallet(session: session)
        let accountsList = instantiate(AccountsListViewController.self)
        accountsList.onSelectedWallet = completion
        windowController.contentViewController = accountsList
    }
    
    func showApprove(transaction: Transaction, chain: EthereumChain, peerMeta: WCPeerMeta?, completion: @escaping (Transaction?) -> Void) {
        let windowController = Window.showNew()
        let approveViewController = ApproveTransactionViewController.with(transaction: transaction, chain: chain, peerMeta: peerMeta) { [weak self] transaction in
            if transaction != nil {
                self?.askAuthentication(on: windowController.window, onStart: false, reason: Strings.sendTransaction) { success in
                    completion(success ? transaction : nil)
                    Window.closeAllAndActivateBrowser()
                }
            } else {
                Window.closeAllAndActivateBrowser()
                completion(nil)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func showApprove(title: String, meta: String, peerMeta: WCPeerMeta?, completion: @escaping (Bool) -> Void) {
        let windowController = Window.showNew()
        let approveViewController = ApproveViewController.with(title: title, meta: meta, peerMeta: peerMeta) { [weak self] result in
            if result {
                self?.askAuthentication(on: windowController.window, onStart: false, reason: title) { success in
                    completion(success)
                    Window.closeAllAndActivateBrowser()
                }
            } else {
                Window.closeAllAndActivateBrowser()
                completion(result)
            }
        }
        windowController.contentViewController = approveViewController
    }
    
    func showErrorMessage(_ message: String) {
        let windowController = Window.showNew()
        windowController.contentViewController = ErrorViewController.withMessage(message)
    }
    
    func processInputLink(_ link: String) {
        let session = sessionWithLink(link)
        showInitialScreen(wcSession: session)
    }
    
    func getWalletSelectionCompletionIfShouldSelect() -> ((Int, InkWallet) -> Void)? {
        let session = getSessionFromPasteboard()
        return onSelectedWallet(session: session)
    }
    
    lazy private var statusBarMenu: NSMenu = {
        let menu = NSMenu(title: "Encrypted Ink")
        
        let showItem = NSMenuItem(title: "Show Encrypted Ink", action: #selector(didSelectShowMenuItem), keyEquivalent: "")
        let howToItem = NSMenuItem(title: "How to WalletConnect?", action: #selector(showInstructionsAlert), keyEquivalent: "")
        let mailItem = NSMenuItem(title: "Drop us a line…", action: #selector(didSelectMailMenuItem), keyEquivalent: "")
        let githubItem = NSMenuItem(title: "View on GitHub…", action: #selector(didSelectGitHubMenuItem), keyEquivalent: "")
        let twitterItem = NSMenuItem(title: "Follow on Twitter…", action: #selector(didSelectTwitterMenuItem), keyEquivalent: "")
        let quitItem = NSMenuItem(title: "Quit", action: #selector(didSelectQuitMenuItem), keyEquivalent: "q")
        showItem.attributedTitle = NSAttributedString(string: "👀 Show Encrypted Ink", attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
        
        showItem.target = self
        howToItem.target = self
        githubItem.target = self
        twitterItem.target = self
        mailItem.target = self
        quitItem.target = self
        
        menu.delegate = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(howToItem)
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
        alert.messageText = "Quit Encrypted Ink?"
        alert.informativeText = "You won't be able to sign requests."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
        if updateStatusBarAfterwards {
            setupStatusBarItem()
        }
    }
    
    @objc private func didSelectTwitterMenuItem() {
        if let url = URL(string: "https://encrypted.ink/twitter") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func didSelectGitHubMenuItem() {
        if let url = URL(string: "https://github.com/zeriontech/Encrypted-Ink") {
            NSWorkspace.shared.open(url)
        }
    }
    
    @objc private func showInstructionsAlert() {
        Window.activateWindow(nil)
        Alert.showWalletConnectInstructions()
    }
    
    @objc private func didSelectMailMenuItem() {
        if let url = URL(string: "mailto:support@encrypted.ink") {
            NSWorkspace.shared.open(url)
        }
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
            showInitialScreen(wcSession: session)
        } else {
            statusBarItem.menu = statusBarMenu
            statusBarItem.button?.performClick(nil)
        }
    }
    
    private func onSelectedWallet(session: WCSession?) -> ((Int, InkWallet) -> Void)? {
        guard let session = session else { return nil }
        return { [weak self] chainId, wallet in
            self?.connectWallet(session: session, chainId: chainId, wallet: wallet)
        }
    }
    
    private func getSessionFromPasteboard() -> WCSession? {
        let pasteboard = NSPasteboard.general
        let link = pasteboard.string(forType: .string) ?? ""
        let session = sessionWithLink(link)
        if session != nil {
            pasteboard.clearContents()
        }
        return session
    }
    
    private func checkPasteboardAndOpen() {
        let session = getSessionFromPasteboard()
        showInitialScreen(wcSession: session)
    }
    
    private func sessionWithLink(_ link: String) -> WCSession? {
        return WalletConnect.shared.sessionWithLink(link)
    }
    
    func askAuthentication(on: NSWindow?, getBackTo: NSViewController? = nil, onStart: Bool, reason: String, completion: @escaping (Bool) -> Void) {
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
            context.localizedCancelTitle = "Cancel"
            didStartInitialLAEvaluation = true
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) { [weak self] success, _ in
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
    
    private func connectWallet(session: WCSession, chainId: Int, wallet: InkWallet) {
        let windowController = Window.showNew()
        let window = windowController.window
        windowController.contentViewController = WaitingViewController.withReason("Connecting")
        
        WalletConnect.shared.connect(session: session, chainId: chainId, walletId: wallet.id) { [weak window] _ in
            if window?.isVisible == true {
                Window.closeAllAndActivateBrowser()
            }
        }
    }
    
}

extension Agent: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        statusBarItem.menu = nil
    }
    
}

// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa
import WalletConnect
import LocalAuthentication

class Agent: NSObject {

    static let shared = Agent()
    private lazy var statusImage = NSImage(named: "Status")
    
    private override init() { super.init() }
    private var statusBarItem: NSStatusItem!
    private var hasPassword = Keychain.password != nil
    
    func start() {
        checkPasteboardAndOpen(onAppStart: true)
    }
    
    func reopen() {
        checkPasteboardAndOpen(onAppStart: false)
    }
    
    func showInitialScreen(onAppStart: Bool, wcSession: WCSession?) {
        let windowController: NSWindowController
        if onAppStart, let currentWindowController = Window.current {
            windowController = currentWindowController
            Window.activate(windowController)
        } else {
            windowController = Window.showNew()
        }
        
        guard hasPassword else {
            let welcomeViewController = WelcomeViewController.new { [weak self] createdPassword in
                guard createdPassword else { return }
                self?.hasPassword = true
                self?.showInitialScreen(onAppStart: onAppStart, wcSession: wcSession)
            }
            windowController.contentViewController = welcomeViewController
            return
        }
        
        let completion = onSelectedAccount(session: wcSession)
        let accounts = AccountsService.getAccounts()
        if !accounts.isEmpty {
            let accountsList = AccountsListViewController.with(preloadedAccounts: accounts)
            accountsList.onSelectedAccount = completion
            windowController.contentViewController = accountsList
        } else {
            let importViewController = instantiate(ImportViewController.self)
            importViewController.onSelectedAccount = completion
            windowController.contentViewController = importViewController
        }
    }
    
    func showApprove(title: String, meta: String, completion: @escaping (Bool) -> Void) {
        let windowController = Window.showNew()
        let approveViewController = ApproveViewController.with(title: title, meta: meta) { [weak self] result in
            Window.closeAll()
            Window.activateBrowser()
            if result {
                self?.proceedAfterAuthentication(reason: title, completion: completion)
            } else {
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
        showInitialScreen(onAppStart: false, wcSession: session)
    }
    
    func getAccountSelectionCompletionIfShouldSelect() -> ((Account) -> Void)? {
        let session = getSessionFromPasteboard()
        return onSelectedAccount(session: session)
    }
    
    lazy private var statusBarMenu: NSMenu = {
        let menu = NSMenu(title: "Encrypted Ink")
        let quitItem = NSMenuItem(title: "Quit", action: #selector(didSelectQuitMenuItem), keyEquivalent: "q")
        quitItem.target = self
        menu.delegate = self
        menu.addItem(quitItem)
        return menu
    }()
    
    @objc private func didSelectQuitMenuItem() {
        Window.activateWindow(nil)
        let alert = NSAlert()
        alert.messageText = "Quit Encrypted Ink?"
        alert.informativeText = "It will not be able to show sign requests."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
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
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            statusBarItem.menu = statusBarMenu
            statusBarItem.button?.performClick(nil)
        } else {
            checkPasteboardAndOpen(onAppStart: false)
        }
    }
    
    private func onSelectedAccount(session: WCSession?) -> ((Account) -> Void)? {
        guard let session = session else { return nil }
        return { [weak self] account in
            self?.connectWallet(session: session, account: account)
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
    
    private func checkPasteboardAndOpen(onAppStart: Bool) {
        let session = getSessionFromPasteboard()
        showInitialScreen(onAppStart: onAppStart, wcSession: session)
    }
    
    private func sessionWithLink(_ link: String) -> WCSession? {
        return WalletConnect.shared.sessionWithLink(link)
    }
    
    func proceedAfterAuthentication(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true)
            return
        }
        
        context.localizedCancelTitle = "Cancel"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason ) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
    }
    
    private func connectWallet(session: WCSession, account: Account) {
        WalletConnect.shared.connect(session: session, address: account.address) { [weak self] connected in
            if connected {
                Window.closeAll()
                Window.activateBrowser()
            } else {
                self?.showErrorMessage("Failed to connect")
            }
        }
        
        let windowController = Window.showNew()
        windowController.contentViewController = WaitingViewController.withReason("Connecting")
    }
    
}

extension Agent: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        statusBarItem.menu = nil
    }
    
}

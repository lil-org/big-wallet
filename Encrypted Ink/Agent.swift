// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa
import WalletConnect

class Agent {

    static let shared = Agent()
    
    private init() {}
    private var statusBarItem: NSStatusItem!
    
    func start() {
        showInitialScreen(onAppStart: true, wcSession: nil)
    }
    
    func reopen() {
        showInitialScreen(onAppStart: false, wcSession: nil)
    }
    
    func showInitialScreen(onAppStart: Bool, wcSession: WCSession?) {
        let windowController: NSWindowController
        if onAppStart, let currentWindowController = Window.current {
            windowController = currentWindowController
            Window.activate(windowController)
        } else {
            windowController = Window.showNew()
        }
        
        var onSelectedAccount: ((Account) -> Void)?
        if let wcSession = wcSession {
            onSelectedAccount = { [weak self] account in
                self?.connectWallet(session: wcSession, account: account)
            }
        }
        
        let accounts = AccountsService.getAccounts()
        if !accounts.isEmpty {
            let accountsList = AccountsListViewController.with(preloadedAccounts: accounts)
            accountsList.onSelectedAccount = onSelectedAccount
            windowController.contentViewController = accountsList
        } else {
            let importViewController = instantiate(ImportViewController.self)
            importViewController.onSelectedAccount = onSelectedAccount
            windowController.contentViewController = importViewController
        }
    }
    
    func showApprove(title: String, meta: String, completion: @escaping (Bool) -> Void) {
        let windowController = Window.showNew()
        let approveViewController = ApproveViewController.with(title: title, meta: meta) { result in
            completion(result)
            Window.closeAll()
            Window.activateSafari()
        }
        windowController.contentViewController = approveViewController
    }
    
    func showErrorMessage(_ message: String) {
        let windowController = Window.showNew()
        windowController.contentViewController = ErrorViewController.withMessage(message)
    }
    
    func setupStatusBarItem() {
        let statusBar = NSStatusBar.system
        statusBarItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        statusBarItem.button?.title = "🍎"
        statusBarItem.button?.target = self
        statusBarItem.button?.action = #selector(statusBarButtonClicked(sender:))
        statusBarItem.button?.sendAction(on: [.leftMouseUp])
    }
    
    @objc private func statusBarButtonClicked(sender: NSStatusBarButton) {
        let pasteboard = NSPasteboard.general
        let link = pasteboard.string(forType: .string) ?? ""
        pasteboard.clearContents()
        let session = WalletConnect.shared.sessionWithLink(link)
        showInitialScreen(onAppStart: false, wcSession: session)
    }
    
    private func connectWallet(session: WCSession, account: Account) {
        WalletConnect.shared.connect(session: session, address: account.address) { [weak self] connected in
            if connected {
                Window.closeAll()
                Window.activateSafari()
            } else {
                self?.showErrorMessage("Failed to connect")
            }
        }
        
        let windowController = Window.showNew()
        windowController.contentViewController = WaitingViewController.withReason("Connecting")
    }
    
}

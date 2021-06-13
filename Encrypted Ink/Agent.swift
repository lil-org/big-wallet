// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class Agent {

    static let shared = Agent()
    private var connectivity: NearbyConnectivity!
    
    private init() {}
    
    func start() {
        connectivity = NearbyConnectivity(delegate: self)
        showInitialScreen(onAppStart: true, wcLink: nil)
    }
    
    func reopen() {
        showInitialScreen(onAppStart: false, wcLink: nil)
    }
    
    func showInitialScreen(onAppStart: Bool, wcLink: String?) {
        let windowController: NSWindowController
        if onAppStart, let currentWindowController = Window.current {
            windowController = currentWindowController
            Window.activate(windowController)
        } else {
            windowController = Window.showNew()
        }
        
        var onSelectedAccount: ((Account) -> Void)?
        if let link = wcLink {
            onSelectedAccount = { [weak self] account in
                self?.connectWalletWithLink(link, account: account)
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
    
    private func connectWalletWithLink(_ link: String, account: Account) {
        WalletConnect.shared.connect(link: link, address: account.address) { [weak self] connected in
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

extension Agent: NearbyConnectivityDelegate {
    
    func didFind(link: String) {
        showInitialScreen(onAppStart: false, wcLink: link)
    }
    
}

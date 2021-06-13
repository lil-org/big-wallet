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
    
    func connectWalletWithLink(_ link: String, account: Account) {
        WalletConnect.shared.connect(link: link, address: account.address) { connected in
            // TODO: close here
            // use connected value
        }
        // TODO: show spinner
        Window.closeAll()
        Window.activateSafari()
    }
    
}

extension Agent: NearbyConnectivityDelegate {
    
    func didFind(link: String) {
        showInitialScreen(onAppStart: false, wcLink: link)
    }
    
}

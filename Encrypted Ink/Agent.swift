// Copyright © 2021 Encrypted Ink. All rights reserved.

import Cocoa

class Agent {

    private var connectivity: NearbyConnectivity!
    
    func start() {
        connectivity = NearbyConnectivity(delegate: self)
        showInitialScreen(onAppStart: true)
    }
    
    func reopen() {
        showInitialScreen(onAppStart: false)
    }
    
    func showInitialScreen(onAppStart: Bool) {
        let windowController: NSWindowController
        if onAppStart, let currentWindowController = Window.current {
            windowController = currentWindowController
            Window.activate(windowController)
        } else {
            windowController = Window.showNew()
        }
        
        let accounts = AccountsService.getAccounts()
        if !accounts.isEmpty {
            windowController.contentViewController = AccountsListViewController.with(preloadedAccounts: accounts)
        } else {
            windowController.contentViewController = instantiate(ImportViewController.self)
        }
    }
    
}

extension Agent: NearbyConnectivityDelegate {
    
    func didFind(link: String) {
        globalLink = link
        // showScreen() // TODO: should show account selection
    }
    
}

var globalLink = ""

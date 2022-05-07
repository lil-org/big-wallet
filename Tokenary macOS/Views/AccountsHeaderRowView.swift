// Copyright © 2022 Tokenary. All rights reserved.

import Cocoa

protocol AccountsHeaderDelegate: AnyObject {
    
    func didClickEditAccounts(sender: NSTableRowView)
    func didClickShowSecretWords(sender: NSTableRowView)
    func didClickRemoveWallet(sender: NSTableRowView)
    
}

class AccountsHeaderRowView: NSTableRowView {
    
    private weak var headerDelegate: AccountsHeaderDelegate?
    
    @IBOutlet weak var titleButton: NSButton! {
        didSet {
            let menu = NSMenu()
            titleButton.menu = menu
            menu.delegate = self
        }
    }
    
    @IBAction func titleButtonTapped(_ sender: NSButton) {
        let menu = sender.menu
        menu?.autoenablesItems = false
        
        let editAccountsItem = NSMenuItem(title: Strings.editAccounts, action: #selector(didClickEditAccounts), keyEquivalent: "")
        let showSecretWordsItem = NSMenuItem(title: Strings.showSecretWords, action: #selector(didClickShowSecretWords), keyEquivalent: "")
        let removeWalletItem = NSMenuItem(title: Strings.removeWallet, action: #selector(didClickRemoveWallet), keyEquivalent: "")
        
        editAccountsItem.target = self
        showSecretWordsItem.target = self
        removeWalletItem.target = self
        
        menu?.addItem(editAccountsItem)
        menu?.addItem(.separator())
        menu?.addItem(showSecretWordsItem)
        menu?.addItem(removeWalletItem)
        
        var origin = sender.frame.origin
        origin.x += sender.frame.width
        origin.y += sender.frame.height
        menu?.popUp(positioning: nil, at: origin, in: self)
    }
    
    func setup(multicoinWallet: Bool, delegate: AccountsHeaderDelegate?) {
        headerDelegate = delegate
        if multicoinWallet {
            titleButton.title = Strings.multicoinWallet
            titleButton.isEnabled = true
            titleButton.image = Images.multicoinWalletPreferences
        } else {
            titleButton.title = Strings.privateKeyWallets
            titleButton.isEnabled = false
            titleButton.image = nil
        }
    }
    
    @objc private func didClickEditAccounts() {
        headerDelegate?.didClickEditAccounts(sender: self)
    }
    
    @objc private func didClickShowSecretWords() {
        headerDelegate?.didClickShowSecretWords(sender: self)
    }
    
    @objc private func didClickRemoveWallet() {
        headerDelegate?.didClickRemoveWallet(sender: self)
    }
    
}

extension AccountsHeaderRowView: NSMenuDelegate {
    
    func menuDidClose(_ menu: NSMenu) {
        menu.removeAllItems()
    }
    
}

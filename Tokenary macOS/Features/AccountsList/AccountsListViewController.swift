// Copyright © 2022 Tokenary. All rights reserved.

import Foundation
import AppKit
import SwiftUI
import WalletCore

class AccountsListViewController: NSViewController, NSWindowDelegate, NSMenuDelegate {
    private let walletsManager: WalletsManager
    private let agent: Agent
    
    @IBOutlet weak var viewContainer: NSView! {
        didSet {
            viewContainer.wantsLayer = true
        }
    }
    @IBOutlet weak var titleLabel: NSTextField!
    @IBOutlet weak var chainButtonHeightConstraint: NSLayoutConstraint!
    @IBOutlet weak var chainButtonContainer: NSView! {
        didSet {
            chainButtonContainer.wantsLayer = true
        }
    }
    @IBOutlet weak var chainButton: NSPopUpButton!
    @IBOutlet weak var accountsListContainer: NSView! {
        didSet {
            accountsListContainer.wantsLayer = true
        }
    }
    @IBOutlet weak var addButton: NSButton! {
        didSet {
            let menu = NSMenu()
            addButton.menu = menu
            menu.delegate = self
        }
    }
    
    private var chain = EthereumChain.ethereum
    private var didCallCompletion = false
    private var wrappingVC: NSViewController
    private weak var testnetsMenuItem: NSMenuItem?
    
    weak var stateProviderInput: AccountsListStateProviderInput?
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?
    var newWalletId: String? // такого на айосе нет
    
    init?(coder: NSCoder, walletsManager: WalletsManager, agent: Agent, wrappingVC: NSViewController) {
        self.walletsManager = walletsManager
        self.agent = agent
        self.wrappingVC = wrappingVC
        super.init(coder: coder)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if walletsManager.wallets.isEmpty {
            walletsManager.start()
        }
        
        addChild(wrappingVC)
        wrappingVC.view.translatesAutoresizingMaskIntoConstraints = false
        accountsListContainer.addSubview(wrappingVC.view)
        
        NSLayoutConstraint.activate([
            wrappingVC.view.widthAnchor.constraint(equalTo: accountsListContainer.widthAnchor),
            wrappingVC.view.heightAnchor.constraint(equalTo: accountsListContainer.heightAnchor),
            wrappingVC.view.topAnchor.constraint(equalTo: accountsListContainer.topAnchor),
            wrappingVC.view.leadingAnchor.constraint(equalTo: accountsListContainer.leadingAnchor),
            wrappingVC.view.trailingAnchor.constraint(equalTo: accountsListContainer.trailingAnchor),
            wrappingVC.view.bottomAnchor.constraint(equalTo: accountsListContainer.bottomAnchor)
        ])
        
        reloadData()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadData(notification:)),
            name: Notification.Name.walletsChanged,
            object: nil
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
        promptSafariForLegacyUsersIfNeeded()
        blinkNewWalletCellIfNeeded()
    }
    
    override func viewWillLayout() {
        chainButtonContainer.layer?.backgroundColor = NSColor(name: nil) { appearance in
            if appearance.isDarkMode {
                return NSColor(deviceRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
            } else {
                return NSColor(deviceRed: 199 / 255, green: 199 / 255, blue: 204 / 255, alpha: 1)
            }
        }.cgColor
        viewContainer.layer?.backgroundColor = NSColor(Color.systemGray2).cgColor
        accountsListContainer.layer?.backgroundColor = NSColor(light: .white, dark: .black).cgColor
    }
    
    // MARK: - State Management
    
    @IBAction func addButtonTapped(_ sender: NSButton) {
        let menu = sender.menu
        
        let createItem = NSMenuItem(
            title: "", action: #selector(didTapCreateNewMnemonicWallet), keyEquivalent: ""
        )
        let importItem = NSMenuItem(
            title: "", action: #selector(didTapImportExistingAccount), keyEquivalent: ""
        )
        let font = NSFont.systemFont(ofSize: 21, weight: .bold)
        
        createItem.attributedTitle = NSAttributedString(
            string: Strings.createNew, attributes: [.font: font]
        )
        importItem.attributedTitle = NSAttributedString(
            string: Strings.importExisting, attributes: [.font: font]
        )
        menu?.addItem(createItem)
        menu?.addItem(importItem)

        var origin = sender.frame.origin
        origin.x += sender.frame.width
        origin.y += sender.frame.height
        menu?.popUp(positioning: nil, at: origin, in: view)
    }
    
    private func updateHeader() {
        let canSelectAccount = onSelectedWallet != nil && !walletsManager.wallets.isEmpty
        titleLabel.stringValue = canSelectAccount ? Strings.selectAccountTwoLines : Strings.accounts
        addButton.isHidden = walletsManager.wallets.isEmpty
        chainButtonHeightConstraint.constant = canSelectAccount ? 40 : 15
        chainButtonContainer.isHidden = !canSelectAccount
        if canSelectAccount, chainButton.menu?.items.isEmpty == true {
            let menu = NSMenu()
            for mainnet in EthereumChain.mainnets {
                let item = NSMenuItem(
                    title: mainnet.title, action: #selector(didSelectChain(_:)), keyEquivalent: ""
                )
                item.tag = mainnet.id
                menu.addItem(item)
            }

            let submenuItem = NSMenuItem()
            submenuItem.title = Strings.testnets
            let submenu = NSMenu()
            for testnet in EthereumChain.testnets {
                let item = NSMenuItem(
                    title: testnet.title, action: #selector(didSelectChain(_:)), keyEquivalent: ""
                )
                item.tag = testnet.id
                submenu.addItem(item)
            }

            submenuItem.submenu = submenu
            menu.addItem(.separator())
            menu.addItem(submenuItem)
            testnetsMenuItem = submenuItem
            chainButton.menu = menu
        }
    }
    
    @objc private func reloadData(notification: NSNotification? = nil) {
        DispatchQueue.main.async {
            if let walletsChangeSet = notification?.userInfo?["changeset"] as? WalletsManager.TokenaryWalletChangeSet {
                self.stateProviderInput?.updateAccounts(with: walletsChangeSet)
            } else {
                self.stateProviderInput?.updateAccounts(
                    with: .init(toAdd: self.walletsManager.wallets.get(), toUpdate: [], toRemove: [])
                )
            }
            self.updateHeader()
        }
    }
    
    private func promptSafariForLegacyUsersIfNeeded() {
        guard Defaults.shouldPromptSafariForLegacyUsers else { return }
        Defaults.shouldPromptSafariForLegacyUsers = false
        Alert.showSafariPrompt()
    }
    
    private func blinkNewWalletCellIfNeeded() {
        guard let newWalletId = self.newWalletId else { return }
        defer { self.newWalletId = nil }
        stateProviderInput?.scrollToWalletAndBlink(walletId: newWalletId)
    }
    
    private func createNewAccountAndShowSecretWordsFor(chains: [ChainType]) {
        guard
            let wallet = try? walletsManager.createMnemonicWallet(
                chainTypes: chains
            )
        else { return }
        newWalletId = wallet.id
        blinkNewWalletCellIfNeeded()
        showKey(wallet: wallet, mnemonic: true)
    }
    
    private func showKey(wallet: TokenaryWallet, mnemonic: Bool) {
        let secret: String
        if mnemonic, let mnemonicString = try? wallet.mnemonic {
            secret = mnemonicString
        } else if let privateKey = wallet[.privateKey] ?? nil {
            secret = privateKey.data.hexString
        } else {
            return
        }
        
        let alert = Alert()
        alert.messageText = mnemonic ? Strings.secretWords : Strings.privateKey
        alert.informativeText = secret
        alert.alertStyle = .informational
        alert.addButton(withTitle: Strings.ok)
        alert.addButton(withTitle: Strings.copy)
        if alert.runModal() != .alertFirstButtonReturn {
            PasteboardHelper.setPlain(secret)
        }
    }
    
    private func update(wallet: TokenaryWallet, newChainList: [ChainType]) {
        try? walletsManager.changeAccountsIn(wallet: wallet, to: newChainList)
    }
    
    @objc
    private func didBecomeActive() {
        guard view.window?.isVisible == true else { return }
        if let completion = agent.getWalletSelectionCompletionIfShouldSelect() {
            onSelectedWallet = completion
        }
        updateHeader()
    }
    
    private func callCompletion(wallet: TokenaryWallet?) {
        if !didCallCompletion {
            didCallCompletion = true
            onSelectedWallet?(chain, wallet)
        }
    }
    
    @objc private func didSelectChain(_ sender: AnyObject) {
        guard
            let menuItem = sender as? NSMenuItem,
                let selectedChain = EthereumChain(rawValue: menuItem.tag)
        else { return }
        
        if let index = chainButton.menu?.index(of: menuItem), index < .zero {
            let submenu = menuItem.menu
            submenu?.removeItem(menuItem)
            
            if
                submenu?.items.isEmpty == true,
                let testnetsMenuItem = self.testnetsMenuItem
            {
                testnetsMenuItem.menu?.removeItem(testnetsMenuItem)
                self.testnetsMenuItem = nil
            }

            chainButton.menu?.addItem(menuItem)
            chainButton.select(menuItem)
        }
        
        chain = selectedChain
    }
    
    // MARK: - AccountsListViewController + NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        callCompletion(wallet: nil)
    }
    
    // MARK: - AccountsListViewController + NSMenuDelegate {
   
    func menuDidClose(_ menu: NSMenu) {
        if addButton.menu === menu {
            menu.removeAllItems()
        }
    }
    
    // MARK: - AccountsListViewController + AccountsListStateProviderOutput
    
    @objc func didTapCreateNewMnemonicWallet() {
        let chainSelectionVC = ChainSelectionAssembly.build(
            for: .multiSelect(ChainType.supportedChains),
            completion: { [weak self] chosenChains in
                let newWindow = Window.showNew()
                newWindow.contentViewController = self
                
                guard chosenChains.count != .zero else { return }
                let alert = Alert()
                alert.messageText = Strings.backUpNewAccount
                alert.informativeText = Strings.youWillSeeSecretWords
                alert.alertStyle = .critical
                alert.addButton(withTitle: Strings.ok)
                alert.addButton(withTitle: Strings.cancel)
                if alert.runModal() == .alertFirstButtonReturn {
                    self?.createNewAccountAndShowSecretWordsFor(chains: chosenChains)
                }
            }
        )
        view.window?.contentViewController = chainSelectionVC
    }
    
    @objc func didTapImportExistingAccount() {
        let importAccountVC = instantiate(ImportViewController.self)
        importAccountVC.onSelectedWallet = onSelectedWallet
        importAccountVC.accountsListVC = self
        view.window?.contentViewController = importAccountVC
    }
}

extension AccountsListViewController: AccountsListStateProviderOutput {
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet) {
        let currentSelection = wallet.associatedMetadata.allChains
        let chainSelectionVC = ChainSelectionAssembly.build(
            for: .multiReSelect(
                currentlySelected: currentSelection,
                possibleElements: ChainType.supportedChains
            ),
            completion: { [weak self] chosenChains in
                let newWindow = Window.showNew()
                newWindow.contentViewController = self
                
                guard
                    chosenChains.count != .zero,
                    chosenChains != currentSelection
                else { return }
                self?.update(wallet: wallet, newChainList: chosenChains)
            }
        )
        view.window?.contentViewController = chainSelectionVC
    }
    
    func didTapRemove(wallet: TokenaryWallet) {
        askBeforeRemoving(wallet: wallet)
    }
    
    func didTapRename(previousName: String, completion: @escaping (String?) -> Void) {
        let scrollView = NSScrollView(frame: NSRect(x: .zero, y: .zero, width: 200, height: 100))
        scrollView.hasVerticalScroller = true
        
        let clipView = NSClipView(frame: scrollView.bounds)
        clipView.autoresizingMask = [.width, .height]
        
        let textView = NSTextView(frame: clipView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.string = previousName
        
        clipView.documentView = textView
        scrollView.contentView = clipView
        
        let alert = Alert().then {
            $0.alertStyle = .informational
            $0.messageText = "Rename Wallet?"
            $0.addButton(withTitle: Strings.ok)
            $0.addButton(withTitle: Strings.cancel)
            $0.accessoryView = scrollView
        }
        alert.window.initialFirstResponder = textView
        let alertResult = alert.runModal()
        
        switch alertResult {
        case .alertFirstButtonReturn:
            if textView.string == previousName {
                completion(nil)
            } else {
                completion(textView.string)
            }
        case .alertSecondButtonReturn:
            completion(nil)
        default:
            completion(nil)
        }
    }

    func didTapExport(wallet: TokenaryWallet) {
        let isMnemonic = wallet.isMnemonic
        let title = isMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        
        let alert = Alert().then {
            $0.alertStyle = .critical
            $0.messageText = title
            $0.addButton(withTitle: Strings.iUnderstandTheRisks)
            $0.addButton(withTitle: Strings.cancel)
        }
        if alert.runModal() == .alertFirstButtonReturn {
            let reason: AuthenticationReason = isMnemonic ? .showSecretWords : .showPrivateKey
            agent.askAuthentication(
                on: view.window,
                getBackTo: self,
                onStart: false,
                reason: reason
            ) { [weak self] isAllowed in
                Window.activateWindow(self?.view.window)
                if isAllowed {
                    self?.showKey(wallet: wallet, mnemonic: isMnemonic)
                }
            }
        }
    }
    
    func askBeforeRemoving(wallet: TokenaryWallet) {
        let alert = Alert().then {
            $0.alertStyle = .critical
            $0.messageText = Strings.removedAccountsCantBeRecovered
            $0.addButton(withTitle: Strings.removeAnyway)
            $0.addButton(withTitle: Strings.cancel)
        }
        
        if alert.runModal() == .alertFirstButtonReturn {
            agent.askAuthentication(
                on: view.window,
                getBackTo: self,
                onStart: false,
                reason: .removeAccount
            ) { [weak self] isAllowed in
                Window.activateWindow(self?.view.window)
                if isAllowed {
                    try? self?.walletsManager.delete(wallet: wallet)
                }
            }
        }
    }
    
    // ToDo: There is one special case here - when we come to change/request accounts with an empty provider -> this way we should have shown both both all-chains and their sub-chain info, however for now, we just drop side-chain choosing and will implement this functionality later
    func didSelect(chain: EthereumChain) {
        self.chain = chain
    }
    
    func cancelButtonWasTapped() {
        callCompletion(wallet: nil)
    }
    
    func didSelect(wallet: TokenaryWallet) {
        callCompletion(wallet: wallet)
    }
}

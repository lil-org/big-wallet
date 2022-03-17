// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

import UIKit
import SwiftUI
import WalletCore

struct DappRequestProcessor1 {

     private static let walletsManager = WalletsManager.shared
     private static let ethereum = Ethereum.shared

     static func processSafariRequest(_ request: SafariRequest, completion: @escaping () -> Void) -> DappRequestAction {
         .selectAccount(.init(provider: .unknown, completion: {_, _ in }))
     }
}

class ALViewController<ContentView: View>: WrappingViewController<ContentView>, DataStateContainer {
    private let walletsManager: WalletsManager

    private var chain = EthereumChain.ethereum
    var onSelectedWallet: ((EthereumChain?, TokenaryWallet?) -> Void)?

    private var toDismissAfterResponse = [Int: UIViewController]()
    
    weak var stateProviderInput: AccountsListStateProviderInput?
    
    init(walletsManager: WalletsManager, rootView: ContentView) {
        self.walletsManager = walletsManager
        super.init(rootView: rootView)
    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        self.onSelectedWallet.isNil
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Be sure to call here (Keychain bug #)
        //  Or maybe there is problem with permissions
        if self.walletsManager.wallets.isEmpty {
            self.walletsManager.start()
        }
        
        self.configureDataState(
            .noData, description: Strings.tokenaryIsEmpty, buttonTitle: Strings.addAccount
        ) { [weak self] buttonFrame in
            self?.stateProviderInput?.didTapAddAccount(at: buttonFrame)
        }
        self.setDataStateViewTransparent(true)
        self.updateDataState()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.processInput),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.reloadData),
            name: Notification.Name.walletsChanged,
            object: nil
        )
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.reloadData()
    }

    @objc private func processInput() {
        guard
            let url = launchURL?.absoluteString, url.hasPrefix(Constants.tokenarySchemePrefix),
            let request = SafariRequest(query: String(url.dropFirst(Constants.tokenarySchemePrefix.count)))
        else { return }

        launchURL = nil

        let action = DappRequestProcessor.processSafariRequest(request) { [weak self] in
             self?.openSafari(requestId: request.id)
        }
        
        switch action {
        case .none, .justShowApp:
            break
        case .selectAccount(let action):
            let accountsListVC = AccountsListAssembly.build(
                for: .choseAccount(forChain: SupportedChainType(provider: action.provider)),
                onSelectedWallet: action.completion
            ).then {
                $0.isModalInPresentation = true
            }
            self.presentForSafariRequest(accountsListVC, id: request.id)
        case .approveMessage(let action):
            let approveViewController = ApproveViewController.with(subject: action.subject,
                                                                   address: action.address,
                                                                   meta: action.meta,
                                                                   peerMeta: action.peerMeta,
                                                                   completion: action.completion)
            self.presentForSafariRequest(approveViewController.inNavigationController, id: request.id)
        case .approveTransaction(let action):
            let approveTransactionViewController = ApproveTransactionViewController.with(transaction: action.transaction,
                                                                                         chain: action.chain,
                                                                                         address: action.address,
                                                                                         peerMeta: action.peerMeta,
                                                                                         completion: action.completion)
            self.presentForSafariRequest(approveTransactionViewController.inNavigationController, id: request.id)
        }
    }
    
    private func openSafari(requestId: Int) {
         UIApplication.shared.open(URL.blankRedirect(id: requestId)) { [weak self] _ in
             self?.toDismissAfterResponse[requestId]?.dismiss(animated: false)
             self?.toDismissAfterResponse.removeValue(forKey: requestId)
         }
     }
    
    // ToDo(@pettrk): Maybe rethink this logic
    private func presentForSafariRequest(_ viewController: UIViewController, id: Int) {
        var presentFrom: UIViewController = self
        while let presented = presentFrom.presentedViewController, !(presented is UIAlertController) {
            presentFrom = presented
        }
        if let alert = presentFrom.presentedViewController as? UIAlertController {
            alert.dismiss(animated: false)
        }
        presentFrom.present(viewController, animated: true)
        self.toDismissAfterResponse[id] = viewController
    }
    
    // MARK: - State Management

    private func updateDataState() {
        if let isFilteredEmpty = self.stateProviderInput?.filteredWallets.isEmpty {
            self.dataState = isFilteredEmpty ? .noData : .hasData
        } else {
            self.dataState = self.walletsManager.wallets.isEmpty ? .noData : .hasData
        }
    }
    
    @objc private func reloadData() {
        self.stateProviderInput?.wallets = self.walletsManager.wallets
        self.updateDataState()
    }
    
    private func createNewAccountAndShowSecretWordsFor(chains: [SupportedChainType]) {
        guard
            let wallet = try? self.walletsManager.createMnemonicWallet(
                coinTypes: chains.map { $0.walletCoreCoinType }
            )
        else { return }
        self.showKey(wallet: wallet, mnemonic: true)
    }
    
    private func showKey(wallet: TokenaryWallet, mnemonic: Bool) {
        let secret: String
        if
            mnemonic, let mnemonicString = try? wallet.mnemonic {
            secret = mnemonicString
        } else if let privateKey = wallet[.privateKey] ?? nil {
            secret = privateKey.data.hexString
        } else {
            return
        }

        let alert = UIAlertController(
            title: mnemonic ? Strings.secretWords : Strings.privateKey,
            message: secret,
            preferredStyle: .alert
        ).then {
            $0.addAction(
                UIAlertAction(title: Strings.ok, style: .default)
            )
            $0.addAction(
                UIAlertAction(title: Strings.copy, style: .default) { _ in
                    UIPasteboard.general.string = secret
                }
            )
        }
        
        self.present(alert, animated: true)
    }
    
    private func update(wallet: TokenaryWallet, newChainList: [SupportedChainType]) {
        try? self.walletsManager.changeAccountsIn(wallet: wallet, to: newChainList)
    }
}

extension ALViewController: AccountsListStateProviderOutput {
    func didTapCreateNewMnemonicWallet() {
        let chainSelectionVC = ChainSelectionAssembly.build(
            for: .multiSelect(SupportedChainType.allCases),
            completion: { [weak self] chosenChains in
                self?.dismissAnimated()
                guard chosenChains.count != .zero else { return }
                let alert = UIAlertController(
                    title: Strings.backUpNewAccount,
                    message: Strings.youWillSeeSecretWords,
                    preferredStyle: .alert
                ).then {
                    $0.addAction(
                        UIAlertAction(title: Strings.ok, style: .default) { [weak self] _ in
                            self?.createNewAccountAndShowSecretWordsFor(chains: chosenChains)
                        }
                    )
                    $0.addAction(
                        UIAlertAction(title: Strings.cancel, style: .cancel)
                    )
                }
                self?.present(alert, animated: true)
            }
        )
        self.present(chainSelectionVC, animated: true)
    }
    
    func didTapImportExistingAccount() {
        let importAccountViewController = instantiate(ImportViewController.self, from: .main)
        present(importAccountViewController.inNavigationController, animated: true)
    }
    
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet) {
        let currentSelection = wallet.associatedMetadata.walletDerivationType.chainTypes
        let chainSelectionVC = ChainSelectionAssembly.build(
            for: .multiReSelect(
                currentlySelected: currentSelection,
                possibleElements: SupportedChainType.allCases
            ),
            completion: { [weak self] chosenChains in
                self?.dismissAnimated()
                guard
                    chosenChains.count != .zero,
                    chosenChains != currentSelection
                else { return }
                self?.update(wallet: wallet, newChainList: chosenChains)
            }
        )
        self.present(chainSelectionVC, animated: true)
    }
    
    func didTapRemove(wallet: TokenaryWallet) {
        self.askBeforeRemoving(wallet: wallet)
    }
    
    func didTapRename(previousName: String, completion: @escaping (String?) -> Void) {
        self.showRenameAlert(title: "Rename wallet?", currentName: previousName, completion: completion)
    }

    func didTapExport(wallet: TokenaryWallet) {
        let isMnemonic = wallet.isMnemonic
        let title = isMnemonic ? Strings.secretWordsGiveFullAccess : Strings.privateKeyGivesFullAccess
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        let okAction = UIAlertAction(title: Strings.iUnderstandTheRisks, style: .default) { [weak self] _ in
            LocalAuthentication.attempt(
                reason: Strings.removeWallet,
                presentPasswordAlertFrom: self,
                passwordReason: Strings.toShowAccountKey
            ) { isSuccessful in
                if isSuccessful {
                    self?.showKey(wallet: wallet, mnemonic: isMnemonic)
                }
            }
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(okAction)
        present(alert, animated: true)
    }
    
    func askBeforeRemoving(wallet: TokenaryWallet) {
        let alert = UIAlertController(
            title: Strings.removedAccountsCantBeRecovered, message: nil, preferredStyle: .alert
        )
        let removeAction = UIAlertAction(title: Strings.removeAnyway, style: .destructive) { [weak self] _ in
            LocalAuthentication.attempt(
                reason: Strings.removeWallet,
                presentPasswordAlertFrom: self,
                passwordReason: Strings.toRemoveAccount
            ) { isSuccessful in
                if isSuccessful {
                    try? self?.walletsManager.delete(wallet: wallet)
                }
            }
        }
        let cancelAction = UIAlertAction(title: Strings.cancel, style: .cancel)
        alert.addAction(cancelAction)
        alert.addAction(removeAction)
        present(alert, animated: true)
    }
    
    // There is one special case here - when we come to change/request accounts
    //  with an empty provider -> this way we should have shown both both all-chains and their sub-chain info
    //  however for now, we just drop side-chain choosing and will implement this functionality later
    func didSelect(chain: EthereumChain) {
        self.chain = chain
    }
    
    func cancelButtonWasTapped() {
        self.onSelectedWallet?(nil, nil)
    }
    
    func didSelect(wallet: TokenaryWallet) {
        self.onSelectedWallet?(chain, wallet)
    }
}

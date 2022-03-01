// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

protocol AccountsListStateProviderInput: AnyObject {
    func didTapAddAccount()
    var wallets: [TokenaryWallet] { get set }
}

protocol AccountsListStateProviderOutput: AnyObject {
    func didTapCreateNewMnemonicWallet()
    func didTapImportExistingAccount()
    func didTapRemove(wallet: TokenaryWallet)
    func cancelButtonWasTapped()
    func didSelect(chain: EthereumChain)
    func didTapExport(wallet: TokenaryWallet)
    func askBeforeRemoving(wallet: TokenaryWallet)
    func didSelect(wallet: TokenaryWallet)
    func didTapRename(previousName: String, completion: @escaping (String?) -> Void)
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet)
}

class AccountsListStateProvider: ObservableObject {
    @Published
    var accounts: [AccountView.ViewModel] = []
    
    @Published
    var wallets: [TokenaryWallet] = [] {
        didSet {
            self.accounts = self.transform(self.filteredWallets)
        }
    }
    
    private var filteredWallets: [TokenaryWallet] {
        if
            case let .choseAccount(forChain: selectedChain) = mode,
            let selectedChain = selectedChain
        {
            return self.wallets.filter { $0.associatedMetadata.walletDerivationType.chainTypes.contains(selectedChain) }
        } else {
            return self.wallets
        }
        
    }
    
    @Published
    var isAddAccountPresented: Bool = false
    
    @Published
    var showToastOverlay: Bool = false
    
    @Published
    var mode: AccountsListMode
    
    @Published
    var selectedWallet: TokenaryWallet?
    
    weak var output: AccountsListStateProviderOutput?
    
    init(mode: AccountsListMode) {
        self.mode = mode
    }
    
    private func transform(_ wallet: TokenaryWallet) -> [MnemonicDerivedAccountView.ViewModel] {
        guard wallet.isMnemonic else { return [] }
        return wallet.associatedMetadata.walletDerivationType.chainTypes.map {
            MnemonicDerivedAccountView.ViewModel(
                icon: Image($0.iconName),
                title: $0.title,
                ticker: $0.ticker,
                accountAddress: wallet[$0, .address] ?? nil,
                iconShadowColor: Color(UIImage(named: $0.iconName)?.averageColor ?? .black)
            )
        }
    }
    
    private func transform(_ wallets: [TokenaryWallet]) -> [AccountView.ViewModel] {
        wallets
            .sorted { $0.associatedMetadata.createdAt < $1.associatedMetadata.createdAt }
            .map { wallet in
                let icon: Image
                if wallet.isMnemonic {
                    if wallet.associatedMetadata.walletDerivationType.chainTypes.contains(.ethereum) {
                        icon = Image(
                            Blockies(seed: wallet[.ethereum, .address]??.lowercased()).createImage(),
                            defaultImage: "multiChainGrid"
                        )
                    } else {
                        icon = Image("multiChainGrid")
                    }
                } else {
                    icon = Image(wallet.associatedMetadata.walletDerivationType.chainTypes.first!.iconName)
                }
                return AccountView.ViewModel(
                    id: wallet.id,
                    icon: icon,
                    isMnemonicBased: wallet.isMnemonic,
                    accountAddress: wallet.isMnemonic ? nil : wallet[.address] ?? nil,
                    accountName: wallet.name,
                    mnemonicDerivedViewModels: self.transform(wallet)
                )
            }
    }
}

extension AccountsListStateProvider: AccountsListStateProviderInput {
    func didTapAddAccount() {
        self.isAddAccountPresented.toggle()
    }
}

extension AccountsListStateProvider: AccountsListStateProviderOutput {
    func didTapCreateNewMnemonicWallet() { self.output?.didTapCreateNewMnemonicWallet() }
    
    func didTapImportExistingAccount() { self.output?.didTapImportExistingAccount() }
    
    func didTapRemove(wallet: TokenaryWallet) { self.output?.didTapRemove(wallet: wallet) }
    
    func cancelButtonWasTapped() { self.output?.cancelButtonWasTapped() }
    
    func didSelect(chain: EthereumChain) { self.output?.didSelect(chain: chain) }
    
    func didTapExport(wallet: TokenaryWallet) { self.output?.didTapExport(wallet: wallet) }
    
    func askBeforeRemoving(wallet: TokenaryWallet) { self.output?.askBeforeRemoving(wallet: wallet) }
    
    func didSelect(wallet: TokenaryWallet) { self.output?.didSelect(wallet: wallet) }
    
    func didTapRename(previousName: String, completion: @escaping (String?) -> Void) {
        self.output?.didTapRename(previousName: previousName, completion: completion)
    }
    
    func didTapReconfigureAccountsIn(wallet: TokenaryWallet) {
        self.output?.didTapReconfigureAccountsIn(wallet: wallet)
    }
}

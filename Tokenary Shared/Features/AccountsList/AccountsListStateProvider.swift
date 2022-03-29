// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

protocol AccountsListStateProviderInput: AnyObject {
    var wallets: [TokenaryWallet] { get set }
    var filteredWallets: [TokenaryWallet] { get }
    
    func updateAccounts(with walletsChangeSet: WalletsManager.TokenaryWalletChangeSet)
    
#if canImport(UIKit)
    func didTapAddAccount(at buttonFrame: CGRect)
#elseif canImport(AppKit)
    func scrollToWalletAndBlink(walletId: String)
#endif
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
    var accounts: [AccountItemView.ViewModel] = []
    
    func updateAccounts(with walletsChangeSet: WalletsManager.TokenaryWalletChangeSet) {
        DispatchQueue.global().async {
            let vmToAdd: [AccountItemView.ViewModel] = walletsChangeSet.toAdd.map(self.transform)
            let indicesToRemove: IndexSet = IndexSet(
                self.accounts
                    .enumerated()
                    .filter { accountEnumeration in
                        walletsChangeSet.toRemove.contains(where: { $0.id == accountEnumeration.element.id })
                    }
                    .map { $0.offset }
            )
            let updateVM: [(Int, AccountItemView.ViewModel)] = walletsChangeSet.toUpdate.compactMap { updateWallet in
                guard let updateIdx = self.accounts.firstIndex(where: { $0.id == updateWallet.id }) else { return nil }
                let updateVM: AccountItemView.ViewModel = self.transform(updateWallet)
                return (updateIdx, updateVM)
            }
            
            DispatchQueue.main.async {
                for (updateIdx, accountVM) in updateVM {
                    self.accounts[updateIdx] = accountVM
                }
                self.accounts.remove(atOffsets: indicesToRemove)
                self.accounts.append(contentsOf: vmToAdd)
            }
        }
    }
    
    @Published
    var wallets: [TokenaryWallet] = []
    
    var filteredWallets: [TokenaryWallet] {
        if
            case let .choseAccount(forChain: selectedChain) = mode,
            let selectedChain = selectedChain
        {
            return self.wallets.filter { $0.associatedMetadata.allChains.contains(selectedChain) }
        } else {
            return self.wallets
        }
    }
    
    // iPad -> popover, iPhone -> dialog
    @Published
    var isAddAccountPopoverPresented: Bool = false
    @Published
    var isAddAccountDialogPresented: Bool = false
    
    var touchAnchor: UnitPoint = .zero
    
    @Published
    var showToastOverlay: Bool = false
    
    @Published
    var mode: AccountsListMode
    
    @Published
    var selectedWallet: TokenaryWallet?
    
    @Published
    var scrollToWalletId: String?
    
    weak var output: AccountsListStateProviderOutput?
    
    init(mode: AccountsListMode) {
        self.mode = mode
    }

    private func transform(_ wallet: TokenaryWallet) -> AccountItemView.ViewModel {
        let icon: Image
        if wallet.isMnemonic {
            if wallet.associatedMetadata.allChains.contains(.ethereum) {
                icon = Image(
                    Blockies(seed: wallet[.ethereum, .address]??.lowercased(), size: 10).createImage(),
                    defaultImage: "multiChainGrid"
                )
            } else {
                icon = Image("multiChainGrid")
            }
        } else {
            let privateKeyChainType = wallet.associatedMetadata.privateKeyChain!
            if privateKeyChainType == .ethereum {
                icon = Image(
                    Blockies(seed: wallet[.address]??.lowercased(), size: 10).createImage(),
                    defaultImage: "multiChainGrid"
                )
            } else {
                icon = Image(privateKeyChainType.iconName)
            }
        }
        return AccountItemView.ViewModel(
            id: wallet.id,
            icon: icon,
            isMnemonicBased: wallet.isMnemonic,
            accountAddress: wallet.isMnemonic ? nil : wallet[.address] ?? nil,
            accountName: wallet.name,
            mnemonicDerivedViewModels: self.transform(wallet)
        )
    }
    
    private func transform(_ wallet: TokenaryWallet) -> [DerivedAccountItemView.ViewModel] {
        guard wallet.isMnemonic else { return [] }
        if
            case let .choseAccount(forChain: selectedChain) = self.mode,
            let selectedChain = selectedChain
        {
            if wallet.associatedMetadata.allChains.contains(selectedChain) {
                return [self.transform(wallet, chain: selectedChain)]
            } else {
                assertionFailure("This should not normally happen!")
                return []
            }
        }
        return wallet.associatedMetadata.allChains.map {
            self.transform(wallet, chain: $0)
        }
    }
    
    private func transform(
        _ wallet: TokenaryWallet, chain: ChainType
    ) -> DerivedAccountItemView.ViewModel {
        DerivedAccountItemView.ViewModel(
            walletId: wallet.id,
            icon: Image(chain.iconName),
            chain: chain,
            accountAddress: wallet[chain, .address] ?? nil,
            iconShadowColor: .black
        )
    }
}

extension AccountsListStateProvider: AccountsListStateProviderInput {
#if canImport(UIKit)
    func didTapAddAccount(at buttonFrame: CGRect) {
        self.touchAnchor = UnitPoint(
            x: (buttonFrame.width / 2 + buttonFrame.minX) / UIScreen.main.bounds.width,
            y: buttonFrame.minY / UIScreen.main.bounds.height
        )
        if UIDevice.isPad {
            self.isAddAccountPopoverPresented.toggle()
        } else {
            self.isAddAccountDialogPresented.toggle()
        }
    }
#elseif canImport(AppKit)
    func scrollToWalletAndBlink(walletId: String) {
        self.scrollToWalletId = walletId
        guard let accountIdx = self.accounts.firstIndex(where: { $0.id == walletId }) else { return }
        let account = self.accounts[accountIdx]
        self.accounts[accountIdx] = AccountItemView.ViewModel(
            id: account.id,
            icon: account.icon,
            isMnemonicBased: account.isMnemonicBased,
            accountAddress: account.accountAddress,
            accountName: account.accountName,
            mnemonicDerivedViewModels: account.mnemonicDerivedViewModels,
            preformBlink: true
        )
    }
#endif
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

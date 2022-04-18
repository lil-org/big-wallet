// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

struct AccountsListSectionHeaderView: View {
    struct ViewModel: Identifiable, Equatable, Hashable {
        let id: String
        let icon: Image
        var accountName: String
        var mnemonicDerivedViewModels: [AccountsListDerivedItemView.ViewModel]
        var preformBlink: Bool = false
        
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
    
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    @State
    private var isInPress: Bool = false
    
    @State
    private var isInBlink: Bool = false
    
    @Binding
    var viewModel: ViewModel
    
    private var attachedWallet: TokenaryWallet? { WalletsManager.shared.getWallet(id: viewModel.id) }
    
    private var backgroundColor: Color {
        if isInBlink {
            return Color.inkGreen
        } else {
            return isInPress
                ? Color.systemGray5
                : Color.mainBackground
        }
    }
    
    var body: some View {
        Section {
            derivedAccountsRows
        } header: {
            HStack(spacing: 8) {
                viewModel.icon
                    .resizable()
                    .frame(width: 20, height: 20)
                    .cornerRadius(5)
                    .aspectRatio(contentMode: .fill)
                Text(viewModel.accountName)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, .zero)
            .padding(.bottom, 5)
        }
        .background(backgroundColor, ignoresSafeAreaEdges: [.leading, .trailing])
        .contextMenu {
            Text(actionsForWalletDialogTitle)
            walletActions
        }
        .onChange(of: viewModel.preformBlink) { newValue in
            guard newValue else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                isInBlink = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                isInBlink = false
                viewModel.preformBlink = false
            }
        }
    }
    
    private var actionsForWalletDialogTitle: String {
        if let address = attachedWallet?[.address] ?? nil {
            return address.trimmingAddress(sideLength: 6)
        } else {
            return "Mnemonic wallet"
        }
    }
    
    @ViewBuilder
    private var walletActions: some View {
        Button("Rename Wallet", role: .none) {
            if let attachedWallet = self.attachedWallet {
                stateProvider.didTapRename(previousName: attachedWallet.name) { newName in
                    if let newName = newName {
                        try? WalletsManager.shared.rename(
                            wallet: attachedWallet, newName: newName
                        )
                    }
                }
            }
        }.keyboardShortcut("r", modifiers: [.command])
        specificWalletActions
        Button(Strings.showWalletKey, role: .none) {
            if let attachedWallet = self.attachedWallet {
                stateProvider.didTapExport(wallet: attachedWallet)
            }
        }.keyboardShortcut("s", modifiers: [.command])
        Divider()
        Button(Strings.removeWallet, role: .destructive) {
            if let attachedWallet = self.attachedWallet {
                stateProvider.didTapRemove(wallet: attachedWallet)
            }
        }.keyboardShortcut("d", modifiers: [.shift, .command])
    }
    
    private var specificWalletActions: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            if attachedWallet.isMnemonic {
                mnemonicWalletActions
            } else {
                privateKeyWalletActions
            }
        }
    }
    
    private var mnemonicWalletActions: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            Button("Configure accounts") {
                stateProvider.didTapReconfigureAccountsIn(wallet: attachedWallet)
            }.keyboardShortcut("c", modifiers: [.command])
        }
    }
    
    private var privateKeyWalletActions: some View {
        Unwrap2(self.attachedWallet, attachedWallet?.associatedMetadata.privateKeyChain) { unwrappedWallet, chainType in
            Button(Strings.copyAddress) {
                PasteboardHelper.setPlainNotNil(unwrappedWallet[.address] ?? nil)
            }.keyboardShortcut(.defaultAction)
            Button(chainType.transactionScaner) {
                if let address = unwrappedWallet[.address] ?? nil {
                    LinkHelper.open(chainType.scanURL(address))
                }
            }.keyboardShortcut("t", modifiers: [.command])
        }
    }
    
    private var derivedAccountsRows: some View {
        ForEach($viewModel.mnemonicDerivedViewModels, id: \.id) { $mnemonicDerivedViewModel in
            AccountsListDerivedItemView(
                viewModel: $mnemonicDerivedViewModel
            )
        }
    }
}

struct AccountsListSectionHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        AccountsListSectionHeaderView(
            viewModel: .constant(.init(
                id: "Some-ID",
                icon: Image("tez"),
                accountName: "Some really good old name with comas,,, 🔥🔥🔥🔥🔥",
                mnemonicDerivedViewModels: [
                    AccountsListDerivedItemView.ViewModel(
                        walletId: "1234",
                        icon: Image(packageResource: "eth", ofType: "png"),
                        chain: .ethereum,
                        accountAddress: "0x00000000219ab540356cbb839cbe05303d7705fa"
                    )
                ]
            ))
        )
        .frame(width: 250, height: 350)
    }
}

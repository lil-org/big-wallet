// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

struct AccountItemView: View {
    struct ViewModel: Identifiable, Equatable, Hashable {
        let id: String
        let icon: Image
        let isMnemonicBased: Bool
        let accountAddress: String?
        let accountName: String
        var mnemonicDerivedViewModels: [DerivedAccountItemView.ViewModel]
        var preformBlink: Bool = false
        
        func hash(into hasher: inout Hasher) { hasher.combine(self.id) }
    }
    
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    @State
    private var isInPress: Bool = false
    
    @State
    private var isInBlink: Bool = false
    
    @State
    private var areActionsForWalletPresented: Bool = false
    
    @Binding
    var viewModel: ViewModel
    
    private var attachedWallet: TokenaryWallet? {
        self.stateProvider.wallets.first(
            where: { $0.id == self.viewModel.id }
        )
    }
    
    private var backgroundColor: Color {
        if self.isInBlink {
            return Color.red
        } else {
            return self.isInPress
                ? Color.systemGray5
                : Color(light: .white, dark: .black)
        }
    }
    
    var body: some View {
        VStack {
            HStack(spacing: 12) {
                self.viewModel.icon
                    .resizable()
                    .cornerRadius(15)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    
                VStack(alignment: .leading) {
                    Text(self.viewModel.accountName)
                        .font(.system(size: 19, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if
                        !self.viewModel.isMnemonicBased,
                        let accountAddress = self.viewModel.accountAddress
                    {
                        Text(accountAddress)
                            .font(.system(size: 15, weight: .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                #if canImport(UIKit)
                if UIDevice.isPad {
                    Menu {
                        Text(self.actionsForWalletDialogTitle)
                        self.walletActions
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(.blue)
                            .padding([.leading, .trailing], 20)
                            .padding([.top, .bottom], 10)
                            .background(
                                Rectangle().fill(.clear)
                            )
                    }
                    .offset(x: 15)
                } else {
                    Button(action: { self.areActionsForWalletPresented.toggle() }) {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(.blue)
                            .padding([.leading, .trailing], 20)
                            .padding([.top, .bottom], 10)
                            .background(
                                Rectangle().fill(.clear)
                            )
                    }
                    .buttonStyle(DimmingButtonStyle())
                    .offset(x: 15)
                }
                #endif
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            
            if self.viewModel.isMnemonicBased && self.viewModel.mnemonicDerivedViewModels.count != .zero {
                self.derivedAccountsGrid
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .background(self.backgroundColor, ignoresSafeAreaEdges: [.leading, .trailing])
        .onTouchGesture(
            touchChanged: { isInside, hasEnded  in
                withAnimation(.linear(duration: 0.1)) {
                    if hasEnded {
                        self.isInPress = false
                    } else {
                        self.isInPress = isInside ? true : false
                    }
                }
                guard hasEnded, isInside else { return }
                self.areActionsForWalletPresented.toggle()
            }
        )
        .onChange(of: self.viewModel.preformBlink) { newValue in
            guard newValue else { return }
            DispatchQueue.main.async {
                self.isInBlink = true
            }
            
//            withAnimation(.easeOut(duration: 1.2)) {
//                self.isInBlink = true
//                DispatchQueue.main.async {
//                    self.viewModel.preformBlink = false
////                    self.isInBlink = false
//                }
//            }
        }
        #if canImport(UIKit)
        .confirmationDialog(
            self.actionsForWalletDialogTitle,
            isPresented: self.$areActionsForWalletPresented,
            titleVisibility: .visible,
            actions: {
                self.walletActions
                Button(Strings.cancel, role: .cancel, action: {})
            }
        )
//        .onChange(of: self.moreActionsSelectedElementId) { newValue in
//            guard newValue != nil else { return  }
//            self.stateProvider.selectedWallet = self.stateProvider.wallets.first(
//                where: { $0.id == newValue }
//            )
//            self.areActionsForWalletPresented.toggle()
//            self.moreActionsSelectedElementId = nil
//        }
        #endif
    }
    
    private var actionsForWalletDialogTitle: String {
        if let address = self.attachedWallet?[.address] ?? nil {
            return address
        } else {
            return "Mnemonic wallet"
        }
    }
    
    @ViewBuilder
    private var walletActions: some View {
        Button("Rename Wallet", role: .none) {
            if let attachedWallet = self.attachedWallet {
                self.stateProvider.didTapRename(previousName: attachedWallet.name) { newName in
                    if let newName = newName {
                        try? WalletsManager.shared.rename(
                            wallet: attachedWallet, newName: newName
                        )
                    }
                }
            }
        }
        self.specificWalletActions
        Button(Strings.showWalletKey, role: .none) {
            if let attachedWallet = self.attachedWallet {
                self.stateProvider.didTapExport(wallet: attachedWallet)
            }
        }
        Button(Strings.removeWallet, role: .destructive) {
            if let attachedWallet = self.attachedWallet {
                self.stateProvider.didTapRemove(wallet: attachedWallet)
            }
        }
    }
    
    private var specificWalletActions: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            if attachedWallet.isMnemonic {
                self.mnemonicWalletActions
            } else {
                self.privateKeyWalletActions
            }
        }
    }
    
    private var mnemonicWalletActions: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            Button("Configure accounts") {
                self.stateProvider.didTapReconfigureAccountsIn(wallet: attachedWallet)
            }
        }
    }
    
    private var privateKeyWalletActions: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            let chainType = attachedWallet.associatedMetadata.walletDerivationType.chainTypes.first!
            Button(Strings.copyAddress) {
                PasteboardHelper.setPlainNotNil(attachedWallet[.address] ?? nil)
            }.keyboardShortcut(.defaultAction)
            Button(chainType.transactionScaner) {
                if let address = attachedWallet[.address] ?? nil {
                    LinkHelper.open(chainType.scanURL(address))
                }
            }
        }
    }
    
//        .contextMenu { // appkit
//            Button("Rename Wallet") {}
//            Button(Strings.showWalletKey) {
//            }.keyboardShortcut("h", modifiers: [.control, .option, .command])
//            Divider()
//            Button(Strings.removeWallet) {
//            }.keyboardShortcut(.defaultAction)
//        }
    
//    if canImport(AppKit)
//    .contextMenu {
//        Button("Rename Wallet") {
//            if let selectedWallet = self.stateProvider.selectedWallet {
//                self.stateProvider.didTapRename(previousName: selectedWallet.name) { newName in
//                    if let newName = newName {
//                        try? WalletsManager.shared.rename(
//                            wallet: selectedWallet, newName: newName
//                        )
//                    }
//                }
//            }
//        }
//        self.specialWalletActions
//        Button(Strings.showWalletKey) {
//            if let selectedWallet = self.stateProvider.selectedWallet {
//                self.stateProvider.didTapExport(wallet: selectedWallet)
//            }
//        }.keyboardShortcut("h", modifiers: [.control, .option, .command])
//        Divider()
//        Button(Strings.removeWallet) {
//            if let selectedWallet = self.stateProvider.selectedWallet {
//                self.stateProvider.didTapRemove(wallet: selectedWallet)
//            }
//        }.keyboardShortcut(.defaultAction)
//    }
//    #else
//    
    private var derivedAccountsGrid: some View {
        WrappingStack {
            ForEach($viewModel.mnemonicDerivedViewModels, id: \.id) { $mnemonicDerivedViewModel in
                DerivedAccountItemView(
                    viewModel: $mnemonicDerivedViewModel
                )
            }
        }
        .wrappingStackStyle(
            hSpacing: 8, vSpacing: 8, alignment: .leading
        )
        .expandableGridStyle(
            hSpacing: 10, vSpacing: 10
        )
    }
}

struct AccountView_Previews: PreviewProvider {
    static var previews: some View {
        AccountItemView(
            viewModel: .constant(.init(
                id: "Some-ID",
                icon: Image("tez"),
                isMnemonicBased: true,
                accountAddress: "0x011b6e24ffb0b5f5fcc564cf4183c5bbbc96d515",
                accountName: "Some really good old name with comas,,, 🔥🔥🔥🔥🔥",
                mnemonicDerivedViewModels: []
            ))
        )
        .frame(width: 250, height: 350)
    }
}

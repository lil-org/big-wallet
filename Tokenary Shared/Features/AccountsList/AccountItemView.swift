// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

extension View {
    var accountIconFrame: some View {
        #if canImport(UIKit)
        self.frame(width: 40, height: 40)
        #elseif canImport(AppKit)
        self.frame(width: 30, height: 30)
        #endif
    }
    
    var accountIconCornerRadius: some View {
        #if canImport(UIKit)
        self.cornerRadius(15)
        #elseif canImport(AppKit)
        self.cornerRadius(10)
        #endif
    }
}

extension CGFloat {
    static var accountHorizontalStackSpacing: CGFloat {
        #if canImport(UIKit)
        12
        #elseif canImport(AppKit)
        8
        #endif
    }
}

struct AccountItemView: View {
    struct ViewModel: Identifiable, Equatable, Hashable {
        let id: String
        let icon: Image
        let isMnemonicBased: Bool
        let accountAddress: String?
        var accountName: String
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
            return Color.inkGreen
        } else {
            return self.isInPress
                ? Color.systemGray5
                : Color(light: .white, dark: .black)
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: CGFloat.accountHorizontalStackSpacing) {
                self.viewModel.icon
                    .resizable()
                    .accountIconCornerRadius
                    .aspectRatio(contentMode: .fill)
                    .accountIconFrame
                    
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
            #if canImport(UIKit)
            .padding(.top, 4)
            .padding(.horizontal, 12)
            #endif
            
            if self.viewModel.isMnemonicBased && self.viewModel.mnemonicDerivedViewModels.count != .zero {
                self.derivedAccountsGrid
                    #if canImport(UIKit)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 12)
                    #endif
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
            withAnimation(.easeInOut(duration: 1.2)) {
                self.isInBlink = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.isInBlink = false
                self.viewModel.preformBlink = false
            }
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
        #elseif canImport(AppKit)
        .contextMenu {
            Text(self.actionsForWalletDialogTitle)
            self.walletActions
        }
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
        }.keyboardShortcut("r", modifiers: [.command])
        self.specificWalletActions
        Button(Strings.showWalletKey, role: .none) {
            if let attachedWallet = self.attachedWallet {
                self.stateProvider.didTapExport(wallet: attachedWallet)
            }
        }.keyboardShortcut("s", modifiers: [.command])
        #if canImport(AppKit)
        Divider()
        #endif
        Button(Strings.removeWallet, role: .destructive) {
            if let attachedWallet = self.attachedWallet {
                self.stateProvider.didTapRemove(wallet: attachedWallet)
            }
        }.keyboardShortcut("d", modifiers: [.shift, .command])
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
    
    private var derivedAccountsGrid: some View {
        WrappingStack {
            ForEach($viewModel.mnemonicDerivedViewModels, id: \.id) { $mnemonicDerivedViewModel in
                DerivedAccountItemView(
                    viewModel: $mnemonicDerivedViewModel
                )
            }
        }
        .wrappingStackStyle(
            hSpacing: 6, vSpacing: 6, alignment: .topLeading
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

// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import BlockiesSwift

struct AccountView: View {
    struct ViewModel: Identifiable, Equatable, Hashable {
        let id: String
        let icon: Image
        let isMnemonicBased: Bool
        let accountAddress: String?
        let accountName: String
        var mnemonicDerivedViewModels: [MnemonicDerivedAccountView.ViewModel]
        var preformBlink: Bool = false
        
        func hash(into hasher: inout Hasher) { hasher.combine(self.id) }
    }
    
    @State
    private var isInPress: Bool = false
    
    @State
    private var selectedChainTitle: String?
    
    @Binding
    var viewModel: ViewModel
    
    @Binding
    var showToastOverlay: Bool
    
    @Binding
    var moreActionsSelectedElementId: String?
    
    @Binding
    var chooseWalletAccountForActions: AccountsListContentHolderView.WalletAccountIdentifier?
    
    @State
    private var isInBlink: Bool = false
    
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
                Menu {
                    Button("Order Now", action: self.moreAction)
                    Button("Adjust Order", action: {})
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
                .buttonStyle(DimmingButtonStyle())
                .offset(x: 15)
                #endif
            }
            .background(.green)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .background(self.backgroundColor)
            
            if self.viewModel.isMnemonicBased && self.viewModel.mnemonicDerivedViewModels.count != .zero {
                self.derivedAccountsGrid
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
//        .background(self.backgroundColor, ignoresSafeAreaEdges: [.leading, .trailing])
        .onTouchGesture(
            touchChanged: { isInside, hasEnded  in
                withAnimation(.linear(duration: 0.1)) {
                    self.isInPress = isInside ? true : false
                }
                // Check this!
                guard hasEnded else { return }
                self.moreActionsSelectedElementId = self.viewModel.id
            }
        )
        .onChange(of: self.selectedChainTitle) { newValue in
            guard let newValue = newValue else { return }
            self.chooseWalletAccountForActions = .init(walletId: self.viewModel.id, chainTitle: newValue)
            self.selectedChainTitle = nil
        }
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
    }
    
    private var derivedAccountsGrid: some View {
        WrappingStack {
            ForEach($viewModel.mnemonicDerivedViewModels, id: \.id) { $mnemonicDerivedViewModel in
                MnemonicDerivedAccountView(
                    viewModel: $mnemonicDerivedViewModel,
                    selectedChainTitle: $selectedChainTitle,
                    showToastOverlay: $showToastOverlay
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
    
    private func moreAction() {
        self.moreActionsSelectedElementId = viewModel.id
    }
}

struct AccountView_Previews: PreviewProvider {
    static var previews: some View {
        AccountView(
            viewModel: .constant(.init(
                id: "Some-ID",
                icon: Image("tez"),
                isMnemonicBased: true,
                accountAddress: "0x011b6e24ffb0b5f5fcc564cf4183c5bbbc96d515",
                accountName: "Some really good old name with comas,,, 🔥🔥🔥🔥🔥",
                mnemonicDerivedViewModels: []
            )),
            showToastOverlay: .constant(true),
            moreActionsSelectedElementId: .constant("false"),
            chooseWalletAccountForActions: .constant(nil)
        )
            .frame(width: 250, height: 350)
    }
}

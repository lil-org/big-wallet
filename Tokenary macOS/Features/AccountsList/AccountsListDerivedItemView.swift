// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

struct AccountsListDerivedItemView: View {
    struct ViewModel: Identifiable, Equatable {
        var id = UUID()
        var walletId: String
        var icon: Image
        var chain: ChainType
        var title: String { chain.title }
        var ticker: String { chain.ticker }
        var accountAddress: String
    }
    
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    @State
    private var areActionsForDerivedAccountPresented: Bool = false
    
    @Binding
    var viewModel: ViewModel
    
    private var attachedWallet: TokenaryWallet? { WalletsManager.shared.getWallet(id: viewModel.walletId) }

    var body: some View {
        HStack(spacing: 4) {
            viewModel.icon // нужно добавить border
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 25, height: 25)
                .clipShape(Circle())
                .shadow(
                    color: .black,
                    radius: 4, x: 1, y: 1
                )
            VStack(alignment: .leading) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(viewModel.title)
                        .foregroundColor(Color.mainText)
                        .font(.system(size: 11, weight: .regular))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                    Text("(\(viewModel.ticker))")
                        .foregroundColor(.gray)
                        .font(.system(size: 11, weight: .regular))
                        .multilineTextAlignment(.leading)
                        .fixedSize()
                        .lineLimit(1)
                }
                Text(viewModel.accountAddress)
                    .foregroundColor(Color.mainText)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .regular))
                    .multilineTextAlignment(.center)
            }
        }
        .popover(
            isPresented: $areActionsForDerivedAccountPresented,
            attachmentAnchor: .point(.trailing),
            arrowEdge: .trailing,
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(actionsForDerivedAccountDialogTitle)
                        .foregroundColor(.gray)
                    Divider()
                    copyAddressAction
                    openTransactionInScanerAction
                    showWalletKeyAction
                    removeAccountAction
                        .foregroundColor(.red)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(Color.mainText)
            }
        )
        .modifier(
            DerivedAccountViewStyleModifier(
                Color(light: .black, dark: .white),
                cornerRadius: 4,
                longPressActionClosure: {
                    // ToDo: Enable when custom gesture'll be ready.
//                    withAnimation {
//                        stateProvider.showToastOverlay = true
//                    }
                    PasteboardHelper.setPlainNotNil(viewModel.accountAddress)
                },
                onEndedActionClosure: {
                    if stateProvider.mode == .mainScreen {
                        DispatchQueue.main.async {
                            areActionsForDerivedAccountPresented = true
                        }
                    } else {
                        if let attachedWallet = self.attachedWallet {
                            stateProvider.didSelect(wallet: attachedWallet)
                        }
                    }
                }
            )
        )
    }
    
    private var actionsForDerivedAccountDialogTitle: String {
        if let address = attachedWallet?[viewModel.chain, .address] ?? nil {
            return address.trimmingAddress(sideLength: 6)
        } else {
            return "\(viewModel.chain.title) actions"
        }
    }

    private var derivedAccountActions: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            copyAddressAction
            openTransactionInScanerAction
            showWalletKeyAction
            removeAccountAction
            Button(Strings.cancel, role: .cancel, action: {})
        }
    }
    
    private var copyAddressAction: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            Button(Strings.copyAddress) {
                PasteboardHelper.setPlainNotNil(attachedWallet[viewModel.chain, .address] ?? nil)
                areActionsForDerivedAccountPresented = false
            }
        }
    }
    
    private var openTransactionInScanerAction: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            Button(viewModel.chain.transactionScaner) {
                if let address = attachedWallet[viewModel.chain, .address] ?? nil {
                    LinkHelper.open(viewModel.chain.scanURL(address))
                }
            }
        }
    }
    
    private var showWalletKeyAction: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            Button(Strings.showWalletKey) {
                stateProvider.didTapExport(wallet: attachedWallet)
            }
        }
    }
    
    private var removeAccountAction: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            if attachedWallet.associatedMetadata.allChains.count > 1 {
                Button("Remove account", role: .destructive) {
                    try? WalletsManager.shared.removeAccountIn(
                        wallet: attachedWallet,
                        account: viewModel.chain
                    )
                }
            }
        }
    }
}

private struct DerivedAccountViewStyleModifier<S>: ViewModifier where S: ShapeStyle {
    private let shapeStyle: S
    private let cornerRadius: CGFloat
    private let longPressActionClosure: () -> Void
    private let onEndedActionClosure: () -> Void
    
    @State
    private var scaleValue = CGFloat(1)
    
    init(
        _ shapeStyle: S,
        cornerRadius: CGFloat,
        longPressActionClosure: @escaping () -> Void,
        onEndedActionClosure: @escaping () -> Void
    ) {
        self.shapeStyle = shapeStyle
        self.cornerRadius = cornerRadius
        self.longPressActionClosure = longPressActionClosure
        self.onEndedActionClosure = onEndedActionClosure
    }
    
    func body(content: Content) -> some View {
        content
//            .overlay(
//                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
//                    .inset(by: -3)
//                    .stroke(shapeStyle, lineWidth: CGFloat.pixel)
//            )
//            .padding(3)
//            .scaleEffect(scaleValue, anchor: .center)
            .onTouchGesture(
                touchChanged: { (isInside, hasEnded) in
                    withAnimation {
                        if hasEnded {
                            scaleValue = 1
                        } else {
                            scaleValue = isInside ? 0.95 : 1.0
                        }
                    }
                    guard isInside, hasEnded else { return }
                    onEndedActionClosure()
                },
                useHighPriorityGesture: true,
                longPressDuration: 1,
                longPressActionClosure: longPressActionClosure
            )
    }
}

//struct MnemonicDerivedAccountView_Previews: PreviewProvider {
//    static var previews: some View {
//        DerivedAccountItemView(
//            viewModel: .constant(
//                DerivedAccountItemView.ViewModel(
//                    walletId: "1234",
//                    icon: Image(packageResource: "sberbank", ofType: "png"),
//                    chain: .algorand,
//                    accountAddress: "0x00000000219ab540356cbb839cbe05303d7705fa"
//                )
//            )
//        )
//    }
//}

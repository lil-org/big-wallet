// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import CoreServices

#if os(iOS)
import UIKit
#elseif os(macOS)
import Cocoa
#endif

extension View {
    var derivedAccountIconFrame: some View {
        #if canImport(UIKit)
        self.frame(width: 30, height: 30)
        #elseif canImport(AppKit)
        self.frame(width: 18, height: 18)
        #endif
    }
    
    var derivedAccountTextFont: some View {
        #if canImport(UIKit)
        self.font(.system(size: 14, weight: .regular))
        #elseif canImport(AppKit)
        self.font(.system(size: 11, weight: .regular))
        #endif
    }
    
    var textSizeClampingOverlay: some View {
        #if canImport(UIKit)
        self.overlay(ClampWidthView(minWidth: 100, maxWidth: 150))
        #elseif canImport(AppKit)
        self.overlay(ClampWidthView(minWidth: 70, maxWidth: 105))
        #endif
    }
}

extension CGFloat {
    static var derivedAccountBorderPadding: CGFloat {
        #if canImport(UIKit)
        8
        #elseif canImport(AppKit)
        3
        #endif
    }
    
    static var derivedAccountTextSpacing: CGFloat {
        #if canImport(UIKit)
        4
        #elseif canImport(AppKit)
        2
        #endif
    }
    
    static var derivedAccountIconSpacing: CGFloat {
        #if canImport(UIKit)
        6
        #elseif canImport(AppKit)
        4
        #endif
    }
    
    static var derivedAccountMaxBaseFrameWidth: CGFloat {
        #if canImport(UIKit)
        150
        #elseif canImport(AppKit)
        105
        #endif
    }
}

struct DerivedAccountItemView: View {
    struct ViewModel: Identifiable, Equatable {
        var id = UUID()
        var walletId: String
        var icon: Image
        var chain: ChainType
        var title: String { chain.title }
        var ticker: String { chain.ticker }
        var accountAddress: String?
        var iconShadowColor: Color
    }
    
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    @State
    private var maximumSubViewWidth: CGFloat = .zero
    
    @State
    private var areActionsForDerivedAccountPresented: Bool = false
    
    @Binding
    var viewModel: ViewModel
    
    private var attachedWallet: TokenaryWallet? {
        WalletsManager.shared.getWallet(id: viewModel.walletId)
    }
    
    private let stackUUID = UUID()

    var body: some View {
        HStack(alignment: .center, spacing: CGFloat.derivedAccountIconSpacing) {
            viewModel.icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .derivedAccountIconFrame
                .clipShape(Circle())
                .shadow(
                    color: viewModel.iconShadowColor,
                    radius: 4, x: 1, y: 1
                )
                #if canImport(AppKit)
                .offset(x: -2)
                #endif
            VStack {
                HStack(alignment: .firstTextBaseline, spacing: CGFloat.derivedAccountTextSpacing) {
                    Text(viewModel.title)
                        .foregroundColor(Color.mainText)
                        .derivedAccountTextFont
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                    Text("(\(viewModel.ticker))")
                        .foregroundColor(.gray)
                        .derivedAccountTextFont
                        .multilineTextAlignment(.leading)
                        .fixedSize()
                        .lineLimit(1)
                }
                .layoutPriority(1)
                .textSizeClampingOverlay
                
                Text(viewModel.accountAddress ?? .empty)
                    .foregroundColor(Color.mainText)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .derivedAccountTextFont
                    .layoutPriority(-1)
                    .multilineTextAlignment(.center)
                    .frame(width: maximumSubViewWidth, alignment: .center)
            }
        }
        #if canImport(AppKit)
        .offset(x: 1)
        #endif
        #if canImport(UIKit)
        .confirmationDialog(
            actionsForDerivedAccountDialogTitle,
            isPresented: $areActionsForDerivedAccountPresented,
            titleVisibility: .visible,
            actions: {
                derivedAccountActions
            }
        )
        #elseif canImport(AppKit)
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
        #endif
        #if canImport(AppKit)
        .frame(width: (viewModel.chain == .ethereum ? 80 : 70) + 30 + 6)
        #elseif canImport(UIKit)
        .frame(width: (viewModel.chain == .ethereum ? 110 : 100) + 30 + 6)
        #endif
        .onPreferenceChange(ClampWidthView.Key.self) { newWidth in
            DispatchQueue.main.async {
                maximumSubViewWidth = newWidth
            }
        }
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
            return address
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
    
    private var openTransactionInScanerAction: some View  {
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
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: -CGFloat.derivedAccountBorderPadding)
                    .stroke(shapeStyle, lineWidth: CGFloat.pixel)
            )
            .padding(CGFloat.derivedAccountBorderPadding)
            .scaleEffect(scaleValue, anchor: .center)
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

struct MnemonicDerivedAccountView_Previews: PreviewProvider {
    static var previews: some View {
        DerivedAccountItemView(
            viewModel: .constant(
                DerivedAccountItemView.ViewModel(
                    walletId: "1234",
                    icon: Image(packageResource: "sberbank", ofType: "png"),
                    chain: .algorand,
                    accountAddress: "0x00000000219ab540356cbb839cbe05303d7705fa",
                    iconShadowColor: .black
                )
            )
        )
    }
}

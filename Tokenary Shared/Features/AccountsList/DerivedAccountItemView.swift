// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import CoreServices

#if os(iOS)
import UIKit
#elseif os(macOS)
import Cocoa
#endif

struct DerivedAccountItemView: View {
    struct ViewModel: Identifiable, Equatable {
        var id = UUID()
        var walletId: String
        var icon: Image
        var title: String
        var ticker: String
        var accountAddress: String?
        var iconShadowColor: Color
        
        fileprivate var chain: SupportedChainType {
            SupportedChainType(rawValue: self.title.lowercased()) ?? .ethereum
        }
    }
    
    @EnvironmentObject
    private var stateProvider: AccountsListStateProvider
    
    @State
    private var maximumSubViewWidth: CGFloat = .zero
    
    @State
    private var areActionsForDerivedAccountPresented: Bool = false
    
    @State
    /// Used as a work-around for not correctly working frame operations
    private var viewBounds: CGRect = CGRect(x: .zero, y: .zero, width: 1000, height: .zero)
    
    @Binding
    var viewModel: ViewModel
    
    private var attachedWallet: TokenaryWallet? {
        self.stateProvider.wallets.first(
            where: { $0.id == self.viewModel.walletId }
        )
    }
    
    private let stackUUID = UUID()
    
    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            self.viewModel.icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
                .shadow(
                    color: self.viewModel.iconShadowColor,
                    radius: 4, x: 1, y: 1
                )
            VStack {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(self.viewModel.title)
                        .foregroundColor(Color(light: .black, dark: .white))
                        .font(.system(size: 14, weight: .regular))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                    Text("(\(self.viewModel.ticker))")
                        .foregroundColor(.gray)
                        .font(.system(size: 14, weight: .regular))
                        .multilineTextAlignment(.leading)
                        .fixedSize()
                        .lineLimit(1)
                }
                .layoutPriority(1)
                .overlay(ClampWidthView(minWidth: 100, maxWidth: 150))
                Text(self.viewModel.accountAddress ?? .empty)
                    .foregroundColor(Color(light: .black, dark: .white))
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .font(.system(size: 14, weight: .regular))
                    .layoutPriority(-1)
                    .multilineTextAlignment(.center)
                    .frame(width: self.maximumSubViewWidth, alignment: .center)
            }
            .saveBounds(viewId: self.stackUUID, coordinateSpace: .local)
        }
        .retrieveBounds(viewId: self.stackUUID, $viewBounds)
        .frame(width: min(self.viewBounds.size.width, 150) + 30 + 6)
        .onPreferenceChange(ClampWidthView.Key.self) { newWidth in
            DispatchQueue.main.async {
                self.maximumSubViewWidth = newWidth
            }
        }
        .modifier(
            DerivedAccountViewStyleModifier(
                Color(light: .black, dark: .white),
                cornerRadius: 4,
                longPressActionClosure: {
                    withAnimation {
                        self.stateProvider.showToastOverlay = true
                    }
                    self.copyAddressToPasteboard()
                },
                onEndedActionClosure: {
                    if self.stateProvider.mode == .mainScreen {
                        self.areActionsForDerivedAccountPresented.toggle()
                    } else {
                        if let attachedWallet = self.attachedWallet {
                            self.stateProvider.didSelect(wallet: attachedWallet)
                        }
                    }
                }
            )
        )
        .confirmationDialog(
            self.actionsForDerivedAccountDialogTitle,
            isPresented: self.$areActionsForDerivedAccountPresented,
            titleVisibility: .visible,
            actions: {
                self.derivedAccountActions
            }
        )
    }
    
    private var actionsForDerivedAccountDialogTitle: String {
        if let address = self.stateProvider.selectedWallet?[self.viewModel.chain, .address] ?? nil {
            return address
        } else {
            return "\(self.viewModel.chain.title) actions"
        }
    }

    private var derivedAccountActions: some View {
        Unwrap(self.attachedWallet) { attachedWallet in
            Button(Strings.copyAddress) {
                PasteboardHelper.setPlainNotNil(attachedWallet[self.viewModel.chain, .address] ?? nil)
            }.keyboardShortcut(.defaultAction)
            Button(self.viewModel.chain.transactionScaner) {
                if let address = attachedWallet[self.viewModel.chain, .address] ?? nil {
                    LinkHelper.open(self.viewModel.chain.scanURL(address))
                }
            }
            Button(Strings.showWalletKey) {
                self.stateProvider.didTapExport(wallet: attachedWallet)
            }
            if attachedWallet.associatedMetadata.walletDerivationType.chainTypes.count > 1 {
                Button("Remove account", role: .destructive) {
                    try? WalletsManager.shared.removeAccountIn(
                        wallet: attachedWallet,
                        account: self.viewModel.chain
                    )
                }
            }
            Button(Strings.cancel, role: .cancel, action: {})
        }
    }
    
    private func copyAddressToPasteboard() {
        PasteboardHelper.setPlainNotNil(self.viewModel.accountAddress)
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
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .inset(by: -8)
                    .stroke(self.shapeStyle, lineWidth: CGFloat.pixel)
            )
            .padding(8)
            .scaleEffect(self.scaleValue, anchor: .center)
            .onTouchGesture(
                touchChanged: { (isInside, hasEnded) in
                    withAnimation {
                        if hasEnded {
                            self.scaleValue = 1
                        } else {
                            self.scaleValue = isInside ? 0.95 : 1.0
                        }
                    }
                    guard isInside, hasEnded else { return }
                    self.onEndedActionClosure()
                },
                useHighPriorityGesture: true,
                longPressDuration: 1,
                longPressActionClosure: self.longPressActionClosure
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
                    title: "Anything else long name very long",
                    ticker: "AELNVFL",
                    accountAddress: "0x00000000219ab540356cbb839cbe05303d7705fa",
                    iconShadowColor: Color(BridgedImage(named: "sberbank.png")?.averageColor ?? .black)
                )
            )
        )
    }
}

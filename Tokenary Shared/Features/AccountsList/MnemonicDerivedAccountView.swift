// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import CoreServices

#if os(iOS)
import UIKit
#elseif os(macOS)
import Cocoa
#endif

struct MnemonicDerivedAccountView: View {
    struct ViewModel: Identifiable, Equatable {
        var id = UUID()
        var icon: Image
        var title: String
        var ticker: String
        var accountAddress: String?
        var iconShadowColor: Color
    }
    
    private let stackUUID = UUID()
    
    @State
    var maximumSubViewWidth: CGFloat = .zero
    
    @Binding
    var viewModel: ViewModel
    
    @Binding
    var selectedChainTitle: String?
    
    // Used as a work-around for not correctly working frame operations
    @State
    var viewBounds: CGRect = CGRect(x: .zero, y: .zero, width: 1000, height: .zero)
    
    @Binding
    var showToastOverlay: Bool
    
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
            MnemonicDerivedAccountViewStyleModifier(
                Color(light: .black, dark: .white),
                cornerRadius: 4,
                longPressActionClosure: {
                    withAnimation {
                        self.showToastOverlay = true
                    }
                    self.copyAddressToPasteboard()
                },
                onEndedActionClosure: {
                    self.selectedChainTitle = self.viewModel.title
                }
            )
        )
    }
    
    private func copyAddressToPasteboard() {
        PasteboardHelper.setPlainNotNil(self.viewModel.accountAddress)
    }
}

private struct MnemonicDerivedAccountViewStyleModifier<S>: ViewModifier where S: ShapeStyle {
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
                        self.scaleValue = isInside ? 0.95 : 1.0
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
        MnemonicDerivedAccountView(
            viewModel: .constant(
                MnemonicDerivedAccountView.ViewModel(
                    icon: Image(packageResource: "sberbank", ofType: "png"),
                    title: "Anything else long name very long",
                    // "Crypto Kombat"
                    ticker: "AELNVFL",
                    // "SOL"
                    accountAddress: "0x00000000219ab540356cbb839cbe05303d7705fa",
                    iconShadowColor: Color(BridgedImage(named: "sberbank.png")?.averageColor ?? .black)
                )
            ),
            selectedChainTitle: .constant("false"),
            showToastOverlay: .constant(false)
        )
    }
}

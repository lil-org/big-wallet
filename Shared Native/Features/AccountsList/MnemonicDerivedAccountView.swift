// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI
import UniformTypeIdentifiers
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
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    withAnimation {
                        self.showToastOverlay = true
                    }
                    self.copyAddressToPasteboard()
                }
        )
        .modifier(MnemonicDerivedAccountViewStyleModifier(Color(light: .black, dark: .white), cornerRadius: 4))
    }
    
    private func copyAddressToPasteboard() { // maybe think more
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(
            self.viewModel.accountAddress,
            forType: .string
        )
        #elseif canImport(UIKit)
        UIPasteboard.general.setValue(
            self.viewModel.accountAddress as Any,
            forPasteboardType: UTType.utf8PlainText.identifier
        )
        #endif
    }
}

private struct MnemonicDerivedAccountViewStyleModifier<S>: ViewModifier where S: ShapeStyle {
    private let shapeStyle: S
    private let cornerRadius: CGFloat
    
    @State
    private var scaleValue = CGFloat(1)
    
    init(_ shapeStyle: S, cornerRadius: CGFloat) {
        self.shapeStyle = shapeStyle
        self.cornerRadius = cornerRadius
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
                touchChanged: { isInside in withAnimation { self.scaleValue = isInside ? 0.95 : 1.0 } }
            )
    }
}

struct MnemonicDerivedAccountView_Previews: PreviewProvider {
    static var previews: some View {
        MnemonicDerivedAccountView(
            viewModel: .constant(
                MnemonicDerivedAccountView.ViewModel(
                    icon: Image(uiImage: UIImage(named: "sberbank.png")!),
                    title: "Anything else long name very long",
                    // "Crypto Kombat"
                    ticker: "AELNVFL",
                    // "SOL"
                    accountAddress: "0x00000000219ab540356cbb839cbe05303d7705fa",
                    iconShadowColor: Color(UIImage(named: "sberbank.png")?.averageColor ?? UIColor.black)
                )
            ), showToastOverlay: .constant(false)
        )
    }
}

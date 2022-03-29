// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

private struct GlobalOverlayViewModifier<OverlayView>: ViewModifier where OverlayView: View {
    @Binding
    var isShown: Bool
    
    let overlayView: OverlayView
    
    func body(content: Content) -> some View {
        content
            .onTapGesture {
                withAnimation {
                    isShown = false
                }
            }
            .overlay(overlay)
    }
    
    @ViewBuilder
    private var overlay: some View {
        if isShown {
            ZStack {
                overlayView
            }
        }
    }
}

extension View {
    func addToGlobalOverlay<OverlayView: View>(overlayView: OverlayView, isShown: Binding<Bool>) -> some View {
        modifier(GlobalOverlayViewModifier(isShown: isShown, overlayView: overlayView))
    }
}

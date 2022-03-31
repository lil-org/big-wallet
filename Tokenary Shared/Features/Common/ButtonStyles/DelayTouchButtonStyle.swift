// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

private struct DelaysTouchesButtonStyle: ButtonStyle {
    @Binding var isInPress: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration
            .label
            .onChange(of: configuration.isPressed, perform: handleIsPressed)
    }

    private func handleIsPressed(isPressed: Bool) {
        if isPressed {
            withAnimation(.easeInOut(duration: 0.1)) {
                isInPress = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.1)) {
                isInPress = false
            }
        }
    }
}

private struct DelaysTouches: ViewModifier {
    @Binding var isInPress: Bool

    var action: () -> Void

    func body(content: Content) -> some View {
        Button(action: action) {
            content
        }
        .buttonStyle(DelaysTouchesButtonStyle(isInPress: $isInPress))
    }
}

extension View {
    func delaysTouches(isInPress: Binding<Bool>, onTap action: @escaping () -> Void = {}) -> some View {
        modifier(DelaysTouches(isInPress: isInPress, action: action))
    }
}

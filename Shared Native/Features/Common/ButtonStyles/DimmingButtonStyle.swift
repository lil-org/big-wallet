// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

public struct DimmingButtonStyle: ButtonStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.accentColor)
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

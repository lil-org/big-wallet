// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

extension View {
    public func onSizeChange(perform action: @escaping (CGSize) -> Void) -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: OnSizeChangePreferenceKey.self, value: proxy.size
                )
            }
        )
        .onPreferenceChange(OnSizeChangePreferenceKey.self, perform: action)
    }
}

private struct OnSizeChangePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
}

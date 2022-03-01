// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

/// Can also be used instead of `frame(minWidth:maxWidth:)` since they don't work as expected
public struct ClampWidthView: View {
    typealias Key = MaximumValuePreferenceKey
    
    public let minWidth: CGFloat
    public let maxWidth: CGFloat
    
    public var body: some View {
        GeometryReader { proxy in
            Color.clear
                .anchorPreference(key: MaximumValuePreferenceKey.self, value: .bounds) {
                    min(max(self.minWidth, proxy[$0].size.width), self.maxWidth)
                }
        }
    }
}

public struct MaximumValuePreferenceKey: PreferenceKey {
    public static var defaultValue: CGFloat = .zero
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

/// Can also be used instead of `frame(minWidth:maxWidth:)` since they don't work as expected
struct ClampWidthView: View {
    typealias Key = MaximumValuePreferenceKey
    
    let minWidth: CGFloat
    let maxWidth: CGFloat
    
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .anchorPreference(key: MaximumValuePreferenceKey.self, value: .bounds) {
                    min(max(minWidth, proxy[$0].size.width), maxWidth)
                }
        }
    }
}

struct MaximumValuePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Copyright © 2022 Tokenary. All rights reserved.
// Add ability to save & retrieve bounds from element in view hierarchy

import SwiftUI

extension View {
    func saveBounds(viewId: UUID, coordinateSpace: CoordinateSpace = .global) -> some View {
        self.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SaveBoundsPreferenceKey.self,
                    value: [
                        SaveBoundsPreferenceData(viewId: viewId, bounds: proxy.frame(in: coordinateSpace))
                    ]
                )
            }
        )
    }
    
    func retrieveBounds(viewId: UUID, _ rect: Binding<CGRect>) -> some View {
        self.onPreferenceChange(SaveBoundsPreferenceKey.self) { preferences in
            DispatchQueue.main.async {
                let p = preferences.first(where: { $0.viewId == viewId })
                rect.wrappedValue = p?.bounds ?? .zero
            }
        }
    }
}

private struct SaveBoundsPreferenceData: Equatable {
    let viewId: UUID
    let bounds: CGRect
}

private struct SaveBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [SaveBoundsPreferenceData] = []
    
    static func reduce(value: inout [SaveBoundsPreferenceData], nextValue: () -> [SaveBoundsPreferenceData]) {
        value.append(contentsOf: nextValue())
    }
}

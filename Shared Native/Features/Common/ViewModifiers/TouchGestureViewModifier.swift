// Copyright © 2022 Tokenary. All rights reserved.

import SwiftUI

/// Adds ability to react to touch gesture, on a whole object not only for Control-based objects(like `Button`), but for any object
private struct TouchGestureViewModifier: ViewModifier {
    let touchChanged: (Bool) -> Void
    
    private let viewId = UUID()

    @State
    private var contentBounds: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .saveBounds(viewId: self.viewId, coordinateSpace: .local)
            .retrieveBounds(viewId: self.viewId, $contentBounds)
            .gesture(
                DragGesture(minimumDistance: .zero, coordinateSpace: .local)
                    .onChanged { value in
                        if value.location.x < .zero ||
                            value.location.y < .zero ||
                            value.location.x > self.contentBounds.size.width ||
                            value.location.y > self.contentBounds.size.height {
                            self.touchChanged(false)
                        } else {
                            self.touchChanged(true)
                        }
                    }
                    .onEnded { _ in
                        self.touchChanged(false)
                    }
        )
    }
}

extension View {
    public func onTouchGesture(touchChanged: @escaping (Bool) -> Void) -> some View {
        modifier(TouchGestureViewModifier(touchChanged: touchChanged))
    }
}

// Copyright © 2022 Tokenary. All rights reserved.
// Helper properties & methods over CGAffineTransform

import CoreGraphics

extension CGAffineTransform {
    init(from origin: CGRect, to destination: CGRect) {
        let translation = CGAffineTransform.identity
            .translatedBy(x: destination.midX - origin.midX, y: destination.midY - origin.midY)
            .scaledBy(x: destination.width - origin.width, y: destination.height - origin.height)
        self = translation
    }
}

// Copyright © 2022 Tokenary. All rights reserved.

import UIKit

extension UIImage {
    /// Forces decoding of image at the time of call
    ///
    /// Usually this operation is deferred until image is drawn to `CALayer`
    func forceLoading() -> UIImage? {
        guard size != .zero else { return nil }
        UIGraphicsBeginImageContextWithOptions(size, true, scale)
        draw(at: .zero, blendMode: .copy, alpha: 1.0)
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}

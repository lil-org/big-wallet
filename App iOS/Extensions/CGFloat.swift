// ∅ 2026 lil org

import UIKit

extension CGFloat {
    
    static let pixel: CGFloat = {
        #if os(visionOS)
        return 1
        #else
        return 1.0 / UIScreen.main.scale
        #endif
    }()
    
}

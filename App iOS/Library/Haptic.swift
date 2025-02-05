// ∅ 2025 lil org

import UIKit

struct Haptic {
    
    static func success() {
#if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
    }
    
}

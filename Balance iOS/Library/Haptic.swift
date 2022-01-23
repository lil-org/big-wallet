// Copyright © 2021 Tokenary. All rights reserved.

import UIKit

struct Haptic {
    
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    
}

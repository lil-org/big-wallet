// Copyright © 2021 Encrypted Ink. All rights reserved.

import StoreKit

struct ReviewRequster {
    
    static func requestReviewIfNeeded() {
        if let lastDate = Defaults.latestReviewRequestDate {
            if Date().timeIntervalSince(lastDate) > 190 * 24 * 3600 {
                requestReview()
            }
        } else {
            if Defaults.reviewRequestsGoodMomentsCount >= 2 {
                requestReview()
            } else {
                Defaults.reviewRequestsGoodMomentsCount += 1
            }
        }
    }
    
    private static func requestReview() {
        SKStoreReviewController.requestReview()
        Defaults.latestReviewRequestDate = Date()
    }
    
}

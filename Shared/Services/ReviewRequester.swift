// ∅ 2025 lil org

import StoreKit

struct ReviewRequster {
    
    static func requestReviewIfNeeded(in scene: Any?) {
        if let lastDate = Defaults.latestReviewRequestDate {
            if Date().timeIntervalSince(lastDate) > 190 * 24 * 3600 {
                requestReview(in: scene)
            }
        } else {
            if Defaults.reviewRequestsGoodMomentsCount >= 2 {
                requestReview(in: scene)
            } else {
                Defaults.reviewRequestsGoodMomentsCount += 1
            }
        }
    }

    static func didClickAppStoreReviewButton() {
        didRequestReview()
        if let url = URL(string: "https://apps.apple.com/app/id6478607925?action=write-review") {
            UIApplication.shared.open(url)
        }
    }
    
    private static func requestReview(in scene: Any?) {
#if os(macOS)
        SKStoreReviewController.requestReview()
#else
        if let scene = scene as? UIWindowScene {
            SKStoreReviewController.requestReview(in: scene)
        }
#endif
        didRequestReview()
    }
    
    private static func didRequestReview() {
        Defaults.latestReviewRequestDate = Date()
    }
    
}

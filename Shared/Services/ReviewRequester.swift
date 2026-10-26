import WalletDomain
import WalletAuthority
import WalletNetworking
// ∅ 2026 lil org

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
struct ReviewRequster {
    
    static func didClickAppStoreReviewButton() {
        didRequestReview()
        if let url = URL(string: "https://apps.apple.com/app/id6478607925?action=write-review") {
#if os(macOS)
            NSWorkspace.shared.open(url)
#else
            UIApplication.shared.open(url)
#endif
        }
    }
    
    private static func didRequestReview() {
        ApplicationServices.shared.authority.recordReviewRequest(at: Date())
    }
    
}

// ∅ 2026 lil org

import Foundation
import UniformTypeIdentifiers

extension URL {
    
    static let x = URL(string: "https://x.com/lildotorg")!
    static let farcaster = URL(string: "https://farcaster.xyz/org")!
    static let github = URL(string: "https://github.com/lil-org")!
    static let email = URL(string: "mailto:yo@lil.org")!
    static let quickFeedbackMail = URL(string: "mailto:yo@lil.org?subject=Big%20Wallet")!
    static let iosSafariGuide = URL(string: "https://lil.org/guide-ios")!
    
    var mimeType: String {
        if let typeIdentifier = (try? resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
            let utType = UTType(typeIdentifier) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        } else {
            return "application/octet-stream"
        }
    }
    
}

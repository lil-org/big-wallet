// ∅ 2025 lil org

import Foundation
import UniformTypeIdentifiers

extension URL {
    
    static let x = URL(string: "https://x.com/lildotorg")!
    static let warpcast = URL(string: "https://warpcast.com/org")!
    static let zora = URL(string: "https://zora.co/collect/zora:0x01c077fd6b4df827490cd4f95650d55d6b35c35d")!
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

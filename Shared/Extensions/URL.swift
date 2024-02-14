// ∅ 2024 lil org

import Foundation
import UniformTypeIdentifiers

extension URL {
    
    static let x = URL(string: "https://tokenary.io/x")!
    static let warpcast = URL(string: "https://warpcast.com/org")!
    static let github = URL(string: "https://tokenary.io/github")!
    static let email = URL(string: "mailto:support@tokenary.io")!
    static let iosSafariGuide = URL(string: "https://tokenary.io/guide-ios")!
    static let updateApp = URL(string: "https://lil.org/update")!
    static let farcasterScheme = URL(string: "farcaster://")!
    
    var mimeType: String {
        if let typeIdentifier = (try? resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
            let utType = UTType(typeIdentifier) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        } else {
            return "application/octet-stream"
        }
    }
    
}

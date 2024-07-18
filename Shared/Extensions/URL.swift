// ∅ 2024 lil org

import Foundation
import UniformTypeIdentifiers

extension URL {
    
    static let x = URL(string: "https://x.lil.org")!
    static let warpcast = URL(string: "https://f.lil.org")!
    static let zora = URL(string: "https://mint.lil.org")!
    static let github = URL(string: "https://g.lil.org")!
    static let email = URL(string: "mailto:support@lil.org")!
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

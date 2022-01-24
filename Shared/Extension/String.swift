// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

extension String {
    
    var maybeJSON: Bool {
        return hasPrefix("{") && hasSuffix("}") && count > 3
    }
    
    var isOkAsPassword: Bool {
        return count >= 4
    }
    
    var withFirstLetterCapitalized: String {
        guard !isEmpty else { return self }
        return prefix(1).uppercased() + dropFirst()
    }
    
    var withEllipsis: String {
        return self + "…"
    }
    
    var trimmedAddress: String {
        guard !isEmpty else { return self }
        return "\(prefix(6))...\(suffix(4))"
    }
    
    var multilineAddress: String {
        guard !isEmpty else { return self }
        return "\(prefix(21))\n\(suffix(21))"
    }
    
}

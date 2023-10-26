// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

extension String {
    
    static let hexPrefix = "0x"
    
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
    
    var cleanHex: String {
        if hasPrefix(String.hexPrefix) {
            return String(dropFirst(2))
        } else {
            return self
        }
    }
    
    var withHexPrefix: String {
        return String.hexPrefix + self
    }
    
    static func hex<T>(_ value: T) -> String where T : BinaryInteger {
        return String(value, radix: 16)
    }
    
}

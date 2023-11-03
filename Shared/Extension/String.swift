// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

extension String {
    
    static let hexPrefix = "0x"
    static let zero = "0"
    
    var cleanEvenHex: String {
        let clean = cleanHex
        if clean.count.isMultiple(of: 2) {
            return clean
        } else {
            return String.zero + clean
        }
    }
    
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
        return self + "..."
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
    
    static func hex<T>(_ value: T, withPrefix: Bool = false) -> String where T : BinaryInteger {
        let prefix = withPrefix ? hexPrefix : ""
        return prefix + String(value, radix: 16)
    }
    
    var singleSpaced: String {
        let trimmedString = self.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleSpacedString = trimmedString.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression, range: nil)
        return singleSpacedString
    }
    
}

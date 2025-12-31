// ∅ 2026 lil org

import Foundation

extension String {
    
    static let hexPrefix = "0x"
    static let zero = "0"
    
    var cleanEvenHex: String {
        let clean = cleanHex
        return clean.count.isMultiple(of: 2) ? clean : String.zero + clean
    }
    
    var maybeJSON: Bool {
        hasPrefix("{") && hasSuffix("}") && count > 3
    }
    
    var isOkAsPassword: Bool {
        count >= 4
    }
    
    var withFirstLetterCapitalized: String {
        guard !isEmpty else { return self }
        return prefix(1).uppercased() + dropFirst()
    }
    
    var withEllipsis: String {
        self + "..."
    }
    
    var cleanHex: String {
        hasPrefix(String.hexPrefix) ? String(dropFirst(2)) : self
    }
    
    var withHexPrefix: String {
        String.hexPrefix + self
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

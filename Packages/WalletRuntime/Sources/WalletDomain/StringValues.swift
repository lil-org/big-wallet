// ∅ 2026 lil org

import Foundation

extension String {
    
    public static let hexPrefix = "0x"
    public static let zero = "0"
    
    public var cleanEvenHex: String {
        let clean = cleanHex
        return clean.count.isMultiple(of: 2) ? clean : String.zero + clean
    }
    
    public var maybeJSON: Bool {
        hasPrefix("{") && hasSuffix("}") && count > 3
    }
    
    public var isOkAsPassword: Bool {
        count >= 4
    }
    
    public var withFirstLetterCapitalized: String {
        guard !isEmpty else { return self }
        return prefix(1).uppercased() + dropFirst()
    }
    
    public var withEllipsis: String {
        self + "..."
    }
    
    public var cleanHex: String {
        hasPrefix(String.hexPrefix) ? String(dropFirst(2)) : self
    }
    
    public var withHexPrefix: String {
        String.hexPrefix + self
    }
    
    public static func hex<T>(_ value: T, withPrefix: Bool = false) -> String where T : BinaryInteger {
        let prefix = withPrefix ? hexPrefix : ""
        return prefix + String(value, radix: 16)
    }
    
    public var singleSpaced: String {
        let trimmedString = self.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleSpacedString = trimmedString.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression, range: nil)
        return singleSpacedString
    }
    
}

// Copyright © 2022 Tokenary. All rights reserved.
// Helper extensions for working with `String` types

import Foundation

extension String {
    public static var empty: String = ""
    
    public var isValidEmail: Bool {
        let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        let emailTest = NSPredicate(format: "SELF MATCHES %@", emailRegEx)
        return emailTest.evaluate(with: self)
    }
    
    public func removingOccurrences(of substrings: [String]) -> String {
        var result = self
        substrings.forEach { character in
            result = result.replacingOccurrences(of: character, with: String.empty)
        }
        return result
    }
}

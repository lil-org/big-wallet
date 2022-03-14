// Copyright © 2022 Tokenary. All rights reserved.
// Helper extensions for working with `Optional` types

import Foundation

extension Optional {
    
    // MARK: - Public Properties
    
    public var isNil: Bool {
        if case Optional.none = self {
            return true
        } else {
            return false
        }
    }
    
    // MARK: - Public Methods
    
    public func ensure(
        hint hintExpression: @autoclosure () -> String? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Wrapped {
        guard
            let unwrapped = self
        else {
            var message = "Value was nil in \(file), at line \(line)"

            if let hint = hintExpression() {
                message.append(". Debugging hint: \(hint)")
            }

            let exception = NSException(
                name: .invalidArgumentException, reason: message, userInfo: nil
            )
            exception.raise()
            
            preconditionFailure(message)
        }
        return unwrapped
    }
}

extension Optional where Wrapped == String {
    public var orEmpty: String {
        switch self {
        case .none:
            return .empty
        case let .some(wrapped):
            return wrapped
        }
    }
}

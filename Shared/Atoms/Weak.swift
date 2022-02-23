// Copyright © 2022 Tokenary. All rights reserved.
// Wrapper for weak objects

import Foundation

public struct Weak<Object> {
    typealias ObjectProvider = () -> Object?
    public var object: Object? { provider?() }
    private let provider: ObjectProvider?

    public init(_ object: Object?) {
        let reference = object as AnyObject

        provider = { [weak reference] in
            reference as? Object
        }
    }
}

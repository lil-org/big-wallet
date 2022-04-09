// Copyright © 2022 Tokenary. All rights reserved.
// Wrapper for weak objects

import Foundation

struct Weak<Object> {
    typealias ObjectProvider = () -> Object?
    var object: Object? { provider?() }
    private let provider: ObjectProvider?

    init(_ object: Object?) {
        let reference = object as AnyObject

        provider = { [weak reference] in
            reference as? Object
        }
    }
}

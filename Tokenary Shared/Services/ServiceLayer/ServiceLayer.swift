// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

// ToDo - Rewrite service using observable/observer pattern
//                  Values must be passed as sequences
// ToDo - Make a normal ServiceRegistry structure, to manage Singletons
// ToDo - Add ledgers support here
// ToDo - Mock/real service shared abstractions
final class ServiceLayer {
    static var operationQueue: OperationQueue = {
        OperationQueue()
    }()

    init() {}
    
    struct Services { }
}

// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

// ToDo(@NumenZ) - Rewrite service using observable/observer pattern
//                  Values must be passed as sequences
// ToDo(@NumenZ) - Make a normal ServiceRegistry structure, to manage Singletons
// ToDo(@pettrk) - Add ledgers support here
// ToDo(@NumenZ) - Mock/real service shared abstractions
public final class ServiceLayer {
    static var operationQueue: OperationQueue = {
        OperationQueue()
    }()

    public init() {}
    
    public struct Services { }
    
    public static var services: Services = Services()
}

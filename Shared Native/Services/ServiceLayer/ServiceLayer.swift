// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

public final class ServiceLayer {
    static var operationQueue: OperationQueue = {
        OperationQueue()
    }()

    public init() {}
    
//    public struct Ledgers { } ToDo(@pettrk): maybe include here
    public struct Services { }
    
//    public static var ledgers: Ledgers = Ledgers() ToDo(@pettrk): maybe include here
    public static var services: Services = Services()
}

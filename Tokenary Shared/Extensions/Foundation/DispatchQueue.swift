// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

extension DispatchQueue {
    static func safeMainSync<T>(_ block: @escaping () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try block()
        } else {
            return try DispatchQueue.main.sync(execute: block)
        }
    }
    
    static func safeMainAsync(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

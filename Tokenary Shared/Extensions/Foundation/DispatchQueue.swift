// Copyright © 2022 Tokenary. All rights reserved.
// Helper methods over DispatchQueue

import Foundation

extension DispatchQueue {
    
    // MARK: - Public Properties
    
    public var isQueueCurrent: Bool { DispatchQueue.isQueueCurrent(self) }
    
    // MARK: - Public Methods
    
    public class func safeMainSync(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }
    
    public class func once(file: String = #file, function: String = #function, line: Int = #line, block: () -> Void) {
        let token = file + ":" + function + ":" + String(line)
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        if _onceTracker.contains(token) {
            return
        }
        _onceTracker.append(token)
        block()
    }
    
    public class func isQueueCurrent(_ queue: DispatchQueue) -> Bool {
        let value = OSAtomicIncrement32(&DispatchQueue.currentQueueValue)
        queue.setSpecific(key: key, value: value)
        let valueOnCurrentQueue = self.getSpecific(key: key)
        queue.setSpecific(key: key, value: nil)
        return value == valueOnCurrentQueue
    }
    
    // MARK: - Private Properties

    private static var _onceTracker: [String] = []
    
    private static var currentQueueValue: Int32 = .zero

    /// According to [here](http://tom.lokhorst.eu/2018/02/leaky-abstractions-in-swift-with-dispatchqueue) addresses change
    private static let key = DispatchSpecificKey<Int32>()
}

// Copyright © 2022 Tokenary. All rights reserved.
// Simple wrapper, to feed to Timer.
//  Otherwise, you would always need to declare new `@objc` function, just call the one you need
//
// Example usage:
//
// let timer = Timer(
//    timeInterval: 0.3,
//    target: TimerWrapper({ [weak self] in self?.somth() }),
//    selector: #selector(TimerWrapper.onEvent),
//    userInfo: nil,
//    repeats: false
// )
// RunLoop.main.add(timer, forMode: .common)

import Foundation

public final class TimerWrapper: NSObject {
    private let trigger: () -> Void
    
    public init(_ trigger: @escaping () -> Void) {
        self.trigger = trigger
    }
    
    @objc public func onEvent() { self.trigger() }
}

// Copyright © 2022 Tokenary. All rights reserved.
// Helper extensions for working with general-purpose `Collection`s

import Foundation

extension Collection {
    // MARK: - Public Variables
    
    public var isSingle: Bool { count == 1 }
    
    // MARK: - Public Methods
    
    public func take(atMost atMostCount: Int) -> [Element] {
        return Array(self.prefix(atMostCount))
    }
}

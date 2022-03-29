// Copyright © 2022 Tokenary. All rights reserved.
// Helper extensions for working with general-purpose `Collection`s

import Foundation

extension Collection {
    // MARK: - Variables
    
    var isSingle: Bool { count == 1 }
    
    // MARK: - Methods
    
    func take(atMost atMostCount: Int) -> [Element] {
        return Array(prefix(atMostCount))
    }
    
    // MARK: - Subscripts
    
    subscript(safe index: Index) -> Iterator.Element? {
        if
            distance(to: index) >= .zero,
            distance(from: index) > .zero {
            return self[index]
        }
        return nil
    }
    
    // MARK: - Private Methods
    
    private func distance(from startIndex: Index) -> Int {
        distance(from: startIndex, to: endIndex)
    }

    private func distance(to endIndex: Index) -> Int {
        distance(from: startIndex, to: endIndex)
    }
}

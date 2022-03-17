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

    // MARK: - Public Subscripts
    
    public subscript(safe index: Index) -> Iterator.Element? {
        if
            distance(to: index) >= .zero,
            distance(from: index) > .zero {
            return self[index]
        }
        return nil
    }

    public subscript(safe bounds: Range<Index>) -> SubSequence? {
        if
            distance(to: bounds.lowerBound) >= .zero,
            distance(from: bounds.upperBound) >= .zero {
            return self[bounds]
        }
        return nil
    }

    public subscript(safe bounds: ClosedRange<Index>) -> SubSequence? {
        if
            distance(to: bounds.lowerBound) >= .zero,
            distance(from: bounds.upperBound) > .zero {
            return self[bounds]
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

extension Collection where Element: Equatable {
    public var unique: [Element] {
        self.reduce([]) { accumulator, element in
            accumulator.contains(element)
                ? accumulator
                : accumulator + [element]
        }
    }
    
    public var uniqueLatest: [Element] { self.reversed().unique.reversed() }
}

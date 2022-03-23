// Copyright © 2022 Tokenary. All rights reserved.

import Foundation

struct SynchronizedArray<T>: RangeReplaceableCollection {

    typealias Element = T
    typealias Index = Int
    typealias SubSequence = SynchronizedArray<T>
    typealias Indices = Range<Int>
    fileprivate var array: Array<T>
    var startIndex: Int { return array.startIndex }
    var endIndex: Int { return array.endIndex }
    var indices: Range<Int> { return array.indices }

    func index(after i: Int) -> Int { return array.index(after: i) }

    private var semaphore = DispatchSemaphore(value: 1)
    fileprivate func _wait() { semaphore.wait() }
    fileprivate func _signal() { semaphore.signal() }
}

// MARK: - Instance Methods

extension SynchronizedArray {

    init<S>(_ elements: S) where S : Sequence, SynchronizedArray.Element == S.Element {
        array = Array<S.Element>(elements)
    }

    init() { self.init([]) }

    init(repeating repeatedValue: SynchronizedArray.Element, count: Int) {
        let array = Array(repeating: repeatedValue, count: count)
        self.init(array)
    }
}

// MARK: - Instance Methods

extension SynchronizedArray {

    public mutating func append(_ newElement: SynchronizedArray.Element) {
        _wait(); defer { _signal() }
        array.append(newElement)
    }

    public mutating func append<S>(contentsOf newElements: S) where S : Sequence, SynchronizedArray.Element == S.Element {
        _wait(); defer { _signal() }
        array.append(contentsOf: newElements)
    }

    func filter(_ isIncluded: (SynchronizedArray.Element) throws -> Bool) rethrows -> SynchronizedArray {
        _wait(); defer { _signal() }
        let subArray = try array.filter(isIncluded)
        return SynchronizedArray(subArray)
    }

    public mutating func insert(_ newElement: SynchronizedArray.Element, at i: SynchronizedArray.Index) {
        _wait(); defer { _signal() }
        array.insert(newElement, at: i)
    }

    mutating func insert<S>(contentsOf newElements: S, at i: SynchronizedArray.Index) where S : Collection, SynchronizedArray.Element == S.Element {
        _wait(); defer { _signal() }
        array.insert(contentsOf: newElements, at: i)
    }

    mutating func popLast() -> SynchronizedArray.Element? {
        _wait(); defer { _signal() }
        return array.popLast()
    }

    @discardableResult mutating func remove(at i: SynchronizedArray.Index) -> SynchronizedArray.Element {
        _wait(); defer { _signal() }
        return array.remove(at: i)
    }

    mutating func removeAll() {
        _wait(); defer { _signal() }
        array.removeAll()
    }

    mutating func removeAll(keepingCapacity keepCapacity: Bool) {
        _wait(); defer { _signal() }
        array.removeAll()
    }

    mutating func removeAll(where shouldBeRemoved: (SynchronizedArray.Element) throws -> Bool) rethrows {
        _wait(); defer { _signal() }
        try array.removeAll(where: shouldBeRemoved)
    }

    @discardableResult mutating func removeFirst() -> SynchronizedArray.Element {
        _wait(); defer { _signal() }
        return array.removeFirst()
    }

    mutating func removeFirst(_ k: Int) {
        _wait(); defer { _signal() }
        array.removeFirst(k)
    }

    @discardableResult mutating func removeLast() -> SynchronizedArray.Element {
        _wait(); defer { _signal() }
        return array.removeLast()
    }

    mutating func removeLast(_ k: Int) {
        _wait(); defer { _signal() }
        array.removeLast(k)
    }

    @inlinable public func forEach(_ body: (Element) throws -> Void) rethrows {
        _wait(); defer { _signal() }
        try array.forEach(body)
    }

    mutating func removeFirstIfExist(where shouldBeRemoved: (SynchronizedArray.Element) throws -> Bool) {
        _wait(); defer { _signal() }
        guard let index = try? array.firstIndex(where: shouldBeRemoved) else { return }
        array.remove(at: index)
    }

    mutating func removeSubrange(_ bounds: Range<Int>) {
        _wait(); defer { _signal() }
        array.removeSubrange(bounds)
    }

    mutating func replaceSubrange<C, R>(_ subrange: R, with newElements: C) where C : Collection, R : RangeExpression, T == C.Element, SynchronizedArray<Element>.Index == R.Bound {
        _wait(); defer { _signal() }
        array.replaceSubrange(subrange, with: newElements)
    }

    mutating func reserveCapacity(_ n: Int) {
        _wait(); defer { _signal() }
        array.reserveCapacity(n)
    }

    public var count: Int {
        _wait(); defer { _signal() }
        return array.count
    }

    public var isEmpty: Bool {
        _wait(); defer { _signal() }
        return array.isEmpty
    }
}

// MARK: - Get/Set

extension SynchronizedArray {

    // Single  action

    func get() -> [T] {
        _wait(); defer { _signal() }
        return array
    }

    mutating func set(array: [T]) {
        _wait(); defer { _signal() }
        self.array = array
    }

    // Multy actions

    mutating func get(closure: ([T])->()) {
        _wait(); defer { _signal() }
        closure(array)
    }

    mutating func set(closure: ([T]) -> ([T])) {
        _wait(); defer { _signal() }
        array = closure(array)
    }
}

// MARK: - Subscripts

extension SynchronizedArray {

    subscript(bounds: Range<SynchronizedArray.Index>) -> SynchronizedArray.SubSequence {
        get {
            _wait(); defer { _signal() }
            return SynchronizedArray(array[bounds])
        }
    }

    subscript(bounds: SynchronizedArray.Index) -> SynchronizedArray.Element {
        get {
            _wait(); defer { _signal() }
            return array[bounds]
        }
        set(value) {
            _wait(); defer { _signal() }
            array[bounds] = value
        }
    }
}

// MARK: - Operator Functions

extension SynchronizedArray {

    static func + <Other>(lhs: Other, rhs: SynchronizedArray) -> SynchronizedArray where Other : Sequence, SynchronizedArray.Element == Other.Element {
        return SynchronizedArray(lhs + rhs.get())
    }

    static func + <Other>(lhs: SynchronizedArray, rhs: Other) -> SynchronizedArray where Other : Sequence, SynchronizedArray.Element == Other.Element {
        return SynchronizedArray(lhs.get() + rhs)
    }

    static func + <Other>(lhs: SynchronizedArray, rhs: Other) -> SynchronizedArray where Other : RangeReplaceableCollection, SynchronizedArray.Element == Other.Element {
        return SynchronizedArray(lhs.get() + rhs)
    }

    static func + (lhs: SynchronizedArray<Element>, rhs: SynchronizedArray<Element>) -> SynchronizedArray {
        return SynchronizedArray(lhs.get() + rhs.get())
    }

    static func += <Other>(lhs: inout SynchronizedArray, rhs: Other) where Other : Sequence, SynchronizedArray.Element == Other.Element {
        lhs._wait(); defer { lhs._signal() }
        lhs.array += rhs
    }
}

// MARK: - CustomStringConvertible

extension SynchronizedArray: CustomStringConvertible {
    var description: String {
        _wait(); defer { _signal() }
        return "\(array)"
    }
}

// MARK: - Equatable

extension SynchronizedArray where Element : Equatable {

    func split(separator: Element, maxSplits: Int, omittingEmptySubsequences: Bool) -> [ArraySlice<Element>] {
        _wait(); defer { _signal() }
        return array.split(separator: separator, maxSplits: maxSplits, omittingEmptySubsequences: omittingEmptySubsequences)
    }

    func firstIndex(of element: Element) -> Int? {
        _wait(); defer { _signal() }
        return array.firstIndex(of: element)
    }

    func lastIndex(of element: Element) -> Int? {
        _wait(); defer { _signal() }
        return array.lastIndex(of: element)
    }

    func starts<PossiblePrefix>(with possiblePrefix: PossiblePrefix) -> Bool where PossiblePrefix : Sequence, Element == PossiblePrefix.Element {
        _wait(); defer { _signal() }
        return array.starts(with: possiblePrefix)
    }

    func elementsEqual<OtherSequence>(_ other: OtherSequence) -> Bool where OtherSequence : Sequence, Element == OtherSequence.Element {
        _wait(); defer { _signal() }
        return array.elementsEqual(other)
    }

    func contains(_ element: Element) -> Bool {
        _wait(); defer { _signal() }
        return array.contains(element)
    }

    static func != (lhs: SynchronizedArray<Element>, rhs: SynchronizedArray<Element>) -> Bool {
        lhs._wait(); defer { lhs._signal() }
        rhs._wait(); defer { rhs._signal() }
        return lhs.array != rhs.array
    }

    static func == (lhs: SynchronizedArray<Element>, rhs: SynchronizedArray<Element>) -> Bool {
        lhs._wait(); defer { lhs._signal() }
        rhs._wait(); defer { rhs._signal() }
        return lhs.array == rhs.array
    }
}

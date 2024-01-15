// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// A vector of TWData byte arrays
public final class DataVector {

    /// Retrieve the number of elements
    ///
    /// - Parameter dataVector: A non-null Vector of data
    /// - Returns: the size of the given vector.
    public var size: Int {
        return TWDataVectorSize(rawValue)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = TWDataVectorCreate()
    }

    public init(data: Data) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        rawValue = TWDataVectorCreateWithData(dataData)
    }

    deinit {
        TWDataVectorDelete(rawValue)
    }

    /// Add an element to a Vector of Data. Element is cloned
    ///
    /// - Parameter dataVector: A non-null Vector of data
    /// - Parameter data: A non-null valid block of data
    /// - Note: data input parameter must be deleted on its own
    public func add(data: Data) -> Void {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataVectorAdd(rawValue, dataData)
    }

    /// Retrieve the n-th element.
    ///
    /// - Parameter dataVector: A non-null Vector of data
    /// - Parameter index: index element of the vector to be retrieved, need to be < TWDataVectorSize
    /// - Note: Returned element must be freed with \TWDataDelete
    /// - Returns: A non-null block of data
    public func get(index: Int) -> Data? {
        guard let result = TWDataVectorGet(rawValue, index) else {
            return nil
        }
        return TWDataNSData(result)
    }

}

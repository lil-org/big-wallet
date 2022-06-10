// Copyright © 2017-2022 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class DataVector {

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

    public func add(data: Data) -> Void {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        return TWDataVectorAdd(rawValue, dataData)
    }

    public func get(index: Int) -> Data? {
        guard let result = TWDataVectorGet(rawValue, index) else {
            return nil
        }
        return TWDataNSData(result)
    }

}

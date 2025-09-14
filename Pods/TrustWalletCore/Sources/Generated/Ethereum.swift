// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation


public final class Ethereum {

    /// Returns the checksummed address.
    /// 
    /// - Parameter address: *non-null* string.
    /// - Returns: the checksummed address.
    public static func addressChecksummed(address: String) -> String? {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        guard let result = TWEthereumAddressChecksummed(addressString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Returns the account path from address.
    /// 
    /// - Parameter eth_address: *non-null* string.
    /// - Parameter layer: *non-null* string.
    /// - Parameter application: *non-null* string.
    /// - Parameter index: *non-null* string.
    /// - Returns: the account path.
    public static func eip2645GetPath(ethAddress: String, layer: String, application: String, index: String) -> String? {
        let ethAddressString = TWStringCreateWithNSString(ethAddress)
        defer {
            TWStringDelete(ethAddressString)
        }
        let layerString = TWStringCreateWithNSString(layer)
        defer {
            TWStringDelete(layerString)
        }
        let applicationString = TWStringCreateWithNSString(application)
        defer {
            TWStringDelete(applicationString)
        }
        let indexString = TWStringCreateWithNSString(index)
        defer {
            TWStringDelete(indexString)
        }
        guard let result = TWEthereumEip2645GetPath(ethAddressString, layerString, applicationString, indexString) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Returns EIP-1014 Create2 address
    /// 
    /// - Parameter from: *non-null* string.
    /// - Parameter salt: *non-null* data.
    /// - Parameter init_code_hash: *non-null* data.
    /// - Returns: the EIP-1014 Create2 address.
    public static func eip1014Create2Address(from: String, salt: Data, initCodeHash: Data) -> String? {
        let fromString = TWStringCreateWithNSString(from)
        defer {
            TWStringDelete(fromString)
        }
        let saltData = TWDataCreateWithNSData(salt)
        defer {
            TWDataDelete(saltData)
        }
        let initCodeHashData = TWDataCreateWithNSData(initCodeHash)
        defer {
            TWDataDelete(initCodeHashData)
        }
        guard let result = TWEthereumEip1014Create2Address(fromString, saltData, initCodeHashData) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Returns EIP-1967 proxy init code
    /// 
    /// - Parameter logic_address: *non-null* string.
    /// - Parameter data: *non-null* data.
    /// - Returns: the EIP-1967 proxy init code.
    public static func eip1967ProxyInitCode(logicAddress: String, data: Data) -> Data? {
        let logicAddressString = TWStringCreateWithNSString(logicAddress)
        defer {
            TWStringDelete(logicAddressString)
        }
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        guard let result = TWEthereumEip1967ProxyInitCode(logicAddressString, dataData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }


}

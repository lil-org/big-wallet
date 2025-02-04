// SPDX-License-Identifier: Apache-2.0
//
// Copyright © 2017 Trust Wallet.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Bitcoin script manipulating functions
public final class BitcoinScript {

    /// Determines whether 2 scripts have the same content
    ///
    /// - Parameter lhs: Non-null pointer to the first script
    /// - Parameter rhs: Non-null pointer to the second script
    /// - Returns: true if both script have the same content
    public static func == (lhs: BitcoinScript, rhs: BitcoinScript) -> Bool {
        return TWBitcoinScriptEqual(lhs.rawValue, rhs.rawValue)
    }

    /// Builds a standard 'pay to public key' script.
    ///
    /// - Parameter pubkey: Non-null pointer to a pubkey
    /// - Note: Must be deleted with \TWBitcoinScriptDelete
    /// - Returns: A pointer to the built script
    public static func buildPayToPublicKey(pubkey: Data) -> BitcoinScript {
        let pubkeyData = TWDataCreateWithNSData(pubkey)
        defer {
            TWDataDelete(pubkeyData)
        }
        return BitcoinScript(rawValue: TWBitcoinScriptBuildPayToPublicKey(pubkeyData))
    }

    /// Builds a standard 'pay to public key hash' script.
    ///
    /// - Parameter hash: Non-null pointer to a PublicKey hash
    /// - Note: Must be deleted with \TWBitcoinScriptDelete
    /// - Returns: A pointer to the built script
    public static func buildPayToPublicKeyHash(hash: Data) -> BitcoinScript {
        let hashData = TWDataCreateWithNSData(hash)
        defer {
            TWDataDelete(hashData)
        }
        return BitcoinScript(rawValue: TWBitcoinScriptBuildPayToPublicKeyHash(hashData))
    }

    /// Builds a standard 'pay to script hash' script.
    ///
    /// - Parameter scriptHash: Non-null pointer to a script hash
    /// - Note: Must be deleted with \TWBitcoinScriptDelete
    /// - Returns: A pointer to the built script
    public static func buildPayToScriptHash(scriptHash: Data) -> BitcoinScript {
        let scriptHashData = TWDataCreateWithNSData(scriptHash)
        defer {
            TWDataDelete(scriptHashData)
        }
        return BitcoinScript(rawValue: TWBitcoinScriptBuildPayToScriptHash(scriptHashData))
    }

    /// Builds a pay-to-witness-public-key-hash (P2WPKH) script..
    ///
    /// - Parameter hash: Non-null pointer to a witness public key hash
    /// - Note: Must be deleted with \TWBitcoinScriptDelete
    /// - Returns: A pointer to the built script
    public static func buildPayToWitnessPubkeyHash(hash: Data) -> BitcoinScript {
        let hashData = TWDataCreateWithNSData(hash)
        defer {
            TWDataDelete(hashData)
        }
        return BitcoinScript(rawValue: TWBitcoinScriptBuildPayToWitnessPubkeyHash(hashData))
    }

    /// Builds a pay-to-witness-script-hash (P2WSH) script.
    ///
    /// - Parameter scriptHash: Non-null pointer to a script hash
    /// - Note: Must be deleted with \TWBitcoinScriptDelete
    /// - Returns: A pointer to the built script
    public static func buildPayToWitnessScriptHash(scriptHash: Data) -> BitcoinScript {
        let scriptHashData = TWDataCreateWithNSData(scriptHash)
        defer {
            TWDataDelete(scriptHashData)
        }
        return BitcoinScript(rawValue: TWBitcoinScriptBuildPayToWitnessScriptHash(scriptHashData))
    }

    /// Builds a appropriate lock script for the given address..
    ///
    /// - Parameter address: Non-null pointer to an address
    /// - Parameter coin: coin type
    /// - Note: Must be deleted with \TWBitcoinScriptDelete
    /// - Returns: A pointer to the built script
    public static func lockScriptForAddress(address: String, coin: CoinType) -> BitcoinScript {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        return BitcoinScript(rawValue: TWBitcoinScriptLockScriptForAddress(addressString, TWCoinType(rawValue: coin.rawValue)))
    }

    /// Builds a appropriate lock script for the given address with replay.
    public static func lockScriptForAddressReplay(address: String, coin: CoinType, blockHash: Data, blockHeight: Int64) -> BitcoinScript {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        let blockHashData = TWDataCreateWithNSData(blockHash)
        defer {
            TWDataDelete(blockHashData)
        }
        return BitcoinScript(rawValue: TWBitcoinScriptLockScriptForAddressReplay(addressString, TWCoinType(rawValue: coin.rawValue), blockHashData, blockHeight))
    }

    /// Return the default HashType for the given coin, such as TWBitcoinSigHashTypeAll.
    ///
    /// - Parameter coinType: coin type
    /// - Returns: default HashType for the given coin
    public static func hashTypeForCoin(coinType: CoinType) -> UInt32 {
        return TWBitcoinScriptHashTypeForCoin(TWCoinType(rawValue: coinType.rawValue))
    }

    /// Get size of a script
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: size of the script
    public var size: Int {
        return TWBitcoinScriptSize(rawValue)
    }

    /// Get data of a script
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: data of the given script
    public var data: Data {
        return TWDataNSData(TWBitcoinScriptData(rawValue))
    }

    /// Return script hash of a script
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: script hash of the given script
    public var scriptHash: Data {
        return TWDataNSData(TWBitcoinScriptScriptHash(rawValue))
    }

    /// Determines whether this is a pay-to-script-hash (P2SH) script.
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: true if this is a pay-to-script-hash (P2SH) script, false otherwise
    public var isPayToScriptHash: Bool {
        return TWBitcoinScriptIsPayToScriptHash(rawValue)
    }

    /// Determines whether this is a pay-to-witness-script-hash (P2WSH) script.
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: true if this is a pay-to-witness-script-hash (P2WSH) script, false otherwise
    public var isPayToWitnessScriptHash: Bool {
        return TWBitcoinScriptIsPayToWitnessScriptHash(rawValue)
    }

    /// Determines whether this is a pay-to-witness-public-key-hash (P2WPKH) script.
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: true if this is a pay-to-witness-public-key-hash (P2WPKH) script, false otherwise
    public var isPayToWitnessPublicKeyHash: Bool {
        return TWBitcoinScriptIsPayToWitnessPublicKeyHash(rawValue)
    }

    /// Determines whether this is a witness program script.
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: true if this is a witness program script, false otherwise
    public var isWitnessProgram: Bool {
        return TWBitcoinScriptIsWitnessProgram(rawValue)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = TWBitcoinScriptCreate()
    }

    public init(data: Data) {
        let dataData = TWDataCreateWithNSData(data)
        defer {
            TWDataDelete(dataData)
        }
        rawValue = TWBitcoinScriptCreateWithData(dataData)
    }

    public init(script: BitcoinScript) {
        rawValue = TWBitcoinScriptCreateCopy(script.rawValue)
    }

    deinit {
        TWBitcoinScriptDelete(rawValue)
    }

    /// Matches the script to a pay-to-public-key (P2PK) script.
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: The public key.
    public func matchPayToPubkey() -> Data? {
        guard let result = TWBitcoinScriptMatchPayToPubkey(rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Matches the script to a pay-to-public-key-hash (P2PKH).
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: the key hash.
    public func matchPayToPubkeyHash() -> Data? {
        guard let result = TWBitcoinScriptMatchPayToPubkeyHash(rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Matches the script to a pay-to-script-hash (P2SH).
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: the script hash.
    public func matchPayToScriptHash() -> Data? {
        guard let result = TWBitcoinScriptMatchPayToScriptHash(rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Matches the script to a pay-to-witness-public-key-hash (P2WPKH).
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: the key hash.
    public func matchPayToWitnessPublicKeyHash() -> Data? {
        guard let result = TWBitcoinScriptMatchPayToWitnessPublicKeyHash(rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Matches the script to a pay-to-witness-script-hash (P2WSH).
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: the script hash, a SHA256 of the witness script..
    public func matchPayToWitnessScriptHash() -> Data? {
        guard let result = TWBitcoinScriptMatchPayToWitnessScriptHash(rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Encodes the script.
    ///
    /// - Parameter script: Non-null pointer to a script
    /// - Returns: The encoded script
    public func encode() -> Data {
        return TWDataNSData(TWBitcoinScriptEncode(rawValue))
    }

}

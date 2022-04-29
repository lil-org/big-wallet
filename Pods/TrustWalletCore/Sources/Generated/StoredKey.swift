// Copyright © 2017-2020 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

public final class StoredKey {

    public static func load(path: String) -> StoredKey? {
        let pathString = TWStringCreateWithNSString(path)
        defer {
            TWStringDelete(pathString)
        }
        guard let value = TWStoredKeyLoad(pathString) else {
            return nil
        }
        return StoredKey(rawValue: value)
    }

    public static func importPrivateKey(privateKey: Data, name: String, password: Data, coin: CoinType) -> StoredKey? {
        let privateKeyData = TWDataCreateWithNSData(privateKey)
        defer {
            TWDataDelete(privateKeyData)
        }
        let nameString = TWStringCreateWithNSString(name)
        defer {
            TWStringDelete(nameString)
        }
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        guard let value = TWStoredKeyImportPrivateKey(privateKeyData, nameString, passwordData, TWCoinType(rawValue: coin.rawValue)) else {
            return nil
        }
        return StoredKey(rawValue: value)
    }

    public static func importHDWallet(mnemonic: String, name: String, password: Data, coin: CoinType) -> StoredKey? {
        let mnemonicString = TWStringCreateWithNSString(mnemonic)
        defer {
            TWStringDelete(mnemonicString)
        }
        let nameString = TWStringCreateWithNSString(name)
        defer {
            TWStringDelete(nameString)
        }
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        guard let value = TWStoredKeyImportHDWallet(mnemonicString, nameString, passwordData, TWCoinType(rawValue: coin.rawValue)) else {
            return nil
        }
        return StoredKey(rawValue: value)
    }

    public static func importJSON(json: Data) -> StoredKey? {
        let jsonData = TWDataCreateWithNSData(json)
        defer {
            TWDataDelete(jsonData)
        }
        guard let value = TWStoredKeyImportJSON(jsonData) else {
            return nil
        }
        return StoredKey(rawValue: value)
    }

    public var identifier: String? {
        guard let result = TWStoredKeyIdentifier(rawValue) else {
            return nil
        }
        return TWStringNSString(result)
    }

    public var name: String {
        return TWStringNSString(TWStoredKeyName(rawValue))
    }

    public var isMnemonic: Bool {
        return TWStoredKeyIsMnemonic(rawValue)
    }

    public var accountCount: Int {
        return TWStoredKeyAccountCount(rawValue)
    }

    public var encryptionParameters: String? {
        guard let result = TWStoredKeyEncryptionParameters(rawValue) else {
            return nil
        }
        return TWStringNSString(result)
    }

    let rawValue: OpaquePointer

    init(rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    public init(name: String, password: Data, encryptionLevel: StoredKeyEncryptionLevel) {
        let nameString = TWStringCreateWithNSString(name)
        defer {
            TWStringDelete(nameString)
        }
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        rawValue = TWStoredKeyCreateLevel(nameString, passwordData, TWStoredKeyEncryptionLevel(rawValue: encryptionLevel.rawValue))
    }

    public init(name: String, password: Data) {
        let nameString = TWStringCreateWithNSString(name)
        defer {
            TWStringDelete(nameString)
        }
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        rawValue = TWStoredKeyCreate(nameString, passwordData)
    }

    deinit {
        TWStoredKeyDelete(rawValue)
    }

    public func account(index: Int) -> Account? {
        guard let value = TWStoredKeyAccount(rawValue, index) else {
            return nil
        }
        return Account(rawValue: value)
    }

    public func accountForCoin(coin: CoinType, wallet: HDWallet?) -> Account? {
        guard let value = TWStoredKeyAccountForCoin(rawValue, TWCoinType(rawValue: coin.rawValue), wallet?.rawValue) else {
            return nil
        }
        return Account(rawValue: value)
    }

    public func removeAccountForCoin(coin: CoinType) -> Void {
        return TWStoredKeyRemoveAccountForCoin(rawValue, TWCoinType(rawValue: coin.rawValue))
    }

    public func addAccount(address: String, coin: CoinType, derivationPath: String, extetndedPublicKey: String) -> Void {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        let extetndedPublicKeyString = TWStringCreateWithNSString(extetndedPublicKey)
        defer {
            TWStringDelete(extetndedPublicKeyString)
        }
        return TWStoredKeyAddAccount(rawValue, addressString, TWCoinType(rawValue: coin.rawValue), derivationPathString, extetndedPublicKeyString)
    }

    public func store(path: String) -> Bool {
        let pathString = TWStringCreateWithNSString(path)
        defer {
            TWStringDelete(pathString)
        }
        return TWStoredKeyStore(rawValue, pathString)
    }

    public func decryptPrivateKey(password: Data) -> Data? {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        guard let result = TWStoredKeyDecryptPrivateKey(rawValue, passwordData) else {
            return nil
        }
        return TWDataNSData(result)
    }

    public func decryptMnemonic(password: Data) -> String? {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        guard let result = TWStoredKeyDecryptMnemonic(rawValue, passwordData) else {
            return nil
        }
        return TWStringNSString(result)
    }

    public func privateKey(coin: CoinType, password: Data) -> PrivateKey? {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        guard let value = TWStoredKeyPrivateKey(rawValue, TWCoinType(rawValue: coin.rawValue), passwordData) else {
            return nil
        }
        return PrivateKey(rawValue: value)
    }

    public func wallet(password: Data) -> HDWallet? {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        guard let value = TWStoredKeyWallet(rawValue, passwordData) else {
            return nil
        }
        return HDWallet(rawValue: value)
    }

    public func exportJSON() -> Data? {
        guard let result = TWStoredKeyExportJSON(rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    public func fixAddresses(password: Data) -> Bool {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        return TWStoredKeyFixAddresses(rawValue, passwordData)
    }

}

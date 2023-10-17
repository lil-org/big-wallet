// Copyright © 2017-2023 Trust Wallet.
//
// This file is part of Trust. The full Trust copyright notice, including
// terms governing use, modification, and redistribution, is contained in the
// file LICENSE at the root of the source code distribution tree.
//
// This is a GENERATED FILE, changes made here WILL BE LOST.
//

import Foundation

/// Represents a key stored as an encrypted file.
public final class StoredKey {

    /// Loads a key from a file.
    ///
    /// - Parameter path: filepath to the key as a non-null string
    /// - Note: Returned object needs to be deleted with \TWStoredKeyDelete
    /// - Returns: Nullptr if the key can't be load, the stored key otherwise
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

    /// Imports a private key.
    ///
    /// - Parameter privateKey: Non-null Block of data private key
    /// - Parameter name: The name of the stored key to import as a non-null string
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Parameter coin: the coin type
    /// - Note: Returned object needs to be deleted with \TWStoredKeyDelete
    /// - Returns: Nullptr if the key can't be imported, the stored key otherwise
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

    /// Imports a private key.
    ///
    /// - Parameter privateKey: Non-null Block of data private key
    /// - Parameter name: The name of the stored key to import as a non-null string
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Parameter coin: the coin type
    /// - Parameter encryption: cipher encryption mode
    /// - Note: Returned object needs to be deleted with \TWStoredKeyDelete
    /// - Returns: Nullptr if the key can't be imported, the stored key otherwise
    public static func importPrivateKeyWithEncryption(privateKey: Data, name: String, password: Data, coin: CoinType, encryption: StoredKeyEncryption) -> StoredKey? {
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
        guard let value = TWStoredKeyImportPrivateKeyWithEncryption(privateKeyData, nameString, passwordData, TWCoinType(rawValue: coin.rawValue), TWStoredKeyEncryption(rawValue: encryption.rawValue)) else {
            return nil
        }
        return StoredKey(rawValue: value)
    }

    /// Imports an HD wallet.
    ///
    /// - Parameter mnemonic: Non-null bip39 mnemonic
    /// - Parameter name: The name of the stored key to import as a non-null string
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Parameter coin: the coin type
    /// - Note: Returned object needs to be deleted with \TWStoredKeyDelete
    /// - Returns: Nullptr if the key can't be imported, the stored key otherwise
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

    /// Imports an HD wallet.
    ///
    /// - Parameter mnemonic: Non-null bip39 mnemonic
    /// - Parameter name: The name of the stored key to import as a non-null string
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Parameter coin: the coin type
    /// - Parameter encryption: cipher encryption mode
    /// - Note: Returned object needs to be deleted with \TWStoredKeyDelete
    /// - Returns: Nullptr if the key can't be imported, the stored key otherwise
    public static func importHDWalletWithEncryption(mnemonic: String, name: String, password: Data, coin: CoinType, encryption: StoredKeyEncryption) -> StoredKey? {
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
        guard let value = TWStoredKeyImportHDWalletWithEncryption(mnemonicString, nameString, passwordData, TWCoinType(rawValue: coin.rawValue), TWStoredKeyEncryption(rawValue: encryption.rawValue)) else {
            return nil
        }
        return StoredKey(rawValue: value)
    }

    /// Imports a key from JSON.
    ///
    /// - Parameter json: Json stored key import format as a non-null block of data
    /// - Note: Returned object needs to be deleted with \TWStoredKeyDelete
    /// - Returns: Nullptr if the key can't be imported, the stored key otherwise
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

    /// Stored key unique identifier.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns: The stored key unique identifier if it's found, null pointer otherwise.
    public var identifier: String? {
        guard let result = TWStoredKeyIdentifier(rawValue) else {
            return nil
        }
        return TWStringNSString(result)
    }

    /// Stored key namer.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Note: Returned object needs to be deleted with \TWStringDelete
    /// - Returns: The stored key name as a non-null string pointer.
    public var name: String {
        return TWStringNSString(TWStoredKeyName(rawValue))
    }

    /// Whether this key is a mnemonic phrase for a HD wallet.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Returns: true if the given stored key is a mnemonic, false otherwise
    public var isMnemonic: Bool {
        return TWStoredKeyIsMnemonic(rawValue)
    }

    /// The number of accounts.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Returns: the number of accounts associated to the given stored key
    public var accountCount: Int {
        return TWStoredKeyAccountCount(rawValue)
    }

    /// Retrieve stored key encoding parameters, as JSON string.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Returns: Null pointer on failure, encoding parameter as a json string otherwise.
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

    public init(name: String, password: Data, encryptionLevel: StoredKeyEncryptionLevel, encryption: StoredKeyEncryption) {
        let nameString = TWStringCreateWithNSString(name)
        defer {
            TWStringDelete(nameString)
        }
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        rawValue = TWStoredKeyCreateLevelAndEncryption(nameString, passwordData, TWStoredKeyEncryptionLevel(rawValue: encryptionLevel.rawValue), TWStoredKeyEncryption(rawValue: encryption.rawValue))
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

    public init(name: String, password: Data, encryption: StoredKeyEncryption) {
        let nameString = TWStringCreateWithNSString(name)
        defer {
            TWStringDelete(nameString)
        }
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        rawValue = TWStoredKeyCreateEncryption(nameString, passwordData, TWStoredKeyEncryption(rawValue: encryption.rawValue))
    }

    deinit {
        TWStoredKeyDelete(rawValue)
    }

    /// Returns the account at a given index.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter index: the account index to be retrieved
    /// - Note: Returned object needs to be deleted with \TWAccountDelete
    /// - Returns: Null pointer if the associated account is not found, pointer to the account otherwise.
    public func account(index: Int) -> Account? {
        guard let value = TWStoredKeyAccount(rawValue, index) else {
            return nil
        }
        return Account(rawValue: value)
    }

    /// Returns the account for a specific coin, creating it if necessary.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter coin: The coin type
    /// - Parameter wallet: The associated HD wallet, can be null.
    /// - Note: Returned object needs to be deleted with \TWAccountDelete
    /// - Returns: Null pointer if the associated account is not found/not created, pointer to the account otherwise.
    public func accountForCoin(coin: CoinType, wallet: HDWallet?) -> Account? {
        guard let value = TWStoredKeyAccountForCoin(rawValue, TWCoinType(rawValue: coin.rawValue), wallet?.rawValue) else {
            return nil
        }
        return Account(rawValue: value)
    }

    /// Returns the account for a specific coin + derivation, creating it if necessary.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter coin: The coin type
    /// - Parameter derivation: The derivation for the given coin
    /// - Parameter wallet: the associated HD wallet, can be null.
    /// - Note: Returned object needs to be deleted with \TWAccountDelete
    /// - Returns: Null pointer if the associated account is not found/not created, pointer to the account otherwise.
    public func accountForCoinDerivation(coin: CoinType, derivation: Derivation, wallet: HDWallet?) -> Account? {
        guard let value = TWStoredKeyAccountForCoinDerivation(rawValue, TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue), wallet?.rawValue) else {
            return nil
        }
        return Account(rawValue: value)
    }

    /// Adds a new account, using given derivation (usually TWDerivationDefault)
    /// and derivation path (usually matches path from derivation, but custom possible).
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter address: Non-null pointer to the address of the coin for this account
    /// - Parameter coin: coin type
    /// - Parameter derivation: derivation of the given coin type
    /// - Parameter derivationPath: HD bip44 derivation path of the given coin
    /// - Parameter publicKey: Non-null public key of the given coin/address
    /// - Parameter extendedPublicKey: Non-null extended public key of the given coin/address
    public func addAccountDerivation(address: String, coin: CoinType, derivation: Derivation, derivationPath: String, publicKey: String, extendedPublicKey: String) -> Void {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        let publicKeyString = TWStringCreateWithNSString(publicKey)
        defer {
            TWStringDelete(publicKeyString)
        }
        let extendedPublicKeyString = TWStringCreateWithNSString(extendedPublicKey)
        defer {
            TWStringDelete(extendedPublicKeyString)
        }
        return TWStoredKeyAddAccountDerivation(rawValue, addressString, TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue), derivationPathString, publicKeyString, extendedPublicKeyString)
    }

    /// Adds a new account, using given derivation path.
    ///
    /// \deprecated Use TWStoredKeyAddAccountDerivation (with TWDerivationDefault) instead.
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter address: Non-null pointer to the address of the coin for this account
    /// - Parameter coin: coin type
    /// - Parameter derivationPath: HD bip44 derivation path of the given coin
    /// - Parameter publicKey: Non-null public key of the given coin/address
    /// - Parameter extendedPublicKey: Non-null extended public key of the given coin/address
    public func addAccount(address: String, coin: CoinType, derivationPath: String, publicKey: String, extendedPublicKey: String) -> Void {
        let addressString = TWStringCreateWithNSString(address)
        defer {
            TWStringDelete(addressString)
        }
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        let publicKeyString = TWStringCreateWithNSString(publicKey)
        defer {
            TWStringDelete(publicKeyString)
        }
        let extendedPublicKeyString = TWStringCreateWithNSString(extendedPublicKey)
        defer {
            TWStringDelete(extendedPublicKeyString)
        }
        return TWStoredKeyAddAccount(rawValue, addressString, TWCoinType(rawValue: coin.rawValue), derivationPathString, publicKeyString, extendedPublicKeyString)
    }

    /// Remove the account for a specific coin
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter coin: Account coin type to be removed
    public func removeAccountForCoin(coin: CoinType) -> Void {
        return TWStoredKeyRemoveAccountForCoin(rawValue, TWCoinType(rawValue: coin.rawValue))
    }

    /// Remove the account for a specific coin with the given derivation.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter coin: Account coin type to be removed
    /// - Parameter derivation: The derivation of the given coin type
    public func removeAccountForCoinDerivation(coin: CoinType, derivation: Derivation) -> Void {
        return TWStoredKeyRemoveAccountForCoinDerivation(rawValue, TWCoinType(rawValue: coin.rawValue), TWDerivation(rawValue: derivation.rawValue))
    }

    /// Remove the account for a specific coin with the given derivation path.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter coin: Account coin type to be removed
    /// - Parameter derivationPath: The derivation path (bip44) of the given coin type
    public func removeAccountForCoinDerivationPath(coin: CoinType, derivationPath: String) -> Void {
        let derivationPathString = TWStringCreateWithNSString(derivationPath)
        defer {
            TWStringDelete(derivationPathString)
        }
        return TWStoredKeyRemoveAccountForCoinDerivationPath(rawValue, TWCoinType(rawValue: coin.rawValue), derivationPathString)
    }

    /// Saves the key to a file.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter path: Non-null string filepath where the key will be saved
    /// - Returns: true if the key was successfully stored in the given filepath file, false otherwise
    public func store(path: String) -> Bool {
        let pathString = TWStringCreateWithNSString(path)
        defer {
            TWStringDelete(pathString)
        }
        return TWStoredKeyStore(rawValue, pathString)
    }

    /// Decrypts the private key.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Returns: Decrypted private key as a block of data if success, null pointer otherwise
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

    /// Decrypts the mnemonic phrase.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Returns: Bip39 decrypted mnemonic if success, null pointer otherwise
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

    /// Returns the private key for a specific coin.  Returned object needs to be deleted.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter coin: Account coin type to be queried
    /// - Note: Returned object needs to be deleted with \TWPrivateKeyDelete
    /// - Returns: Null pointer on failure, pointer to the private key otherwise
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

    /// Decrypts and returns the HD Wallet for mnemonic phrase keys.  Returned object needs to be deleted.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Note: Returned object needs to be deleted with \TWHDWalletDelete
    /// - Returns: Null pointer on failure, pointer to the HDWallet otherwise
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

    /// Exports the key as JSON
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Returns: Null pointer on failure, pointer to a block of data containing the json otherwise
    public func exportJSON() -> Data? {
        guard let result = TWStoredKeyExportJSON(rawValue) else {
            return nil
        }
        return TWDataNSData(result)
    }

    /// Fills in empty and invalid addresses.
    /// This method needs the encryption password to re-derive addresses from private keys.
    ///
    /// - Parameter key: Non-null pointer to a stored key
    /// - Parameter password: Non-null block of data, password of the stored key
    /// - Returns: `false` if the password is incorrect, true otherwise.
    public func fixAddresses(password: Data) -> Bool {
        let passwordData = TWDataCreateWithNSData(password)
        defer {
            TWDataDelete(passwordData)
        }
        return TWStoredKeyFixAddresses(rawValue, passwordData)
    }

}

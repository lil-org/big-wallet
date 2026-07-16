// ∅ 2026 lil org

import Foundation

enum WalletKeyStoreError: Swift.Error {
    case invalidPassword
    case invalidKey
    case invalidMnemonic
    case accountNotFound
}

enum WalletCoin: UInt32, Hashable {
    case ethereum = 60
    case solana = 501

    var slip44Id: UInt32 { rawValue }
}

enum WalletDerivation: Hashable {
    case `default`
    case solanaSolana
    case custom
}

struct WalletAccount: Hashable {
    let address: String
    let coin: WalletCoin
    let derivation: WalletDerivation
    let derivationPath: String
    let publicKey: String
    let extendedPublicKey: String

    init(address: String,
         coin: WalletCoin,
         derivation: WalletDerivation,
         derivationPath: String,
         publicKey: String,
         extendedPublicKey: String) {
        self.address = address
        self.coin = coin
        self.derivation = derivation
        self.derivationPath = derivationPath
        self.publicKey = publicKey
        self.extendedPublicKey = extendedPublicKey
    }
}

struct WalletPrivateKey {
    private let keyData: Data
    fileprivate static let invalid = WalletPrivateKey(unchecked: Data())

    init?(data: Data) {
        guard data.count == 32, data.contains(where: { $0 != 0 }) else { return nil }
        keyData = data
    }

    fileprivate init(unchecked data: Data) {
        keyData = data
    }

    func withData<Result>(_ body: (Data) throws -> Result) rethrows -> Result {
        var privateKeyData = keyData
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        return try body(privateKeyData)
    }

    func publicKeyData(coin: WalletCoin) -> Data {
        switch coin {
        case .ethereum:
            return Secp256k1.publicKey(privateKey: keyData, compressed: false) ?? Data()
        case .solana:
            return Ed25519.publicKey(seed: keyData) ?? Data()
        }
    }

    func publicKeyDescription(coin: WalletCoin) -> String {
        return WalletCrypto.hexString(publicKeyData(coin: coin))
    }

    func sign(digest: Data, coin: WalletCoin) -> Data? {
        switch coin {
        case .ethereum:
            guard WalletCrypto.isSupportedEthereumSigningDigest(digest) else { return nil }
            return Secp256k1.sign(digest: digest, privateKey: keyData)
        case .solana:
            return Ed25519.sign(message: digest, seed: keyData)
        }
    }

    func sign<Digests: Sequence>(digests: Digests, coin: WalletCoin) -> [Data]? where Digests.Element == Data {
        switch coin {
        case .ethereum:
            guard WalletCrypto.isValidPrivateKeyData(keyData, coin: coin) else { return nil }
            var signatures = [Data]()
            signatures.reserveCapacity(digests.underestimatedCount)
            for digest in digests {
                guard let signature = sign(digest: digest, coin: coin) else { return nil }
                signatures.append(signature)
            }
            return signatures
        case .solana:
            return Ed25519.sign(messages: digests, seed: keyData)
        }
    }
}

struct WalletHDWallet {
    private let seed: Data

    init?(mnemonic: String, passphrase: String) {
        guard WalletCrypto.isValidMnemonic(mnemonic) else { return nil }
        self.seed = BIP39.seed(mnemonic: mnemonic, passphrase: passphrase)
    }

    func getKey(coin: WalletCoin, derivationPath: String) -> WalletPrivateKey {
        return privateKey(coin: coin, derivationPath: derivationPath) ?? .invalid
    }

    func privateKey(coin: WalletCoin, derivationPath: String) -> WalletPrivateKey? {
        switch coin {
        case .ethereum:
            guard let path = DerivationPath(derivationPath),
                  let node = BIP32.derivePrivateNode(seed: seed, path: path, includeParentFingerprint: false),
                  Secp256k1.isValidPrivateKey(node.privateKey) else { return nil }
            return WalletPrivateKey(unchecked: node.privateKey)
        case .solana:
            guard let path = DerivationPath(derivationPath),
                  let node = SLIP10Ed25519.derivePrivateNode(seed: seed, path: path, includeParentFingerprint: false) else { return nil }
            return WalletPrivateKey(unchecked: node.privateKey)
        }
    }

    func solanaPreviewAccounts(accountRange: Range<Int>) -> [WalletAccount]? {
        guard let prefixPath = DerivationPath(components: WalletCrypto.solanaBaseDerivationComponents()),
              let prefixNode = SLIP10Ed25519.derivePrivateKeyMaterial(seed: seed, path: prefixPath) else {
            return nil
        }

        var accounts = [WalletAccount]()
        accounts.reserveCapacity(accountRange.count)

        for accountIndex in accountRange {
            guard let accountValue = UInt32(exactly: accountIndex), accountValue < 0x80000000 else { return nil }
            let components = WalletCrypto.solanaSolanaDerivationComponents(account: accountValue)
            guard let accountNode = SLIP10Ed25519.deriveChildPrivateKeyMaterial(parent: prefixNode,
                                                                                component: components.account),
                  let addressNode = SLIP10Ed25519.deriveChildPrivateKeyMaterial(parent: accountNode,
                                                                                component: components.address) else {
                return nil
            }
            let privateKey = WalletPrivateKey(unchecked: addressNode.privateKey)
            guard let account = solanaPreviewAccount(accountIndex: accountIndex,
                                                     account: accountValue,
                                                     privateKey: privateKey) else { return nil }
            accounts.append(account)
        }

        return accounts
    }

    private func solanaPreviewAccount(accountIndex: Int, account: UInt32, privateKey: WalletPrivateKey) -> WalletAccount? {
        let coin = WalletCoin.solana
        let derivation = accountIndex == 0 ? WalletDerivation.solanaSolana : .custom
        let publicKeyData = privateKey.publicKeyData(coin: coin)
        return WalletCrypto.accountFromPublicKeyData(publicKeyData: publicKeyData,
                                                     coin: coin,
                                                     derivation: derivation,
                                                     derivationPath: WalletCrypto.solanaSolanaDerivationPath(account: account),
                                                     extendedPublicKey: solanaPreviewExtendedPublicKey(account: account))
    }

    private func solanaPreviewExtendedPublicKey(account: UInt32) -> String {
        guard account != 0 else {
            return extendedPublicKeyDerivation(coin: .solana, derivation: .solanaSolana)
        }

        return extendedPublicKeyAccount(coin: .solana, derivation: .solanaSolana, account: account)
    }

    func ethereumPreviewAccounts(accountRange: Range<Int>) -> [WalletAccount]? {
        let extendedPublicKey = extendedPublicKey(coin: .ethereum)
        return WalletCrypto.ethereumAccountsFromAccountExtendedPublicKey(extended: extendedPublicKey,
                                                                         derivation: .custom,
                                                                         account: 0,
                                                                         change: 0,
                                                                         addressRange: accountRange)
    }

    func extendedPublicKey(coin: WalletCoin) -> String {
        switch coin {
        case .ethereum:
            return extendedPublicKeyAccount(coin: coin, derivation: .default, account: 0)
        case .solana:
            guard let path = DerivationPath(WalletCrypto.solanaDefaultDerivationPath(account: 0)),
                  let node = SLIP10Ed25519.derivePrivateNode(seed: seed, path: path),
                  let publicKey = Ed25519.publicKey(seed: node.privateKey) else { return "" }
            return BIP32.serializeExtendedPublicKey(publicKey: Data([0x01]) + publicKey,
                                                    chainCode: node.chainCode,
                                                    depth: 3,
                                                    parentFingerprint: node.parentFingerprint,
                                                    childNumber: 0x80000000)
        }
    }

    func extendedPublicKeyDerivation(coin: WalletCoin, derivation: WalletDerivation) -> String {
        switch coin {
        case .ethereum:
            return extendedPublicKeyAccount(coin: coin, derivation: derivation, account: 0)
        case .solana:
            return ""
        }
    }

    func extendedPublicKeyAccount(coin: WalletCoin, derivation _: WalletDerivation, account: UInt32) -> String {
        guard coin == .ethereum, account < 0x80000000 else { return "" }
        guard let accountPath = DerivationPath("m/44'/60'/\(account)'"),
              let node = BIP32.derivePrivateNode(seed: seed, path: accountPath) else { return "" }
        return BIP32.serializeExtendedPublicKey(privateKey: node.privateKey,
                                                chainCode: node.chainCode,
                                                depth: 3,
                                                parentFingerprint: node.parentFingerprint,
                                                childNumber: 0x80000000 | account)
    }
}

struct WalletStoredKey {
    fileprivate let storage: StoredKeyStorage

    var name: String { storage.name }
    var isMnemonic: Bool { storage.type == .mnemonic }
    var accountCount: Int { storage.accounts.count }

    init?(name: String, password: Data) {
        let mnemonic = BIP39.generateMnemonic()
        guard let storage = StoredKeyStorage(type: .mnemonic,
                                             name: name,
                                             payload: Data(mnemonic.utf8),
                                             password: password) else { return nil }
        self.storage = storage
    }

    fileprivate init(storage: StoredKeyStorage) {
        self.storage = storage
    }

    static func importJSON(json: Data) -> WalletStoredKey? {
        return StoredKeyStorage.importJSON(json).map(WalletStoredKey.init(storage:))
    }

    static func importPrivateKey(privateKey: Data, name: String, password: Data, coin: WalletCoin) -> WalletStoredKey? {
        guard WalletCrypto.isValidPrivateKeyData(privateKey, coin: coin),
              let walletPrivateKey = WalletPrivateKey(data: privateKey),
              let storage = StoredKeyStorage(type: .privateKey, name: name, payload: privateKey, password: password)
        else { return nil }
        guard storage.addDefaultAccount(coin: coin, privateKey: walletPrivateKey) else { return nil }
        return WalletStoredKey(storage: storage)
    }

    static func importHDWallet(mnemonic: String, name: String, password: Data, coin: WalletCoin) -> WalletStoredKey? {
        guard let wallet = WalletHDWallet(mnemonic: mnemonic, passphrase: ""),
              let storage = StoredKeyStorage(type: .mnemonic, name: name, payload: Data(mnemonic.utf8), password: password)
        else { return nil }
        _ = storage.accountForCoin(coin: coin, wallet: wallet)
        return WalletStoredKey(storage: storage)
    }

    func wallet(password: Data) -> WalletHDWallet? {
        guard storage.type == .mnemonic,
              let mnemonic = decryptMnemonic(password: password) else { return nil }
        return WalletHDWallet(mnemonic: mnemonic, passphrase: "")
    }

    func account(index: Int) -> WalletAccount? {
        guard storage.accounts.indices.contains(index) else { return nil }
        return storage.accounts[index].walletAccount
    }

    func accountForCoin(coin: WalletCoin, wallet: WalletHDWallet?) -> WalletAccount? {
        return storage.accountForCoin(coin: coin, wallet: wallet)
    }

    func accountForCoinDerivation(coin: WalletCoin, derivation: WalletDerivation, wallet: WalletHDWallet?) -> WalletAccount? {
        return storage.accountForCoinDerivation(coin: coin, derivation: derivation, wallet: wallet)
    }

    func privateKey(coin: WalletCoin, password: Data) -> WalletPrivateKey? {
        switch storage.type {
        case .privateKey:
            guard let data = decryptPrivateKey(password: password),
                  WalletCrypto.isValidPrivateKeyData(data, coin: coin),
                  let privateKey = WalletPrivateKey(data: data),
                  storage.hasAccount(coin: coin, matching: privateKey) else { return nil }
            return privateKey
        case .mnemonic:
            guard let wallet = wallet(password: password) else { return nil }
            // WalletCore resolves TWDerivationDefault first, not the app's Solana preference,
            // then uses that record's stored path.
            let account = storage.accountForCoinDerivation(coin: coin, derivation: .default, wallet: wallet)
            return account.flatMap { wallet.privateKey(coin: coin, derivationPath: $0.derivationPath) }
        }
    }

    func decryptPrivateKey(password: Data) -> Data? {
        return storage.decrypt(password: password)
    }

    func decryptMnemonic(password: Data) -> String? {
        guard storage.type == .mnemonic,
              let data = storage.decrypt(password: password) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func exportJSON() -> Data? {
        return storage.exportJSON()
    }

    func removeAccountForCoinDerivationPath(coin: WalletCoin, derivationPath: String) {
        storage.accounts.removeAll { $0.coinRawValue == coin.rawValue && $0.derivationPath == derivationPath }
    }

    func removeAccountForCoin(coin: WalletCoin) {
        storage.accounts.removeAll { $0.coinRawValue == coin.rawValue }
    }

    func addAccountDerivation(address: String,
                              coin: WalletCoin,
                              derivation: WalletDerivation,
                              derivationPath: String,
                              publicKey: String,
                              extendedPublicKey: String) {
        storage.addAccount(WalletAccount(address: address,
                                         coin: coin,
                                         derivation: derivation,
                                         derivationPath: derivationPath,
                                         publicKey: publicKey,
                                         extendedPublicKey: extendedPublicKey))
    }
}

enum WalletCrypto {
    struct SolanaDerivationComponents {
        let base: [DerivationPath.Component]
        let account: DerivationPath.Component
        let address: DerivationPath.Component

        var defaultPath: [DerivationPath.Component] {
            return base + [account]
        }

        var solanaPath: [DerivationPath.Component] {
            return defaultPath + [address]
        }
    }

    static func isValidMnemonic(_ mnemonic: String) -> Bool {
        return BIP39.isValidMnemonic(mnemonic)
    }

    static func isValidMnemonic(mnemonic: String) -> Bool {
        return isValidMnemonic(mnemonic)
    }

    static func isValidPrivateKeyData(_ data: Data, coin: WalletCoin) -> Bool {
        switch coin {
        case .ethereum:
            return Secp256k1.isValidPrivateKey(data)
        case .solana:
            return data.count == 32 && data.contains(where: { $0 != 0 })
        }
    }

    static func isValidPrivateKeyData(data: Data, coin: WalletCoin) -> Bool {
        return isValidPrivateKeyData(data, coin: coin)
    }

    static func base58Decode(_ string: String) -> Data? {
        return Base58.decode(string)
    }

    static func base58Decode(string: String) -> Data? {
        return base58Decode(string)
    }

    static func base58Encode(_ data: Data) -> String {
        return Base58.encode(data)
    }

    static func base58Encode(data: Data) -> String {
        return base58Encode(data)
    }

    static func hexData(_ string: String) -> Data? {
        let hexString = string.cleanHex
        return cleanHexData(hexString)
    }

    static func hexData(string: String) -> Data? {
        return hexData(string)
    }

    static func isValidNonEmptyHexData(_ string: String) -> Bool {
        let hexString = string.cleanHex
        return !hexString.isEmpty && isValidCleanHexData(hexString)
    }

    private static func cleanHexData(_ hexString: String) -> Data? {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(hexString.count / 2)

        var highNibble: UInt8?
        for byte in hexString.utf8 {
            guard let value = hexValue(byte) else { return nil }
            if let high = highNibble {
                data.append((high << 4) | value)
                highNibble = nil
            } else {
                highNibble = value
            }
        }
        return data
    }

    private static func isValidCleanHexData(_ hexString: String) -> Bool {
        guard hexString.count.isMultiple(of: 2) else { return false }
        return hexString.utf8.allSatisfy { hexValue($0) != nil }
    }

    static func hexString(_ data: Data) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(hexAlphabet[Int(byte >> 4)])
            bytes.append(hexAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    static func hexString(data: Data) -> String {
        return hexString(data)
    }

    static func keccak256(data: Data) -> Data {
        return Keccak256.hash(data)
    }

    static func keccak256(parts: [Data]) -> Data {
        return Keccak256.hash(parts: parts)
    }

    static func isSupportedEthereumSigningDigest(_ digest: Data) -> Bool {
        return digest.count == 32 && digest.contains { $0 != 0 }
    }

    static func solanaDefaultDerivationPath(account: UInt32) -> String {
        return derivationPath(solanaSolanaDerivationComponents(account: account).defaultPath)
    }

    static func solanaSolanaDerivationPath(account: UInt32) -> String {
        return derivationPath(solanaSolanaDerivationComponents(account: account).solanaPath)
    }

    static func solanaBaseDerivationComponents() -> [DerivationPath.Component] {
        return [
            DerivationPath.Component(value: 44, hardened: true),
            DerivationPath.Component(value: WalletCoin.solana.slip44Id, hardened: true),
        ]
    }

    static func solanaSolanaDerivationComponents(account: UInt32) -> SolanaDerivationComponents {
        return SolanaDerivationComponents(base: solanaBaseDerivationComponents(),
                                          account: DerivationPath.Component(value: account, hardened: true),
                                          address: DerivationPath.Component(value: 0, hardened: true))
    }

    private static func derivationPath(_ components: [DerivationPath.Component]) -> String {
        return "m/" + components.map { component in
            let suffix = component.hardened ? "'" : ""
            return "\(component.value)\(suffix)"
        }.joined(separator: "/")
    }

    static func publicKeyDescriptionFromExtended(extended: String, coin: WalletCoin, derivationPath: String) -> String? {
        guard coin == .ethereum,
              let parsedExtendedPublicKey = BIP32.ExtendedPublicKey(extended),
              let publicKeyData = publicKeyDataFromExtended(parsedExtendedPublicKey: parsedExtendedPublicKey,
                                                            coin: coin,
                                                            derivationPath: derivationPath) else { return nil }
        return hexString(publicKeyData)
    }

    static func publicKeyDataFromExtended(parsedExtendedPublicKey: BIP32.ExtendedPublicKey,
                                          coin: WalletCoin,
                                          derivationPath: String) -> Data? {
        guard coin == .ethereum,
              let path = DerivationPath(derivationPath),
              let publicKey = parsedExtendedPublicKey.uncompressedPublicKey(path: path) else { return nil }
        return publicKey
    }

    static func accountFromExtendedPublicKey(extended: String,
                                             coin: WalletCoin,
                                             derivation: WalletDerivation,
                                             derivationPath: String) -> WalletAccount? {
        guard let parsedExtendedPublicKey = BIP32.ExtendedPublicKey(extended),
              let publicKeyData = publicKeyDataFromExtended(parsedExtendedPublicKey: parsedExtendedPublicKey,
                                                            coin: coin,
                                                            derivationPath: derivationPath) else { return nil }
        return accountFromPublicKeyData(publicKeyData: publicKeyData,
                                        coin: coin,
                                        derivation: derivation,
                                        derivationPath: derivationPath,
                                        extendedPublicKey: extended)
    }

    static func ethereumAccountsFromAccountExtendedPublicKey(extended: String,
                                                             derivation: WalletDerivation,
                                                             account: UInt32,
                                                             change: UInt32,
                                                             addressRange: Range<Int>) -> [WalletAccount]? {
        guard let parsedExtendedPublicKey = BIP32.ExtendedPublicKey(extended),
              let changeNode = parsedExtendedPublicKey.publicNode(change: change) else { return nil }

        var accounts = [WalletAccount]()
        accounts.reserveCapacity(addressRange.count)

        for addressIndex in addressRange {
            guard let addressIndexValue = UInt32(exactly: addressIndex),
                  let publicKeyData = changeNode.uncompressedPublicKey(addressIndex: addressIndexValue) else { return nil }
            let derivationPath = bip44DerivationPath(coin: .ethereum,
                                                     account: account,
                                                     change: change,
                                                     address: addressIndexValue)
            guard let walletAccount = accountFromPublicKeyData(publicKeyData: publicKeyData,
                                                               coin: .ethereum,
                                                               derivation: derivation,
                                                               derivationPath: derivationPath,
                                                               extendedPublicKey: extended) else { return nil }
            accounts.append(walletAccount)
        }

        return accounts
    }

    static func accountFromPublicKeyData(publicKeyData: Data,
                                         coin: WalletCoin,
                                         derivation: WalletDerivation,
                                         derivationPath: String,
                                         extendedPublicKey: String) -> WalletAccount? {
        let publicKey = hexString(publicKeyData)
        let address = addressFromPublicKeyData(publicKeyData, coin: coin)
        guard !address.isEmpty else { return nil }
        return WalletAccount(address: address,
                             coin: coin,
                             derivation: derivation,
                             derivationPath: derivationPath,
                             publicKey: publicKey,
                             extendedPublicKey: extendedPublicKey)
    }

    static func addressFromPublicKeyDescription(_ publicKeyDescription: String, coin: WalletCoin) -> String {
        guard let publicKeyData = hexData(publicKeyDescription) else { return "" }
        return addressFromPublicKeyData(publicKeyData, coin: coin)
    }

    static func addressFromPublicKeyData(_ publicKeyData: Data, coin: WalletCoin) -> String {
        switch coin {
        case .ethereum:
            guard Secp256k1.isValidPublicKey(publicKeyData) else { return "" }
            let data = Data(publicKeyData.dropFirst())
            let hash = keccak256(data: data)
            return EthereumCodec.checksumAddress(Data(hash.suffix(20)))
        case .solana:
            let rawPublicKey: Data
            if publicKeyData.count == 32 {
                rawPublicKey = publicKeyData
            } else if publicKeyData.count == 33, publicKeyData.first == 0x01 {
                rawPublicKey = Data(publicKeyData.dropFirst())
            } else {
                return ""
            }
            return Base58.encode(rawPublicKey)
        }
    }

    static func recoverEthereumAddress(signature: Data, messageHash: Data) -> String? {
        guard messageHash.count == 32,
              let publicKey = Secp256k1.recoverPublicKey(signature: signature, digest: messageHash) else { return nil }
        return addressFromPublicKeyData(publicKey, coin: .ethereum)
    }

    static func ethereumTypedDataDigest(messageJson: String) -> Data {
        return EIP712.digest(json: messageJson)
    }

    static func decodeEthereumCall(data: Data, abi: String) -> String? {
        return EthereumABI.decodeCall(data: data, abi: abi)
    }

    static func signEthereumTransaction(chainID: Data,
                                        nonce: Data,
                                        gasPrice: Data,
                                        gasLimit: Data,
                                        toAddress: String,
                                        privateKey: WalletPrivateKey,
                                        amount: Data,
                                        data: Data) -> Data? {
        return EthereumTransactionSigner.signLegacy(chainID: chainID,
                                                    nonce: nonce,
                                                    gasPrice: gasPrice,
                                                    gasLimit: gasLimit,
                                                    toAddress: toAddress,
                                                    privateKey: privateKey,
                                                    amount: amount,
                                                    data: data)
    }

    static func bip44DerivationPath(coin: WalletCoin, account: UInt32, change: UInt32, address: UInt32) -> String {
        return "m/44'/\(coin.slip44Id)'/\(account)'/\(change)/\(address)"
    }

    static func previewDerivationIndex(derivationPath: String, coin: WalletCoin) -> Int {
        guard let path = DerivationPath(derivationPath) else { return 0 }
        switch coin {
        case .solana:
            return Int(path.account)
        case .ethereum:
            return Int(path.address)
        }
    }

    fileprivate static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static let hexAlphabet = Array("0123456789abcdef".utf8)
}

#if DEBUG
struct WalletRawAccountForTesting: Equatable {
    let address: String
    let coinRawValue: UInt32
    let derivationRawValue: UInt32
    let derivationPath: String
    let publicKey: String
    let extendedPublicKey: String
}

extension WalletStoredKey {
    func addUnsupportedAccountForTesting(_ account: WalletRawAccountForTesting) {
        storage.accounts.append(WalletRawAccountRecord(address: account.address,
                                                       coinRawValue: account.coinRawValue,
                                                       derivationRawValue: account.derivationRawValue,
                                                       derivationPath: account.derivationPath,
                                                       publicKey: account.publicKey,
                                                       extendedPublicKey: account.extendedPublicKey))
    }

    func rawAccountForTesting(index: Int) -> WalletRawAccountForTesting? {
        guard storage.accounts.indices.contains(index) else { return nil }
        let account = storage.accounts[index]
        return WalletRawAccountForTesting(address: account.address,
                                          coinRawValue: account.coinRawValue,
                                          derivationRawValue: account.derivationRawValue,
                                          derivationPath: account.derivationPath,
                                          publicKey: account.publicKey,
                                          extendedPublicKey: account.extendedPublicKey)
    }
}
#endif

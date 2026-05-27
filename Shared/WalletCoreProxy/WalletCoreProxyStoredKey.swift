// ∅ 2026 lil org

import Foundation
import Security

extension WalletDerivation {
    var rawValue: UInt32 {
        switch self {
        case .default: return 0
        case .custom: return 1
        case .solanaSolana: return 6
        }
    }

    init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .default
        case 6: self = .solanaSolana
        default: self = .custom
        }
    }
}

struct WalletRawAccountRecord: Equatable {
    var address: String
    var coinRawValue: UInt32
    var derivationRawValue: UInt32
    var derivationPath: String
    var publicKey: String
    var extendedPublicKey: String

    var walletAccount: WalletAccount? {
        guard let coin = WalletCoin(rawValue: coinRawValue) else { return nil }
        return WalletAccount(address: address,
                             coin: coin,
                             derivation: WalletDerivation(rawValue: derivationRawValue),
                             derivationPath: derivationPath,
                             publicKey: publicKey,
                             extendedPublicKey: extendedPublicKey)
    }
}

extension WalletRawAccountRecord {
    init(account: WalletAccount) {
        self.init(address: account.address,
                  coinRawValue: account.coin.rawValue,
                  derivationRawValue: account.derivation.rawValue,
                  derivationPath: account.derivationPath,
                  publicKey: account.publicKey,
                  extendedPublicKey: account.extendedPublicKey)
    }
}

final class StoredKeyStorage {
    enum KeyType: String { case privateKey, mnemonic }
    private typealias AccountEntry = (index: Int, account: WalletAccount)

    var type: KeyType
    var name: String
    var id: String
    var encryptedPayload: EncryptedPayload
    var accounts: [WalletRawAccountRecord]

    init?(type: KeyType, name: String, payload: Data, password: Data) {
        guard let encryptedPayload = EncryptedPayload.encrypt(payload: payload, password: password) else { return nil }
        self.type = type
        self.name = name
        self.id = UUID().uuidString.lowercased()
        self.encryptedPayload = encryptedPayload
        self.accounts = []
    }

    init(type: KeyType, name: String, id: String, encryptedPayload: EncryptedPayload, accounts: [WalletRawAccountRecord]) {
        self.type = type
        self.name = name
        self.id = id
        self.encryptedPayload = encryptedPayload
        self.accounts = accounts
    }

    func decrypt(password: Data) -> Data? {
        return encryptedPayload.decrypt(password: password)
    }

    func accountForCoin(coin: WalletCoin, wallet: WalletHDWallet?) -> WalletAccount? {
        let existing = walletAccountEntries().filter { $0.account.coin == coin }
        if type == .mnemonic, let wallet {
            if let derivedAccount = derivedAccount(coin: coin, derivation: .default, wallet: wallet),
               let matchingEntry = existing.first(where: { Self.account($0.account, hasAddressOf: derivedAccount) }) {
                return filledAccount(matchingEntry.account, wallet: wallet)
            }
            // WalletCore falls back to stored default/first accounts after an address miss.
            // Derivation metadata in imported JSON is documented as unreliable, so do not
            // normalize or replace these records with the derived default account here.
            if let defaultEntry = existing.first(where: { $0.account.derivation == .default }) {
                return filledAccount(defaultEntry.account, wallet: wallet)
            }
            if let firstEntry = existing.first {
                return filledAccount(firstEntry.account, wallet: wallet)
            }
        }
        if let defaultEntry = existing.first(where: { $0.account.derivation == .default }) {
            return defaultEntry.account
        }
        if let firstEntry = existing.first {
            return firstEntry.account
        }
        guard type == .mnemonic, let wallet else { return nil }
        return createAccount(coin: coin, derivation: .default, wallet: wallet)
    }

    func accountForCoinDerivation(coin: WalletCoin, derivation: WalletDerivation, wallet: WalletHDWallet?) -> WalletAccount? {
        guard type == .mnemonic, derivation != .custom, let wallet else { return nil }
        let existing = walletAccountEntries().filter { $0.account.coin == coin }
        guard let derivedAccount = derivedAccount(coin: coin, derivation: derivation, wallet: wallet) else { return nil }
        // Match WalletCore: explicit derivation lookup derives an address, then finds the
        // stored account by coin/address. The returned record keeps its original metadata.
        if let matchingEntry = existing.first(where: { Self.account($0.account, hasAddressOf: derivedAccount) }) {
            return filledAccount(matchingEntry.account, wallet: wallet)
        }
        addAccount(derivedAccount)
        return derivedAccount
    }

    func addDefaultAccount(coin: WalletCoin, privateKey: WalletPrivateKey) -> Bool {
        guard let account = Self.account(coin: coin,
                                         derivation: .default,
                                         derivationPath: Self.defaultDerivationPath(coin: coin, derivation: .default),
                                         privateKey: privateKey) else { return false }
        addAccount(account)
        return true
    }

    func hasAccount(coin: WalletCoin, matching privateKey: WalletPrivateKey) -> Bool {
        let publicKeyData = privateKey.publicKeyData(coin: coin)
        let address = WalletCrypto.addressFromPublicKeyData(publicKeyData, coin: coin)
        guard !address.isEmpty else { return false }

        return accounts.compactMap(\.walletAccount).contains { account in
            guard account.coin == coin,
                  Self.address(account.address, matches: address, coin: coin) else { return false }
            guard !account.publicKey.isEmpty else { return true }
            return WalletCrypto.hexData(account.publicKey) == publicKeyData
        }
    }

    private func createAccount(coin: WalletCoin, derivation: WalletDerivation, wallet: WalletHDWallet) -> WalletAccount? {
        guard let account = derivedAccount(coin: coin, derivation: derivation, wallet: wallet) else { return nil }
        addAccount(account)
        return account
    }

    private func derivedAccount(coin: WalletCoin, derivation: WalletDerivation, wallet: WalletHDWallet) -> WalletAccount? {
        let path = Self.defaultDerivationPath(coin: coin, derivation: derivation)
        guard let privateKey = wallet.privateKey(coin: coin, derivationPath: path) else { return nil }
        return Self.account(coin: coin, derivation: derivation, derivationPath: path, privateKey: privateKey)
    }

    private static func account(coin: WalletCoin,
                                derivation: WalletDerivation,
                                derivationPath: String,
                                privateKey: WalletPrivateKey,
                                extendedPublicKey: String = "") -> WalletAccount? {
        let publicKeyData = privateKey.publicKeyData(coin: coin)
        return WalletCrypto.accountFromPublicKeyData(publicKeyData: publicKeyData,
                                                     coin: coin,
                                                     derivation: derivation,
                                                     derivationPath: derivationPath,
                                                     extendedPublicKey: extendedPublicKey)
    }

    func addAccount(_ account: WalletAccount) {
        accounts.append(WalletRawAccountRecord(account: account))
    }

    private func walletAccountEntries() -> [AccountEntry] {
        accounts.indices.compactMap { index in
            guard let account = accounts[index].walletAccount else { return nil }
            return (index: index, account: account)
        }
    }

    private func filledAccount(_ account: WalletAccount, wallet: WalletHDWallet?) -> WalletAccount {
        guard let wallet else {
            return account
        }

        let address: String
        if account.address.isEmpty,
           let derivedAccount = derivedAccount(coin: account.coin, derivation: account.derivation, wallet: wallet) {
            address = derivedAccount.address
        } else {
            address = account.address
        }

        let publicKey: String
        if account.publicKey.isEmpty,
           let privateKey = wallet.privateKey(coin: account.coin, derivationPath: account.derivationPath) {
            publicKey = WalletCrypto.hexString(privateKey.publicKeyData(coin: account.coin))
        } else {
            publicKey = account.publicKey
        }

        return WalletAccount(address: address,
                             coin: account.coin,
                             derivation: account.derivation,
                             derivationPath: account.derivationPath,
                             publicKey: publicKey,
                             extendedPublicKey: account.extendedPublicKey)
    }

    private static func account(_ lhs: WalletAccount, hasAddressOf rhs: WalletAccount) -> Bool {
        return lhs.coin == rhs.coin && address(lhs.address, matches: rhs.address, coin: lhs.coin)
    }

    static func defaultDerivationPath(coin: WalletCoin, derivation: WalletDerivation) -> String {
        switch coin {
        case .ethereum:
            return WalletCrypto.bip44DerivationPath(coin: .ethereum, account: 0, change: 0, address: 0)
        case .solana:
            switch derivation {
            case .solanaSolana:
                return WalletCrypto.solanaSolanaDerivationPath(account: 0)
            case .default, .custom:
                return WalletCrypto.solanaDefaultDerivationPath(account: 0)
            }
        }
    }

    static func importJSON(_ data: Data) -> StoredKeyStorage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let crypto = (object["crypto"] ?? object["Crypto"]) as? [String: Any],
              let payload = EncryptedPayload(json: crypto) else { return nil }
        let type = (object["type"] as? String).flatMap(KeyType.init(rawValue:)) ?? .privateKey
        let name = object["name"] as? String ?? ""
        let id = object["id"] as? String ?? UUID().uuidString.lowercased()
        let accounts = parseAccounts(object: object)
        return StoredKeyStorage(type: type, name: name, id: id, encryptedPayload: payload, accounts: accounts)
    }

    private static func parseAccounts(object: [String: Any]) -> [WalletRawAccountRecord] {
        if let active = object["activeAccounts"] as? [[String: Any]] {
            return active.compactMap { accountObject in
                guard let address = accountObject["address"] as? String,
                      let path = accountObject["derivationPath"] as? String else { return nil }
                let coinRaw = uint32Value(accountObject["coin"])
                    ?? DerivationPath(path)?.coin
                    ?? 0
                let derivationRaw = uint32Value(accountObject["derivation"]) ?? 0
                return WalletRawAccountRecord(address: address,
                                              coinRawValue: coinRaw,
                                              derivationRawValue: derivationRaw,
                                              derivationPath: path,
                                              publicKey: accountObject["publicKey"] as? String ?? "",
                                              extendedPublicKey: accountObject["extendedPublicKey"] as? String ?? "")
            }
        }

        guard let address = object["address"] as? String else { return [] }
        let coinRaw = uint32Value(object["coin"]) ?? WalletCoin.ethereum.rawValue
        let coin = WalletCoin(rawValue: coinRaw) ?? .ethereum
        return [WalletRawAccountRecord(address: address,
                                       coinRawValue: coinRaw,
                                       derivationRawValue: WalletDerivation.default.rawValue,
                                       derivationPath: defaultDerivationPath(coin: coin, derivation: .default),
                                       publicKey: "",
                                       extendedPublicKey: "")]
    }

    private static func uint32Value(_ value: Any?) -> UInt32? {
        if let value = value as? UInt32 { return value }
        if let value = value as? Int, value >= 0, value <= Int(UInt32.max) { return UInt32(value) }
        if let value = value as? NSNumber {
            let intValue = value.int64Value
            guard intValue >= 0, intValue <= Int64(UInt32.max) else { return nil }
            return UInt32(intValue)
        }
        return nil
    }

    private static func address(_ lhs: String, matches rhs: String, coin: WalletCoin) -> Bool {
        switch coin {
        case .ethereum:
            return EthereumCodec.parseAddress(lhs) == EthereumCodec.parseAddress(rhs)
        case .solana:
            return lhs == rhs
        }
    }

    func exportJSON() -> Data? {
        var object: [String: Any] = [
            "version": 3,
            "id": id,
            "name": name,
            "crypto": encryptedPayload.jsonObject(),
        ]
        if type == .mnemonic {
            object["type"] = KeyType.mnemonic.rawValue
        }
        if let first = accounts.first {
            object["address"] = first.address
            object["coin"] = Int(first.coinRawValue)
        }
        object["activeAccounts"] = accounts.map {
            [
                "address": $0.address,
                "coin": Int($0.coinRawValue),
                "derivation": Int($0.derivationRawValue),
                "derivationPath": $0.derivationPath,
                "publicKey": $0.publicKey,
                "extendedPublicKey": $0.extendedPublicKey,
            ] as [String: Any]
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

struct EncryptedPayload {
    private enum Name {
        static let scrypt = "scrypt"
        static let pbkdf2 = "pbkdf2"
        static let hmacSHA256 = "hmac-sha256"
    }
    private enum Cipher: String {
        case aes128CTR = "aes-128-ctr"
        case aes256CTR = "aes-256-ctr"

        var keyBytes: Int {
            switch self {
            case .aes128CTR: return 16
            case .aes256CTR: return 32
            }
        }
    }
    private enum ScryptDefaults {
        static let n = 1 << 14
        static let r = 8
        static let p = 4
        static let dkLen = 32
    }

    enum KDF {
        case scrypt(n: Int, r: Int, p: Int, dkLen: Int, salt: Data)
        case pbkdf2(c: Int, dkLen: Int, salt: Data)
    }

    private let cipher: Cipher
    let iv: Data
    let ciphertext: Data
    let mac: Data
    let kdf: KDF

    private init(cipher: Cipher, iv: Data, ciphertext: Data, mac: Data, kdf: KDF) {
        self.cipher = cipher
        self.iv = iv
        self.ciphertext = ciphertext
        self.mac = mac
        self.kdf = kdf
    }

    static func encrypt(payload: Data, password: Data) -> EncryptedPayload? {
        let salt = SecureRandom.data(count: 32)
        let iv = SecureRandom.data(count: 16)
        let kdf = KDF.scrypt(n: ScryptDefaults.n,
                             r: ScryptDefaults.r,
                             p: ScryptDefaults.p,
                             dkLen: ScryptDefaults.dkLen,
                             salt: salt)
        let derivedKey = Scrypt.deriveKey(password: password,
                                          salt: salt,
                                          n: ScryptDefaults.n,
                                          r: ScryptDefaults.r,
                                          p: ScryptDefaults.p,
                                          dkLen: ScryptDefaults.dkLen)
        guard derivedKey.count >= 32,
              let ciphertext = AESCTR.crypt(data: payload, key: Data(derivedKey.prefix(16)), iv: iv)
        else { return nil }
        let mac = WalletCrypto.keccak256(data: derivedKey.subdata(in: 16..<32) + ciphertext)
        return EncryptedPayload(cipher: .aes128CTR, iv: iv, ciphertext: ciphertext, mac: mac, kdf: kdf)
    }

    init?(json: [String: Any]) {
        guard let cipherName = json["cipher"] as? String,
              let cipher = Cipher(rawValue: cipherName),
              let cipherParams = json["cipherparams"] as? [String: Any],
              let ivHex = cipherParams["iv"] as? String,
              let iv = WalletCrypto.hexData(ivHex),
              let ciphertextHex = json["ciphertext"] as? String,
              let ciphertext = WalletCrypto.hexData(ciphertextHex),
              let macHex = json["mac"] as? String,
              let mac = WalletCrypto.hexData(macHex),
              let kdfName = json["kdf"] as? String,
              let kdfParams = json["kdfparams"] as? [String: Any] else { return nil }

        self.cipher = cipher
        self.iv = iv
        self.ciphertext = ciphertext
        self.mac = mac
        if kdfName == Name.scrypt,
           let n = kdfParams["n"] as? Int,
           let r = kdfParams["r"] as? Int,
           let p = kdfParams["p"] as? Int,
           let dkLen = kdfParams["dklen"] as? Int,
           let saltHex = kdfParams["salt"] as? String,
           let salt = WalletCrypto.hexData(saltHex),
           Scrypt.parametersAreValid(n: n, r: r, p: p, dkLen: dkLen) {
            self.kdf = .scrypt(n: n, r: r, p: p, dkLen: dkLen, salt: salt)
        } else if kdfName == Name.pbkdf2,
                  let c = kdfParams["c"] as? Int,
                  let dkLen = kdfParams["dklen"] as? Int,
                  let saltHex = kdfParams["salt"] as? String,
                  let salt = WalletCrypto.hexData(saltHex),
                  let prf = kdfParams["prf"] as? String,
                  prf == Name.hmacSHA256,
                  PBKDF2.parametersAreValid(rounds: c, keyLength: dkLen) {
            self.kdf = .pbkdf2(c: c, dkLen: dkLen, salt: salt)
        } else {
            return nil
        }
    }

    func decrypt(password: Data) -> Data? {
        let derivedKey: Data
        switch kdf {
        case let .scrypt(n, r, p, dkLen, salt):
            derivedKey = Scrypt.deriveKey(password: password, salt: salt, n: n, r: r, p: p, dkLen: dkLen)
        case let .pbkdf2(c, dkLen, salt):
            derivedKey = PBKDF2.sha256(password: password, salt: salt, rounds: c, keyLength: dkLen)
        }

        let keyBytes = cipher.keyBytes
        guard derivedKey.count >= max(32, keyBytes),
              WalletCrypto.keccak256(data: derivedKey.subdata(in: 16..<32) + ciphertext) == mac else { return nil }
        return AESCTR.crypt(data: ciphertext, key: Data(derivedKey.prefix(keyBytes)), iv: iv)
    }

    func jsonObject() -> [String: Any] {
        var kdfObject: [String: Any]
        let kdfName: String
        switch kdf {
        case let .scrypt(n, r, p, dkLen, salt):
            kdfName = Name.scrypt
            kdfObject = ["n": n, "r": r, "p": p, "dklen": dkLen, "salt": WalletCrypto.hexString(salt)]
        case let .pbkdf2(c, dkLen, salt):
            kdfName = Name.pbkdf2
            kdfObject = ["c": c, "dklen": dkLen, "prf": Name.hmacSHA256, "salt": WalletCrypto.hexString(salt)]
        }
        return [
            "cipher": cipher.rawValue,
            "cipherparams": ["iv": WalletCrypto.hexString(iv)],
            "ciphertext": WalletCrypto.hexString(ciphertext),
            "kdf": kdfName,
            "kdfparams": kdfObject,
            "mac": WalletCrypto.hexString(mac),
        ]
    }
}

enum SecureRandom {
    static func data(count: Int) -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "Secure random generation failed")
        return Data(bytes)
    }
}

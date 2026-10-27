import CryptoKit
import Foundation
import WalletDomain

enum UpgradeFailure: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self { case .invalid(let reason): reason }
    }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw UpgradeFailure.invalid(message) }
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func hexData(_ text: String) throws -> Data {
    try require(text.count.isMultiple(of: 2) && text.allSatisfy { "0123456789abcdef".contains($0) }, "Invalid fixture hex")
    var data = Data()
    var index = text.startIndex
    while index < text.endIndex {
        let end = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<end], radix: 16) else { throw UpgradeFailure.invalid("Invalid fixture hex") }
        data.append(byte)
        index = end
    }
    return data
}

func readRegularFile(_ url: URL, maximumBytes: Int = 16 * 1_024 * 1_024) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    try require(attributes[.type] as? FileAttributeType == .typeRegular, "Fixture path is not a regular file")
    try require(((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumBytes, "Fixture file is too large")
    let data = try Data(contentsOf: url)
    try require(data.count <= maximumBytes, "Fixture file is too large")
    return data
}

func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

struct Baseline: Codable, Equatable, Sendable {
    let commit: String
    let marketingVersion: String
    let buildVersion: String
    let platform: String

    static let shipped = Baseline(commit: "03b1eb841180081063c6a64e5afe58c76d7f3732",
        marketingVersion: "1.0.98", buildVersion: "147", platform: "macos")
}

struct FixtureExpectations: Decodable, Sendable {
    struct Signature: Decodable, Sendable {
        let signatureHex: String
        let publicKeyHex: String
    }

    struct Account: Decodable, Sendable {
        let coin: UInt32
        let derivation: UInt32
        let derivationPath: String
        let address: String
        let publicKey: String
        let extendedPublicKey: String
        let name: String?
        let privateKeyBackup: String
        let signing: Signature

        var walletCoin: WalletCoin {
            get throws {
                guard let value = WalletCoin(rawValue: coin) else { throw UpgradeFailure.invalid("Unsupported fixture coin") }
                return value
            }
        }
    }

    struct Wallet: Decodable, Sendable {
        let fixtureID: String
        let walletID: String
        let walletDataSHA256: String
        let isMnemonic: Bool
        let name: String?
        let mnemonicBackup: String?
        let accounts: [Account]
    }

    struct Network: Decodable, Sendable {
        let chainID: Int
        let chainIDHex: String
        let name: String
        let symbol: String
        let decimals: Int
        let rpcURL: String
        let rpcURLs: [String]
        let blockExplorerURLs: [String]
        let currencyName: String
    }

    let version: Int
    let fixtureID: String
    let baseline: Baseline
    let fixturePassword: String
    let ethereumDigestHex: String
    let solanaMessageHex: String
    let wallets: [Wallet]
    let networks: [Network]

    func validate() throws {
        try require(version == 1 && fixtureID == "shipped-1.0.98-147" && baseline == .shipped, "Unexpected shipped fixture baseline")
        try require(!fixturePassword.isEmpty && wallets.count == 3 && wallets.reduce(0) { $0 + $1.accounts.count } == 4,
            "Unexpected shipped fixture inventory")
        try require(Set(wallets.map(\.fixtureID)) == Set(["mnemonic", "ethereum", "solana"]), "Unexpected fixture wallet identities")
        try require(Set(wallets.map(\.walletID)).count == wallets.count, "Duplicate fixture wallet identity")
        try require(try hexData(ethereumDigestHex).count == 32, "Invalid Ethereum fixture digest")
        try require(!(try hexData(solanaMessageHex)).isEmpty, "Empty Solana fixture message")
        try require(networks.count == 1 && networks[0].chainID == 31337 && networks[0].chainIDHex == "0x7a69",
            "Unexpected fixture network")
        for wallet in wallets {
            try require(!wallet.walletID.isEmpty && !wallet.accounts.isEmpty && wallet.walletDataSHA256.count == 64, "Invalid fixture wallet")
            try require(wallet.isMnemonic == (wallet.mnemonicBackup != nil), "Invalid fixture backup type")
            for account in wallet.accounts {
                _ = try account.walletCoin
                try require([0, 1, 6].contains(account.derivation) && !account.privateKeyBackup.isEmpty, "Invalid fixture account")
                try require(try hexData(account.signing.signatureHex).count == (account.coin == 60 ? 65 : 64), "Invalid fixture signature size")
                try require(try hexData(account.signing.publicKeyHex).count == (account.coin == 60 ? 65 : 32), "Invalid fixture public key size")
            }
        }
    }
}

struct StorageHashes: Codable, Equatable, Sendable {
    let keychainSHA256: String?
    let preferencesSHA256: String?

    init(root: URL) throws {
        func digest(_ name: String) throws -> String? {
            let path = root.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: path.path) ? sha256(try readRegularFile(path)) : nil
        }
        keychainSHA256 = try digest("keychain.plist")
        preferencesSHA256 = try digest("preferences.plist")
    }

    private enum CodingKeys: String, CodingKey { case keychainSHA256, preferencesSHA256 }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keychainSHA256, forKey: .keychainSHA256)
        try container.encode(preferencesSHA256, forKey: .preferencesSHA256)
    }
}

struct ConsumerReport: Encodable {
    struct Counts: Encodable {
        var wallets = 0
        var accounts = 0
        var exports = 0
        var approvedSignatures = 0
    }

    struct Storage: Encodable {
        let before: StorageHashes
        var after: StorageHashes
    }

    struct FailureCase: Encodable {
        let name: String
        let rejected: Bool
        let before: StorageHashes
        let after: StorageHashes
        let keychainWrites: Int
        let preferenceWrites: Int
    }

    let version = 1
    let mode: String
    let fixtureID = "shipped-1.0.98-147"
    let baseline = Baseline.shipped
    let processID = ProcessInfo.processInfo.processIdentifier
    var status = "failed"
    var checks = [String]()
    var counts = Counts()
    var networkAttempts = 0
    var keychainWrites = 0
    var preferenceWrites = 0
    var storage: Storage
    var failureCases: [FailureCase]?
    var error: String?
}

struct WalletMapping: Codable {
    let version: Int
    let fixtureID: String
    let baseline: Baseline
    let walletIDs: [String: String]
    let password: String
    let addedWalletName: String?
}

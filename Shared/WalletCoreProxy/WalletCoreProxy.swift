// ∅ 2026 lil org

import Foundation
import WalletCore

enum WalletKeyStoreError: Swift.Error {
    case invalidPassword
    case invalidKey
    case invalidMnemonic
    case accountNotFound
}

enum WalletCoin: UInt32, Hashable {
    case ethereum = 60
    case solana = 501

    fileprivate var walletCoreCoin: CoinType {
        switch self {
        case .ethereum:
            return .ethereum
        case .solana:
            return .solana
        }
    }

    var slip44Id: UInt32 {
        return walletCoreCoin.slip44Id
    }

    fileprivate var extendedPublicKeyVersion: HDVersion {
        switch self {
        case .ethereum:
            return .xpub
        case .solana:
            return walletCoreCoin.xpubVersion
        }
    }
}

enum WalletDerivation: Hashable {
    case `default`
    case solanaSolana
    case custom

    fileprivate var walletCoreDerivation: Derivation {
        switch self {
        case .default:
            return .default
        case .solanaSolana:
            return .solanaSolana
        case .custom:
            return .custom
        }
    }

    fileprivate init(_ derivation: Derivation) {
        switch derivation {
        case .default:
            self = .default
        case .solanaSolana:
            self = .solanaSolana
        default:
            self = .custom
        }
    }
}

struct WalletAccount: Hashable {
    let address: String
    let coin: WalletCoin
    let derivation: WalletDerivation
    let derivationPath: String
    let publicKey: String
    let extendedPublicKey: String

    fileprivate init?(_ account: Account) {
        guard let coin = WalletCoin(account.coin) else { return nil }
        self.init(address: account.address,
                  coin: coin,
                  derivation: WalletDerivation(account.derivation),
                  derivationPath: account.derivationPath,
                  publicKey: account.publicKey,
                  extendedPublicKey: account.extendedPublicKey)
    }

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
    private let walletCorePrivateKey: PrivateKey

    init?(data: Data) {
        guard let walletCorePrivateKey = PrivateKey(data: data) else { return nil }
        self.walletCorePrivateKey = walletCorePrivateKey
    }

    fileprivate init(_ privateKey: PrivateKey) {
        walletCorePrivateKey = privateKey
    }

    func withData<Result>(_ body: (Data) throws -> Result) rethrows -> Result {
        var privateKeyData = walletCorePrivateKey.data
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        return try body(privateKeyData)
    }

    func publicKeyData(coin: WalletCoin) -> Data {
        return walletCorePrivateKey.getPublicKey(coinType: coin.walletCoreCoin).data
    }

    func publicKeyDescription(coin: WalletCoin) -> String {
        return walletCorePrivateKey.getPublicKey(coinType: coin.walletCoreCoin).description
    }

    func sign(digest: Data, coin: WalletCoin) -> Data? {
        return walletCorePrivateKey.sign(digest: digest, curve: coin.walletCoreCoin.curve)
    }
}

struct WalletHDWallet {
    fileprivate let walletCoreWallet: HDWallet

    init?(mnemonic: String, passphrase: String) {
        guard let walletCoreWallet = HDWallet(mnemonic: mnemonic, passphrase: passphrase) else { return nil }
        self.walletCoreWallet = walletCoreWallet
    }

    fileprivate init(_ wallet: HDWallet) {
        walletCoreWallet = wallet
    }

    func getKey(coin: WalletCoin, derivationPath: String) -> WalletPrivateKey {
        let privateKey = walletCoreWallet.getKey(coin: coin.walletCoreCoin, derivationPath: derivationPath)
        return WalletPrivateKey(privateKey)
    }

    func extendedPublicKey(coin: WalletCoin) -> String {
        let walletCoreCoin = coin.walletCoreCoin
        return walletCoreWallet.getExtendedPublicKey(purpose: walletCoreCoin.purpose,
                                                     coin: walletCoreCoin,
                                                     version: .xpub)
    }

    func extendedPublicKeyDerivation(coin: WalletCoin, derivation: WalletDerivation) -> String {
        let walletCoreCoin = coin.walletCoreCoin
        return walletCoreWallet.getExtendedPublicKeyDerivation(purpose: walletCoreCoin.purpose,
                                                               coin: walletCoreCoin,
                                                               derivation: derivation.walletCoreDerivation,
                                                               version: coin.extendedPublicKeyVersion)
    }

    func extendedPublicKeyAccount(coin: WalletCoin, derivation: WalletDerivation, account: UInt32) -> String {
        let walletCoreCoin = coin.walletCoreCoin
        return walletCoreWallet.getExtendedPublicKeyAccount(purpose: walletCoreCoin.purpose,
                                                            coin: walletCoreCoin,
                                                            derivation: derivation.walletCoreDerivation,
                                                            version: coin.extendedPublicKeyVersion,
                                                            account: account)
    }
}

struct WalletStoredKey {
    fileprivate let walletCoreKey: StoredKey

    var name: String {
        return walletCoreKey.name
    }

    var isMnemonic: Bool {
        return walletCoreKey.isMnemonic
    }

    var accountCount: Int {
        return walletCoreKey.accountCount
    }

    init(name: String, password: Data) {
        walletCoreKey = StoredKey(name: name, password: password)
    }

    fileprivate init(_ key: StoredKey) {
        walletCoreKey = key
    }

    static func importJSON(json: Data) -> WalletStoredKey? {
        return StoredKey.importJSON(json: json).map(WalletStoredKey.init)
    }

    static func importPrivateKey(privateKey: Data, name: String, password: Data, coin: WalletCoin) -> WalletStoredKey? {
        return StoredKey.importPrivateKey(privateKey: privateKey,
                                          name: name,
                                          password: password,
                                          coin: coin.walletCoreCoin).map(WalletStoredKey.init)
    }

    static func importHDWallet(mnemonic: String, name: String, password: Data, coin: WalletCoin) -> WalletStoredKey? {
        return StoredKey.importHDWallet(mnemonic: mnemonic,
                                        name: name,
                                        password: password,
                                        coin: coin.walletCoreCoin).map(WalletStoredKey.init)
    }

    func wallet(password: Data) -> WalletHDWallet? {
        return walletCoreKey.wallet(password: password).map(WalletHDWallet.init)
    }

    func account(index: Int) -> WalletAccount? {
        return walletCoreKey.account(index: index).flatMap(WalletAccount.init)
    }

    func accountForCoin(coin: WalletCoin, wallet: WalletHDWallet?) -> WalletAccount? {
        return walletCoreKey.accountForCoin(coin: coin.walletCoreCoin, wallet: wallet?.walletCoreWallet).flatMap(WalletAccount.init)
    }

    func accountForCoinDerivation(coin: WalletCoin, derivation: WalletDerivation, wallet: WalletHDWallet?) -> WalletAccount? {
        return walletCoreKey.accountForCoinDerivation(coin: coin.walletCoreCoin,
                                                      derivation: derivation.walletCoreDerivation,
                                                      wallet: wallet?.walletCoreWallet).flatMap(WalletAccount.init)
    }

    func privateKey(coin: WalletCoin, password: Data) -> WalletPrivateKey? {
        guard let privateKey = walletCoreKey.privateKey(coin: coin.walletCoreCoin, password: password) else { return nil }
        return WalletPrivateKey(privateKey)
    }

    func decryptPrivateKey(password: Data) -> Data? {
        return walletCoreKey.decryptPrivateKey(password: password)
    }

    func decryptMnemonic(password: Data) -> String? {
        return walletCoreKey.decryptMnemonic(password: password)
    }

    func exportJSON() -> Data? {
        return walletCoreKey.exportJSON()
    }

    func removeAccountForCoinDerivationPath(coin: WalletCoin, derivationPath: String) {
        walletCoreKey.removeAccountForCoinDerivationPath(coin: coin.walletCoreCoin, derivationPath: derivationPath)
    }

    func removeAccountForCoin(coin: WalletCoin) {
        walletCoreKey.removeAccountForCoin(coin: coin.walletCoreCoin)
    }

    func addAccountDerivation(address: String,
                              coin: WalletCoin,
                              derivation: WalletDerivation,
                              derivationPath: String,
                              publicKey: String,
                              extendedPublicKey: String) {
        walletCoreKey.addAccountDerivation(address: address,
                                           coin: coin.walletCoreCoin,
                                           derivation: derivation.walletCoreDerivation,
                                           derivationPath: derivationPath,
                                           publicKey: publicKey,
                                           extendedPublicKey: extendedPublicKey)
    }

    func copyUnsupportedAccounts(from source: WalletStoredKey) {
        for index in 0..<source.accountCount {
            guard let account = source.walletCoreKey.account(index: index),
                  WalletCoin(account.coin) == nil else { continue }

            walletCoreKey.addAccountDerivation(address: account.address,
                                               coin: account.coin,
                                               derivation: account.derivation,
                                               derivationPath: account.derivationPath,
                                               publicKey: account.publicKey,
                                               extendedPublicKey: account.extendedPublicKey)
        }
    }
}

enum WalletCrypto {

    static func isValidMnemonic(_ mnemonic: String) -> Bool {
        return Mnemonic.isValid(mnemonic: mnemonic)
    }

    static func isValidMnemonic(mnemonic: String) -> Bool {
        return isValidMnemonic(mnemonic)
    }

    static func isValidPrivateKeyData(_ data: Data, coin: WalletCoin) -> Bool {
        return PrivateKey.isValid(data: data, curve: coin.walletCoreCoin.curve)
    }

    static func isValidPrivateKeyData(data: Data, coin: WalletCoin) -> Bool {
        return isValidPrivateKeyData(data, coin: coin)
    }

    static func base58Decode(_ string: String) -> Data? {
        return Base58.decodeNoCheck(string: string)
    }

    static func base58Decode(string: String) -> Data? {
        return base58Decode(string)
    }

    static func base58Encode(_ data: Data) -> String {
        return Base58.encodeNoCheck(data: data)
    }

    static func base58Encode(data: Data) -> String {
        return base58Encode(data)
    }

    static func hexData(_ string: String) -> Data? {
        let hexString = string.hasPrefix(String.hexPrefix) ? String(string.dropFirst(String.hexPrefix.count)) : string
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

    static func hexData(string: String) -> Data? {
        return hexData(string)
    }

    static func hexString(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count * 2)

        for byte in data {
            bytes.append(alphabet[Int(byte >> 4)])
            bytes.append(alphabet[Int(byte & 0x0f)])
        }

        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    static func hexString(data: Data) -> String {
        return hexString(data)
    }

    static func keccak256(data: Data) -> Data {
        return Hash.keccak256(data: data)
    }

    static func publicKeyDescriptionFromExtended(extended: String, coin: WalletCoin, derivationPath: String) -> String? {
        guard DerivationPath(derivationPath) != nil else { return nil }
        return HDWallet.getPublicKeyFromExtended(extended: extended,
                                                 coin: coin.walletCoreCoin,
                                                 derivationPath: derivationPath)?.description
    }

    static func accountFromExtendedPublicKey(extended: String,
                                             coin: WalletCoin,
                                             derivation: WalletDerivation,
                                             derivationPath: String) -> WalletAccount? {
        let walletCoreCoin = coin.walletCoreCoin
        guard DerivationPath(derivationPath) != nil else { return nil }
        guard let publicKey = HDWallet.getPublicKeyFromExtended(extended: extended,
                                                                coin: walletCoreCoin,
                                                                derivationPath: derivationPath) else { return nil }
        let address = walletCoreCoin.deriveAddressFromPublicKey(publicKey: publicKey)
        guard !address.isEmpty else { return nil }

        return WalletAccount(address: address,
                             coin: coin,
                             derivation: derivation,
                             derivationPath: derivationPath,
                             publicKey: publicKey.description,
                             extendedPublicKey: extended)
    }

    static func addressFromPublicKeyDescription(_ publicKeyDescription: String, coin: WalletCoin) -> String {
        let walletCoreCoin = coin.walletCoreCoin
        guard let publicKeyData = hexData(publicKeyDescription),
              isSupportedPublicKeyData(publicKeyData, coin: coin),
              PublicKey.isValid(data: publicKeyData, type: walletCoreCoin.publicKeyType),
              let publicKey = PublicKey(data: publicKeyData, type: walletCoreCoin.publicKeyType)
        else { return "" }
        return walletCoreCoin.deriveAddressFromPublicKey(publicKey: publicKey)
    }

    static func addressFromPublicKeyData(_ publicKeyData: Data, coin: WalletCoin) -> String {
        let walletCoreCoin = coin.walletCoreCoin
        guard isSupportedPublicKeyData(publicKeyData, coin: coin),
              PublicKey.isValid(data: publicKeyData, type: walletCoreCoin.publicKeyType),
              let publicKey = PublicKey(data: publicKeyData, type: walletCoreCoin.publicKeyType)
        else { return "" }
        return walletCoreCoin.deriveAddressFromPublicKey(publicKey: publicKey)
    }

    static func recoverEthereumAddress(signature: Data, messageHash: Data) -> String? {
        guard let publicKey = PublicKey.recover(signature: signature, message: messageHash),
              PublicKey.isValid(data: publicKey.data, type: publicKey.keyType) else {
            return nil
        }
        return CoinType.ethereum.deriveAddressFromPublicKey(publicKey: publicKey)
    }

    static func ethereumTypedDataDigest(messageJson: String) -> Data {
        return EthereumAbi.encodeTyped(messageJson: messageJson)
    }

    static func decodeEthereumCall(data: Data, abi: String) -> String? {
        return EthereumAbi.decodeCall(data: data, abi: abi)
    }

    static func signEthereumTransaction(chainID: Data,
                                        nonce: Data,
                                        gasPrice: Data,
                                        gasLimit: Data,
                                        toAddress: String,
                                        privateKey: WalletPrivateKey,
                                        amount: Data,
                                        data: Data) -> Data {
        return privateKey.withData { privateKeyData in
            let input = EthereumSigningInput.with {
                $0.chainID = chainID
                $0.nonce = nonce
                $0.gasPrice = gasPrice
                $0.gasLimit = gasLimit
                $0.toAddress = toAddress
                $0.privateKey = privateKeyData
                $0.transaction = EthereumTransaction.with {
                    $0.contractGeneric = EthereumTransaction.ContractGeneric.with {
                        $0.amount = amount
                        $0.data = data
                    }
                }
            }
            let output: EthereumSigningOutput = AnySigner.sign(input: input, coin: .ethereum)
            return output.encoded
        }
    }

    static func bip44DerivationPath(coin: WalletCoin, account: UInt32, change: UInt32, address: UInt32) -> String {
        return DerivationPath(purpose: .bip44,
                              coin: coin.slip44Id,
                              account: account,
                              change: change,
                              address: address).description
    }

    static func previewDerivationIndex(derivationPath: String, coin: WalletCoin) -> Int {
        guard let path = DerivationPath(derivationPath) else { return 0 }
        switch coin {
        case .solana:
            return Int(path.account)
        default:
            return Int(path.address)
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            return byte - 48
        case 65...70:
            return byte - 55
        case 97...102:
            return byte - 87
        default:
            return nil
        }
    }

    private static func isSupportedPublicKeyData(_ data: Data, coin: WalletCoin) -> Bool {
        switch coin {
        case .solana:
            return data.count == 32 || (data.count == 33 && data.first == 0x01)
        case .ethereum:
            return true
        }
    }
}

private extension WalletCoin {

    init?(_ coin: CoinType) {
        switch coin {
        case .ethereum:
            self = .ethereum
        case .solana:
            self = .solana
        default:
            return nil
        }
    }

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
        guard let coin = CoinType(rawValue: account.coinRawValue),
              let derivation = Derivation(rawValue: account.derivationRawValue) else {
            preconditionFailure("Invalid raw WalletCore account test vector")
        }

        walletCoreKey.addAccountDerivation(address: account.address,
                                           coin: coin,
                                           derivation: derivation,
                                           derivationPath: account.derivationPath,
                                           publicKey: account.publicKey,
                                           extendedPublicKey: account.extendedPublicKey)
    }

    func rawAccountForTesting(index: Int) -> WalletRawAccountForTesting? {
        guard let account = walletCoreKey.account(index: index) else { return nil }

        return WalletRawAccountForTesting(address: account.address,
                                          coinRawValue: account.coin.rawValue,
                                          derivationRawValue: account.derivation.rawValue,
                                          derivationPath: account.derivationPath,
                                          publicKey: account.publicKey,
                                          extendedPublicKey: account.extendedPublicKey)
    }

}
#endif

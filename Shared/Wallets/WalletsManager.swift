// ∅ 2026 lil org
// Rewrite of KeyStore.swift from Trust Wallet Core.

import Foundation
import WalletCore

final class WalletsManager {

    enum Error: Swift.Error {
        case keychainAccessFailure
        case invalidInput
        case failedToDeriveAccount
    }
    
    enum InputValidationResult {
        case valid, invalid, requiresPassword
    }
    
    static let shared = WalletsManager()
    private static let previewAccountsPageSize = 11
    private let keychain = Keychain.shared
    private let defaultCoin = CoinType.ethereum
    private let defaultMnemonicCoinDerivations: [(coin: CoinType, derivation: Derivation)] = [
        (.ethereum, .default),
        (.solana, .solanaSolana),
    ]
    private(set) var wallets = [WalletContainer]()

    private init() {}

    func start() {
        try? loadWalletsFromKeychain()
    }
    
    func validateWalletInput(_ input: String) -> InputValidationResult {
        let trimmedInput = input.singleSpaced
        if Mnemonic.isValid(mnemonic: trimmedInput) {
            return .valid
        } else if let data = Data(hexString: trimmedInput) {
            return PrivateKey.isValid(data: data, curve: defaultCoin.curve) ? .valid : .invalid
        } else {
            return input.maybeJSON ? .requiresPassword : .invalid
        }
    }
    
    func createWallet() throws -> WalletContainer {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        return try createWallet(name: defaultWalletName, password: password)
    }
    
    func getWallet(id: String) -> WalletContainer? {
        return wallets.first(where: { $0.id == id })
    }
    
    func addWallet(input: String, inputPassword: String?) throws -> WalletContainer {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        let name = defaultWalletName
        let trimmedInput = input.singleSpaced
        if Mnemonic.isValid(mnemonic: trimmedInput) {
            return try importMnemonic(trimmedInput, name: name, encryptPassword: password)
        } else if let data = Data(hexString: trimmedInput), PrivateKey.isValid(data: data, curve: defaultCoin.curve), let privateKey = PrivateKey(data: data) {
            return try importPrivateKey(privateKey, name: name, password: password, coin: defaultCoin, onlyToKeychain: false)
        } else if input.maybeJSON, let inputPassword = inputPassword, let json = input.data(using: .utf8) {
            return try importJSON(json, name: name, password: inputPassword, newPassword: password, coin: defaultCoin, onlyToKeychain: false)
        } else {
            throw Error.invalidInput
        }
    }
    
    func getSpecificAccount(coin: CoinType, address: String) -> SpecificWalletAccount? {
        return getWalletAndAccount(coin: coin, address: address).map { wallet, account in
            SpecificWalletAccount(walletId: wallet.id, account: account)
        }
    }
    
    func suggestedAccounts(coin: CoinType? = nil) -> [SpecificWalletAccount] {
        return suggestedAccounts(for: [coin ?? defaultCoin])
    }

    func suggestedAccounts(providers: Set<InpageProvider>) -> [SpecificWalletAccount] {
        guard !providers.isEmpty else { return [] }

        let coins = InpageProvider.allCases
            .filter(providers.contains)
            .compactMap(CoinType.correspondingToInpageProvider)
        return suggestedAccounts(for: coins)
    }
    
    func previewAccounts(wallet: WalletContainer, page: Int, coin: CoinType? = nil) throws -> [Account] {
        guard let password = keychain.password, let hdWallet = wallet.key.wallet(password: Data(password.utf8)) else { throw Error.keychainAccessFailure }
        return try previewAccounts(hdWallet: hdWallet, page: page, coin: coin)
    }

    func previewAccounts(hdWallet: HDWallet, page: Int, coin: CoinType?) throws -> [Account] {
        guard let coin else {
            return try Self.collectPreviewAccounts(coins: defaultMnemonicCoins) { previewCoin in
                try previewAccounts(hdWallet: hdWallet, page: page, coin: previewCoin)
            }
        }

        if coin == .solana { return try previewSolanaAccounts(hdWallet: hdWallet, page: page) }

        let range = Self.previewAccountIndexRange(page: page)
        let xpub = hdWallet.getExtendedPublicKey(purpose: coin.purpose, coin: coin, version: .xpub)
        let accounts = range.compactMap { i -> Account? in
            let dp = DerivationPath(purpose: .bip44, coin: coin.slip44Id, account: 0, change: 0, address: UInt32(i)).description
            guard let pubkey = HDWallet.getPublicKeyFromExtended(extended: xpub, coin: coin, derivationPath: dp) else { return nil }
            let address = coin.deriveAddressFromPublicKey(publicKey: pubkey)
            let account = Account(address: address, coin: coin, derivation: .custom, derivationPath: dp, publicKey: pubkey.description, extendedPublicKey: xpub)
            return account
        }
        guard accounts.count == range.count else { throw Error.failedToDeriveAccount }
        return accounts
    }

    static func collectPreviewAccounts(coins: [CoinType],
                                       previewAccountsForCoin: (CoinType) throws -> [Account]) throws -> [Account] {
        var accountGroups = [[Account]]()
        var firstError: Swift.Error?

        for coin in coins {
            do {
                accountGroups.append(try previewAccountsForCoin(coin))
            } catch {
                firstError = firstError ?? error
            }
        }

        let accounts = interleaved(accountGroups)
        if accounts.isEmpty, let firstError {
            throw firstError
        }

        return accounts
    }

    private static func interleaved(_ accountGroups: [[Account]]) -> [Account] {
        let totalCount = accountGroups.reduce(0) { $0 + $1.count }
        let maxCount = accountGroups.map { $0.count }.max() ?? 0
        var accounts = [Account]()
        accounts.reserveCapacity(totalCount)

        for index in 0..<maxCount {
            for group in accountGroups where index < group.count {
                accounts.append(group[index])
            }
        }

        return accounts
    }

    private func createWallet(name: String, password: String) throws -> WalletContainer {
        let key = StoredKey(name: name, password: Data(password.utf8))
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: password)
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    private func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: CoinType, onlyToKeychain: Bool) throws -> WalletContainer {
        guard let key = StoredKey.importJSON(json: json) else { throw KeyStore.Error.invalidKey }
        guard let data = key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        if let mnemonic = checkMnemonic(data) { return try self.importMnemonic(mnemonic, name: name, encryptPassword: newPassword) }
        guard let privateKey = PrivateKey(data: data) else { throw KeyStore.Error.invalidKey }
        return try self.importPrivateKey(privateKey, name: name, password: newPassword, coin: coin, onlyToKeychain: onlyToKeychain)
    }

    private func checkMnemonic(_ data: Data) -> String? {
        guard let mnemonic = String(data: data, encoding: .ascii), Mnemonic.isValid(mnemonic: mnemonic) else { return nil }
        return mnemonic
    }

    private func importPrivateKey(_ privateKey: PrivateKey, name: String, password: String, coin: CoinType, onlyToKeychain: Bool) throws -> WalletContainer {
        guard let newKey = StoredKey.importPrivateKey(privateKey: privateKey.data, name: name, password: Data(password.utf8), coin: coin) else { throw KeyStore.Error.invalidKey }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: newKey)
        _ = try wallet.getAccount(password: password, coin: coin)
        if !onlyToKeychain {
            wallets.append(wallet)
        }
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    private func importMnemonic(_ mnemonic: String, name: String, encryptPassword: String) throws -> WalletContainer {
        guard let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: Data(encryptPassword.utf8), coin: defaultCoin) else { throw KeyStore.Error.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: encryptPassword)
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    func exportPrivateKey(wallet: WalletContainer, account: Account? = nil) throws -> String {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let account = account ?? wallet.accounts.first else { throw KeyStore.Error.accountNotFound }
        let privateKey = try wallet.privateKey(password: password, account: account)
        return Self.privateKeyExportString(privateKey: privateKey, coin: account.coin)
    }

    static func privateKeyExportString(privateKey: PrivateKey, coin: CoinType) -> String {
        switch coin {
        case .solana:
            return solanaSecretKeyExportString(privateKey: privateKey)
        default:
            return hexPrivateKeyExportString(privateKey: privateKey)
        }
    }

    private static func solanaSecretKeyExportString(privateKey: PrivateKey) -> String {
        var secretKey = privateKey.data
        defer { secretKey.resetBytes(in: 0..<secretKey.count) }

        if secretKey.count == 32 {
            secretKey.append(privateKey.getPublicKey(coinType: .solana).data)
        }

        return Base58.encodeNoCheck(data: secretKey)
    }

    private static func hexPrivateKeyExportString(privateKey: PrivateKey) -> String {
        var privateKeyData = privateKey.data
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }

        return privateKeyData.hexString
    }

    func exportMnemonic(wallet: WalletContainer) throws -> String {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let mnemonic = wallet.key.decryptMnemonic(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        return mnemonic
    }

    func update(wallet: WalletContainer, newPassword: String) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, password: password, newPassword: newPassword, newName: wallet.key.name)
    }

    func delete(wallet: WalletContainer) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKey = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidKey }
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }
        wallets.remove(at: index)
        try keychain.removeWallet(id: wallet.id)
        postWalletsChangedNotification()
        WalletsMetadataService.removeMetadataForWallet(wallet)
    }

    func destroy() throws {
        wallets.removeAll(keepingCapacity: false)
        try keychain.removeAllWallets()
    }
    
    private func loadWalletsFromKeychain() throws {
        let ids = keychain.getAllWalletsIds()
        for id in ids {
            guard let data = keychain.getWalletData(id: id), let key = StoredKey.importJSON(json: data) else { continue }
            let wallet = WalletContainer(id: id, key: key)
            wallets.append(wallet)
        }
    }
    
    func update(wallet: WalletContainer, enabledAccounts: [Account]) throws {
        for account in wallet.accounts {
            wallet.key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
        }
        for account in enabledAccounts {
            wallet.key.addAccountDerivation(address: account.address,
                                            coin: account.coin,
                                            derivation: account.derivation,
                                            derivationPath: account.derivationPath,
                                            publicKey: account.publicKey,
                                            extendedPublicKey: account.extendedPublicKey)
        }
        try save(wallet: wallet, isUpdate: true)
    }
    
    func update(wallet: WalletContainer, removeAccounts toRemove: [Account]) throws {
        for account in toRemove {
            wallet.key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
        }
        
        try save(wallet: wallet, isUpdate: true)
    }
    
    private func update(wallet: WalletContainer, password: String, newPassword: String, newName: String) throws {
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKeyData = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        let enabledAccounts = wallet.accounts
        
        if let mnemonic = checkMnemonic(privateKeyData),
           let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: defaultCoin) {
            wallets[index].key = key
        } else if let key = StoredKey.importPrivateKey(privateKey: privateKeyData, name: newName, password: Data(newPassword.utf8), coin: defaultCoin) {
            wallets[index].key = key
        } else {
            throw KeyStore.Error.invalidKey
        }
        
        wallets[index].key.removeAccountForCoin(coin: defaultCoin)
        for account in enabledAccounts {
            wallets[index].key.addAccountDerivation(address: account.address,
                                                    coin: account.coin,
                                                    derivation: account.derivation,
                                                    derivationPath: account.derivationPath,
                                                    publicKey: account.publicKey,
                                                    extendedPublicKey: account.extendedPublicKey)
        }
        
        try save(wallet: wallets[index], isUpdate: true)
    }

    private func save(wallet: WalletContainer, isUpdate: Bool) throws {
        guard let data = wallet.key.exportJSON() else { throw KeyStore.Error.invalidPassword }
        if isUpdate {
            try keychain.updateWallet(id: wallet.id, data: data)
        } else {
            try keychain.saveWallet(id: wallet.id, data: data)
        }
        postWalletsChangedNotification()
    }
    
    private func postWalletsChangedNotification() {
        NotificationCenter.default.post(name: .walletsChanged, object: nil)
    }
    
    private let defaultWalletName = ""
    private lazy var defaultMnemonicCoins: [CoinType] = {
        var previewCoins = [CoinType]()
        var seenCoins = Set<CoinType>()

        for derivation in defaultMnemonicCoinDerivations where seenCoins.insert(derivation.coin).inserted {
            previewCoins.append(derivation.coin)
        }

        return previewCoins
    }()

    private func suggestedAccounts(for coins: [CoinType]) -> [SpecificWalletAccount] {
        var suggestions = [SpecificWalletAccount]()
        var seenCoins = Set<CoinType>()

        for coin in coins {
            guard seenCoins.insert(coin).inserted else { continue }
            if let suggestion = firstSuggestedAccount(for: coin) {
                suggestions.append(suggestion)
            }
        }

        return suggestions
    }

    private func firstSuggestedAccount(for coin: CoinType) -> SpecificWalletAccount? {
        for wallet in wallets {
            if let account = wallet.accounts.first(where: { $0.coin == coin }) {
                return SpecificWalletAccount(walletId: wallet.id, account: account)
            }
        }
        return nil
    }

    private func addMnemonicAccounts(to wallet: WalletContainer,
                                     password: String,
                                     coinDerivations: [(coin: CoinType, derivation: Derivation)]) throws {
        guard wallet.isMnemonic else { return }

        let hdWallet = wallet.key.wallet(password: Data(password.utf8))
        for (coin, derivation) in coinDerivations
        where !wallet.accounts.contains(where: { $0.coin == coin && $0.derivation == derivation }) {
            guard wallet.key.accountForCoinDerivation(coin: coin, derivation: derivation, wallet: hdWallet) != nil else {
                throw KeyStore.Error.invalidPassword
            }
        }
    }

    private func addDefaultMnemonicAccounts(to wallet: WalletContainer, password: String) throws {
        try addMnemonicAccounts(to: wallet, password: password, coinDerivations: defaultMnemonicCoinDerivations)
    }

    private static func previewAccountIndexRange(page: Int) -> Range<Int> {
        let start = page * previewAccountsPageSize
        return start..<(start + previewAccountsPageSize)
    }

    private func previewSolanaAccounts(hdWallet: HDWallet, page: Int) throws -> [Account] {
        let coin = CoinType.solana
        let accounts = Self.previewAccountIndexRange(page: page).map { accountIndex in
            let derivation = accountIndex == 0 ? Derivation.solanaSolana : .custom
            let derivationPath = Self.solanaDerivationPath(accountIndex: accountIndex)
            let privateKey = hdWallet.getKey(coin: coin, derivationPath: derivationPath)
            let publicKey = privateKey.getPublicKey(coinType: coin)
            let address = coin.deriveAddressFromPublicKey(publicKey: publicKey)
            let extendedPublicKey = solanaExtendedPublicKey(hdWallet: hdWallet, accountIndex: accountIndex)

            return Account(address: address,
                           coin: coin,
                           derivation: derivation,
                           derivationPath: derivationPath,
                           publicKey: publicKey.description,
                           extendedPublicKey: extendedPublicKey)
        }

        guard accounts.allSatisfy({ !$0.address.isEmpty }) else { throw Error.failedToDeriveAccount }
        return accounts
    }

    private static func solanaDerivationPath(accountIndex: Int) -> String {
        return "m/44'/\(CoinType.solana.slip44Id)'/\(accountIndex)'/0'"
    }

    private func solanaExtendedPublicKey(hdWallet: HDWallet, accountIndex: Int) -> String {
        let coin = CoinType.solana
        guard accountIndex != 0 else {
            return hdWallet.getExtendedPublicKeyDerivation(purpose: coin.purpose,
                                                           coin: coin,
                                                           derivation: .solanaSolana,
                                                           version: coin.xpubVersion)
        }

        return hdWallet.getExtendedPublicKeyAccount(purpose: coin.purpose,
                                                    coin: coin,
                                                    derivation: .solanaSolana,
                                                    version: coin.xpubVersion,
                                                    account: UInt32(accountIndex))
    }
    
    private func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }
    
}

extension WalletsManager {
    
    func getPrivateKey(wallet: WalletContainer, account: Account) -> PrivateKey? {
        guard let password = Keychain.shared.password else { return nil }
        return try? wallet.privateKey(password: password, account: account)
    }
    
    func getPrivateKey(coin: CoinType, address: String) -> PrivateKey? {
        guard let password = Keychain.shared.password else { return nil }
        if let (wallet, account) = getWalletAndAccount(coin: coin, address: address) {
            return try? wallet.privateKey(password: password, account: account)
        } else {
            return nil
        }
    }
    
    func getWalletAndAccount(coin: CoinType, address: String) -> (WalletContainer, Account)? {
        let normalizedAddress = coin.normalizedAddress(address)
        for wallet in wallets {
            for account in wallet.accounts where account.coin == coin {
                let match = coin.normalizedAddress(account.address) == normalizedAddress
                if match {
                    return (wallet, account)
                }
            }
        }
        return nil
    }
    
}

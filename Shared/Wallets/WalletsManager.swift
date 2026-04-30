// ∅ 2026 lil org
// Rewrite of KeyStore.swift from Trust Wallet Core.

import Foundation
import WalletCore

struct WalletStoreSync {

    private static let senderProcessId = String(ProcessInfo.processInfo.processIdentifier)

    static func postLocalChange() {
        NotificationCenter.default.post(name: .walletsChanged, object: nil)
    }

    static func postLocalAndExternalChange(defaultsAlreadySynchronized: Bool = false) {
        if !defaultsAlreadySynchronized {
            Defaults.synchronize()
        }
        postLocalChange()
        postExternalChange()
    }

#if os(macOS)
    static func startObserving(_ observer: Any, selector: Selector) {
        DistributedNotificationCenter.default().addObserver(observer,
                                                            selector: selector,
                                                            name: .walletStoreChanged,
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
    }

    static func isExternalChange(_ notification: Notification) -> Bool {
        guard let sender = notification.object as? String else { return true }
        return sender != senderProcessId
    }

    private static func postExternalChange() {
        DistributedNotificationCenter.default().post(name: .walletStoreChanged, object: senderProcessId)
    }
#else
    static func startObserving(_ observer: Any, selector: Selector) {}
    static func isExternalChange(_ notification: Notification) -> Bool { false }
    private static func postExternalChange() {}
#endif

}

final class WalletsManager: NSObject {

    enum Error: Swift.Error {
        case keychainAccessFailure
        case invalidInput
        case failedToDeriveAccount
    }

    enum InputValidationResult {
        case valid, invalid, requiresPassword
    }

    struct PrivateKeyImport {
        let privateKey: PrivateKey
        let coin: CoinType
    }

    static let shared = WalletsManager()
    private static let previewAccountsPageSize = 11
    private static let solanaBase58SecretKeyLengthRange = 32...88
    private static let maxSolanaSecretKeyByteArrayStringLength = 1024
    private let keychain = Keychain.shared
    private let defaultCoin = CoinType.ethereum
    private let defaultMnemonicCoinDerivations: [(coin: CoinType, derivation: Derivation)] = [
        (.ethereum, .default),
        (.solana, .solanaSolana),
    ]
    private(set) var wallets = [WalletContainer]()

    private var isObservingExternalChanges = false

    private override init() {
        super.init()
    }

    func start() {
        reloadWalletsFromKeychain()
        startObservingExternalChanges()
    }

    func validateWalletInput(_ input: String) -> InputValidationResult {
        let trimmedInput = input.singleSpaced
        if Mnemonic.isValid(mnemonic: trimmedInput) {
            return .valid
        } else if Self.privateKeyImport(from: trimmedInput) != nil {
            return .valid
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
        } else if let privateKeyImport = Self.privateKeyImport(from: trimmedInput) {
            return try importPrivateKey(privateKeyImport.privateKey, name: name, password: password, coin: privateKeyImport.coin, onlyToKeychain: false)
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

    func exportPrivateKey(walletId: String, account: Account? = nil) throws -> String {
        guard let wallet = currentWallet(id: walletId) else { throw KeyStore.Error.accountNotFound }
        if let account {
            guard wallet.hasAccountMatching(account) else { throw KeyStore.Error.accountNotFound }
        }
        return try exportPrivateKey(wallet: wallet, account: account)
    }

    static func privateKeyExportString(privateKey: PrivateKey, coin: CoinType) -> String {
        switch coin {
        case .solana:
            return solanaSecretKeyExportString(privateKey: privateKey)
        default:
            return hexPrivateKeyExportString(privateKey: privateKey)
        }
    }

    static func privateKeyImport(from input: String) -> PrivateKeyImport? {
        if let ethereumPrivateKey = ethereumPrivateKeyImport(from: input) {
            return PrivateKeyImport(privateKey: ethereumPrivateKey, coin: .ethereum)
        }

        if let solanaPrivateKey = solanaPrivateKeyImport(from: input) {
            return PrivateKeyImport(privateKey: solanaPrivateKey, coin: .solana)
        }

        return nil
    }

    private static func ethereumPrivateKeyImport(from input: String) -> PrivateKey? {
        guard let data = Data(hexString: input),
              PrivateKey.isValid(data: data, curve: CoinType.ethereum.curve)
        else { return nil }

        var privateKeyData = data
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        return PrivateKey(data: privateKeyData)
    }

    private static func solanaPrivateKeyImport(from input: String) -> PrivateKey? {
        if solanaBase58SecretKeyLengthRange.contains(input.count),
           let secretKey = Base58.decodeNoCheck(string: input) {
            return solanaPrivateKeyImport(secretKey: secretKey)
        }

        if let secretKey = solanaSecretKeyData(fromByteArrayString: input) {
            return solanaPrivateKeyImport(secretKey: secretKey)
        }

        return nil
    }

    private static func solanaSecretKeyData(fromByteArrayString input: String) -> Data? {
        guard input.hasPrefix("["),
              input.hasSuffix("]"),
              input.count <= maxSolanaSecretKeyByteArrayStringLength,
              let inputData = input.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: inputData),
              let values = jsonObject as? [Any],
              values.count == 32 || values.count == 64
        else { return nil }

        var secretKey = Data()
        secretKey.reserveCapacity(values.count)

        for value in values {
            guard !(value is Bool), let number = value as? NSNumber else { return nil }
            let byteValue = number.doubleValue
            guard byteValue.rounded() == byteValue,
                  byteValue >= Double(UInt8.min),
                  byteValue <= Double(UInt8.max)
            else { return nil }
            secretKey.append(UInt8(byteValue))
        }

        return secretKey
    }

    private static func solanaPrivateKeyImport(secretKey: Data) -> PrivateKey? {
        var secretKeyData = secretKey
        defer { secretKeyData.resetBytes(in: 0..<secretKeyData.count) }

        switch secretKeyData.count {
        case 32:
            guard PrivateKey.isValid(data: secretKeyData, curve: CoinType.solana.curve) else { return nil }
            return PrivateKey(data: secretKeyData)
        case 64:
            var privateKeyData = Data(secretKeyData.prefix(32))
            defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
            guard PrivateKey.isValid(data: privateKeyData, curve: CoinType.solana.curve),
                  let privateKey = PrivateKey(data: privateKeyData)
            else { return nil }

            let expectedPublicKey = privateKey.getPublicKey(coinType: .solana).data
            let exportedPublicKey = Data(secretKeyData.suffix(32))
            return exportedPublicKey == expectedPublicKey ? privateKey : nil
        default:
            return nil
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

    func exportMnemonic(walletId: String) throws -> String {
        guard let wallet = currentWallet(id: walletId) else { throw KeyStore.Error.accountNotFound }
        return try exportMnemonic(wallet: wallet)
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
        WalletsMetadataService.removeMetadataForWallet(wallet, postChange: false)
        postWalletsChangedNotification()
    }

    func destroy() throws {
        wallets.removeAll(keepingCapacity: false)
        try keychain.removeAllWallets()
        WalletsMetadataService.removeAllMetadata(postChange: false)
        postWalletsChangedNotification()
    }

    private func reloadWalletsFromKeychain() {
        wallets = keychain.getAllWalletsIds().compactMap { currentWallet(id: $0) }
    }

    func currentWallet(id: String) -> WalletContainer? {
        guard let data = keychain.getWalletData(id: id), let key = StoredKey.importJSON(json: data) else { return nil }
        return WalletContainer(id: id, key: key)
    }

    func update(wallet: WalletContainer, enabledAccounts: [Account]) throws {
        guard let currentWallet = currentWallet(id: wallet.id) else { throw KeyStore.Error.accountNotFound }

        let originalKeys = Set(wallet.accounts.map { $0.previewAccountKey })
        let enabledKeys = Set(enabledAccounts.map { $0.previewAccountKey })
        let disabledByThisEdit = originalKeys.subtracting(enabledKeys)

        var mergedAccounts = currentWallet.accounts.filter { !disabledByThisEdit.contains($0.previewAccountKey) }
        var mergedKeys = Set(mergedAccounts.map { $0.previewAccountKey })
        for account in enabledAccounts where !originalKeys.contains(account.previewAccountKey) && !mergedKeys.contains(account.previewAccountKey) {
            mergedAccounts.append(account)
            mergedKeys.insert(account.previewAccountKey)
        }

        try replaceAccounts(in: currentWallet, with: mergedAccounts)
    }

    func update(wallet: WalletContainer, removeAccounts toRemove: [Account]) throws {
        guard let currentWallet = currentWallet(id: wallet.id) else { throw KeyStore.Error.accountNotFound }

        let keysToRemove = Set(toRemove.map { $0.previewAccountKey })
        let remainingAccounts = currentWallet.accounts.filter { !keysToRemove.contains($0.previewAccountKey) }
        try replaceAccounts(in: currentWallet, with: remainingAccounts)
    }

    private func replaceAccounts(in wallet: WalletContainer, with accounts: [Account]) throws {
        guard !accounts.isEmpty else { throw Error.invalidInput }

        for account in wallet.accounts {
            wallet.key.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath)
        }
        for account in accounts {
            wallet.key.addAccountDerivation(address: account.address,
                                            coin: account.coin,
                                            derivation: account.derivation,
                                            derivationPath: account.derivationPath,
                                            publicKey: account.publicKey,
                                            extendedPublicKey: account.extendedPublicKey)
        }
        try save(wallet: wallet, isUpdate: true)
    }

    private func update(wallet: WalletContainer, password: String, newPassword: String, newName: String) throws {
        guard let index = wallets.firstIndex(of: wallet) else { throw KeyStore.Error.accountNotFound }
        guard var privateKeyData = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw KeyStore.Error.invalidPassword }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        let enabledAccounts = wallet.accounts
        let reimportedCoin: CoinType

        if let mnemonic = checkMnemonic(privateKeyData),
           let key = StoredKey.importHDWallet(mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: defaultCoin) {
            reimportedCoin = defaultCoin
            wallets[index].key = key
        } else {
            let privateKeyCoin = enabledAccounts.first?.coin ?? defaultCoin
            guard let key = StoredKey.importPrivateKey(privateKey: privateKeyData, name: newName, password: Data(newPassword.utf8), coin: privateKeyCoin) else {
                throw KeyStore.Error.invalidKey
            }
            reimportedCoin = privateKeyCoin
            wallets[index].key = key
        }

        wallets[index].key.removeAccountForCoin(coin: reimportedCoin)
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
        if let index = wallets.firstIndex(of: wallet) {
            wallets[index] = wallet
        }
        postWalletsChangedNotification()
    }

    private func postWalletsChangedNotification() {
        WalletStoreSync.postLocalAndExternalChange()
    }

    private func startObservingExternalChanges() {
        guard !isObservingExternalChanges else { return }
        isObservingExternalChanges = true
        WalletStoreSync.startObserving(self, selector: #selector(externalWalletStoreChanged(_:)))
    }

    @objc private func externalWalletStoreChanged(_ notification: Notification) {
        guard WalletStoreSync.isExternalChange(notification) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reloadWalletsFromKeychain()
            WalletsMetadataService.reload()
            WalletStoreSync.postLocalChange()
        }
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
        return getPrivateKey(walletId: wallet.id, account: account)
    }

    func getPrivateKey(walletId: String, account: Account) -> PrivateKey? {
        guard let password = Keychain.shared.password,
              let wallet = currentWallet(id: walletId)
        else { return nil }
        guard wallet.hasAccountMatching(account) else { return nil }
        return try? wallet.privateKey(password: password, account: account)
    }

    func getPrivateKey(coin: CoinType, address: String) -> PrivateKey? {
        guard let (wallet, account) = getWalletAndAccount(coin: coin, address: address) else { return nil }
        return getPrivateKey(walletId: wallet.id, account: account)
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

extension WalletContainer {

    func hasAccountMatching(_ account: Account) -> Bool {
        let normalizedAddress = account.coin.normalizedAddress(account.address)
        return accounts.contains { currentAccount in
            currentAccount.coin == account.coin &&
            currentAccount.derivationPath == account.derivationPath &&
            account.coin.normalizedAddress(currentAccount.address) == normalizedAddress
        }
    }

}

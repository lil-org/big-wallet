// ∅ 2026 lil org
// Local wallet storage and account management.

import Foundation

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
        let privateKey: WalletPrivateKey
        let coin: WalletCoin
    }

    static let shared = WalletsManager()
    private static let previewAccountsPageSize = 11
    private static let solanaBase58SecretKeyLengthRange = 32...88
    private static let maxSolanaSecretKeyByteArrayStringLength = 1024
    private let keychain = Keychain.shared
    private let defaultCoin = WalletCoin.ethereum
    private let defaultMnemonicCoinDerivations: [(coin: WalletCoin, derivation: WalletDerivation)] = [
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
        if WalletCrypto.isValidMnemonic(mnemonic: trimmedInput) {
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
        if WalletCrypto.isValidMnemonic(mnemonic: trimmedInput) {
            return try importMnemonic(trimmedInput, name: name, encryptPassword: password)
        } else if let privateKeyImport = Self.privateKeyImport(from: trimmedInput) {
            return try importPrivateKey(privateKeyImport.privateKey, name: name, password: password, coin: privateKeyImport.coin, onlyToKeychain: false)
        } else if input.maybeJSON, let inputPassword = inputPassword, let json = input.data(using: .utf8) {
            return try importJSON(json, name: name, password: inputPassword, newPassword: password, coin: defaultCoin, onlyToKeychain: false)
        } else {
            throw Error.invalidInput
        }
    }

    func getSpecificAccount(coin: WalletCoin, address: String) -> SpecificWalletAccount? {
        return getWalletAndAccount(coin: coin, address: address).map { wallet, account in
            SpecificWalletAccount(walletId: wallet.id, account: account)
        }
    }

    func suggestedAccounts(coin: WalletCoin? = nil) -> [SpecificWalletAccount] {
        return suggestedAccounts(for: [coin ?? defaultCoin])
    }

    func suggestedAccounts(providers: Set<InpageProvider>) -> [SpecificWalletAccount] {
        guard !providers.isEmpty else { return [] }

        let coins = InpageProvider.allCases
            .filter(providers.contains)
            .compactMap(WalletCoin.correspondingToInpageProvider)
        return suggestedAccounts(for: coins)
    }

    func previewAccounts(wallet: WalletContainer, page: Int, coin: WalletCoin? = nil) throws -> [WalletAccount] {
        guard let password = keychain.password, let hdWallet = wallet.key.wallet(password: Data(password.utf8)) else { throw Error.keychainAccessFailure }
        return try previewAccounts(hdWallet: hdWallet, page: page, coin: coin)
    }

    func previewAccounts(hdWallet: WalletHDWallet, page: Int, coin: WalletCoin?) throws -> [WalletAccount] {
        guard let coin else {
            return try Self.collectPreviewAccounts(coins: defaultMnemonicCoins) { previewCoin in
                try previewAccounts(hdWallet: hdWallet, page: page, coin: previewCoin)
            }
        }

        switch coin {
        case .ethereum:
            guard let range = Self.previewAccountIndexRange(page: page) else { throw Error.failedToDeriveAccount }
            guard let accounts = hdWallet.ethereumPreviewAccounts(accountRange: range) else { throw Error.failedToDeriveAccount }
            return accounts
        case .solana:
            return try previewSolanaAccounts(hdWallet: hdWallet, page: page)
        }
    }

    static func collectPreviewAccounts(coins: [WalletCoin],
                                       previewAccountsForCoin: (WalletCoin) throws -> [WalletAccount]) throws -> [WalletAccount] {
        var accountGroups = [[WalletAccount]]()
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

    private static func interleaved(_ accountGroups: [[WalletAccount]]) -> [WalletAccount] {
        let totalCount = accountGroups.reduce(0) { $0 + $1.count }
        let maxCount = accountGroups.map { $0.count }.max() ?? 0
        var accounts = [WalletAccount]()
        accounts.reserveCapacity(totalCount)

        for index in 0..<maxCount {
            for group in accountGroups where index < group.count {
                accounts.append(group[index])
            }
        }

        return accounts
    }

    private func createWallet(name: String, password: String) throws -> WalletContainer {
        guard let key = WalletStoredKey(name: name, password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidKey }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: password)
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    private func importJSON(_ json: Data, name: String, password: String, newPassword: String, coin: WalletCoin, onlyToKeychain: Bool) throws -> WalletContainer {
        guard let key = WalletStoredKey.importJSON(json: json) else { throw WalletKeyStoreError.invalidKey }
        guard var data = key.decryptPrivateKey(password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidPassword }
        defer { data.resetBytes(in: 0..<data.count) }
        if let mnemonic = checkMnemonic(data) { return try self.importMnemonic(mnemonic, name: name, encryptPassword: newPassword) }
        guard let privateKey = WalletPrivateKey(data: data) else { throw WalletKeyStoreError.invalidKey }
        return try self.importPrivateKey(privateKey, name: name, password: newPassword, coin: coin, onlyToKeychain: onlyToKeychain)
    }

    private func checkMnemonic(_ data: Data) -> String? {
        guard let mnemonic = String(data: data, encoding: .ascii), WalletCrypto.isValidMnemonic(mnemonic: mnemonic) else { return nil }
        return mnemonic
    }

    private func importPrivateKey(_ privateKey: WalletPrivateKey, name: String, password: String, coin: WalletCoin, onlyToKeychain: Bool) throws -> WalletContainer {
        let passwordData = Data(password.utf8)
        guard let newKey = privateKey.withData({
            WalletStoredKey.importPrivateKey(privateKey: $0, name: name, password: passwordData, coin: coin)
        }) else { throw WalletKeyStoreError.invalidKey }
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
        guard let key = WalletStoredKey.importHDWallet(mnemonic: mnemonic, name: name, password: Data(encryptPassword.utf8), coin: defaultCoin) else { throw WalletKeyStoreError.invalidMnemonic }
        let id = makeNewWalletId()
        let wallet = WalletContainer(id: id, key: key)
        try addDefaultMnemonicAccounts(to: wallet, password: encryptPassword)
        wallets.append(wallet)
        try save(wallet: wallet, isUpdate: false)
        return wallet
    }

    func exportPrivateKey(wallet: WalletContainer, account: WalletAccount? = nil) throws -> String {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let account = account ?? wallet.accounts.first else { throw WalletKeyStoreError.accountNotFound }
        let privateKey = try wallet.privateKey(password: password, account: account)
        return Self.privateKeyExportString(privateKey: privateKey, coin: account.coin)
    }

    func exportPrivateKey(walletId: String, account: WalletAccount? = nil) throws -> String {
        guard let wallet = currentWallet(id: walletId) else { throw WalletKeyStoreError.accountNotFound }
        if let account {
            guard wallet.hasAccountMatching(account) else { throw WalletKeyStoreError.accountNotFound }
        }
        return try exportPrivateKey(wallet: wallet, account: account)
    }

    static func privateKeyExportString(privateKey: WalletPrivateKey, coin: WalletCoin) -> String {
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

    private static func ethereumPrivateKeyImport(from input: String) -> WalletPrivateKey? {
        guard var privateKeyData = WalletCrypto.hexData(string: input),
              WalletCrypto.isValidPrivateKeyData(data: privateKeyData, coin: .ethereum)
        else { return nil }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        return WalletPrivateKey(data: privateKeyData)
    }

    private static func solanaPrivateKeyImport(from input: String) -> WalletPrivateKey? {
        if solanaBase58SecretKeyLengthRange.contains(input.count),
           let secretKey = WalletCrypto.base58Decode(string: input) {
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
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            let byteValue = number.doubleValue
            guard byteValue.rounded() == byteValue,
                  byteValue >= Double(UInt8.min),
                  byteValue <= Double(UInt8.max)
            else { return nil }
            secretKey.append(UInt8(byteValue))
        }

        return secretKey
    }

    private static func solanaPrivateKeyImport(secretKey: Data) -> WalletPrivateKey? {
        var secretKeyData = secretKey
        defer { secretKeyData.resetBytes(in: 0..<secretKeyData.count) }

        switch secretKeyData.count {
        case 32:
            guard WalletCrypto.isValidPrivateKeyData(data: secretKeyData, coin: .solana) else { return nil }
            return WalletPrivateKey(data: secretKeyData)
        case 64:
            var privateKeyData = Data(secretKeyData.prefix(32))
            defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
            guard WalletCrypto.isValidPrivateKeyData(data: privateKeyData, coin: .solana),
                  let privateKey = WalletPrivateKey(data: privateKeyData)
            else { return nil }

            let expectedPublicKey = privateKey.publicKeyData(coin: .solana)
            let exportedPublicKey = Data(secretKeyData.suffix(32))
            return exportedPublicKey == expectedPublicKey ? privateKey : nil
        default:
            return nil
        }
    }

    private static func solanaSecretKeyExportString(privateKey: WalletPrivateKey) -> String {
        return privateKey.withData { privateKeyData in
            var secretKey = privateKeyData
            defer { secretKey.resetBytes(in: 0..<secretKey.count) }

            if secretKey.count == 32 {
                secretKey.append(privateKey.publicKeyData(coin: .solana))
            }

            return WalletCrypto.base58Encode(data: secretKey)
        }
    }

    private static func hexPrivateKeyExportString(privateKey: WalletPrivateKey) -> String {
        return privateKey.withData { WalletCrypto.hexString(data: $0) }
    }

    func exportMnemonic(wallet: WalletContainer) throws -> String {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let mnemonic = wallet.key.decryptMnemonic(password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidPassword }
        return mnemonic
    }

    func exportMnemonic(walletId: String) throws -> String {
        guard let wallet = currentWallet(id: walletId) else { throw WalletKeyStoreError.accountNotFound }
        return try exportMnemonic(wallet: wallet)
    }

    func update(wallet: WalletContainer, newPassword: String) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        try update(wallet: wallet, password: password, newPassword: newPassword, newName: wallet.key.name)
    }

    func delete(wallet: WalletContainer) throws {
        guard let password = keychain.password else { throw Error.keychainAccessFailure }
        guard let index = wallets.firstIndex(of: wallet) else { throw WalletKeyStoreError.accountNotFound }
        guard var privateKey = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidKey }
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
        guard let data = keychain.getWalletData(id: id), let key = WalletStoredKey.importJSON(json: data) else { return nil }
        return WalletContainer(id: id, key: key)
    }

    func update(wallet: WalletContainer, enabledAccounts: [WalletAccount]) throws {
        guard let currentWallet = currentWallet(id: wallet.id) else { throw WalletKeyStoreError.accountNotFound }

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

    func update(wallet: WalletContainer, removeAccounts toRemove: [WalletAccount]) throws {
        guard let currentWallet = currentWallet(id: wallet.id) else { throw WalletKeyStoreError.accountNotFound }

        let keysToRemove = Set(toRemove.map { $0.previewAccountKey })
        let remainingAccounts = currentWallet.accounts.filter { !keysToRemove.contains($0.previewAccountKey) }
        try replaceAccounts(in: currentWallet, with: remainingAccounts)
    }

    private func replaceAccounts(in wallet: WalletContainer, with accounts: [WalletAccount]) throws {
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
        guard let index = wallets.firstIndex(of: wallet) else { throw WalletKeyStoreError.accountNotFound }
        guard var privateKeyData = wallet.key.decryptPrivateKey(password: Data(password.utf8)) else { throw WalletKeyStoreError.invalidPassword }
        defer { privateKeyData.resetBytes(in: 0..<privateKeyData.count) }
        let previousKey = wallet.key
        let enabledAccounts = wallet.accounts
        let reimportedCoin: WalletCoin

        if let mnemonic = checkMnemonic(privateKeyData),
           let key = WalletStoredKey.importHDWallet(mnemonic: mnemonic, name: newName, password: Data(newPassword.utf8), coin: defaultCoin) {
            reimportedCoin = defaultCoin
            wallets[index].key = key
        } else {
            let privateKeyCoin = enabledAccounts.first?.coin ?? defaultCoin
            guard let key = WalletStoredKey.importPrivateKey(privateKey: privateKeyData, name: newName, password: Data(newPassword.utf8), coin: privateKeyCoin) else {
                throw WalletKeyStoreError.invalidKey
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
        wallets[index].key.copyUnsupportedAccounts(from: previousKey)

        try save(wallet: wallets[index], isUpdate: true)
    }

    private func save(wallet: WalletContainer, isUpdate: Bool) throws {
        guard let data = wallet.key.exportJSON() else { throw WalletKeyStoreError.invalidPassword }
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
    private lazy var defaultMnemonicCoins: [WalletCoin] = {
        var previewCoins = [WalletCoin]()
        var seenCoins = Set<WalletCoin>()

        for derivation in defaultMnemonicCoinDerivations where seenCoins.insert(derivation.coin).inserted {
            previewCoins.append(derivation.coin)
        }

        return previewCoins
    }()

    private func suggestedAccounts(for coins: [WalletCoin]) -> [SpecificWalletAccount] {
        var suggestions = [SpecificWalletAccount]()
        var seenCoins = Set<WalletCoin>()

        for coin in coins {
            guard seenCoins.insert(coin).inserted else { continue }
            if let suggestion = firstSuggestedAccount(for: coin) {
                suggestions.append(suggestion)
            }
        }

        return suggestions
    }

    private func firstSuggestedAccount(for coin: WalletCoin) -> SpecificWalletAccount? {
        for wallet in wallets {
            if let account = wallet.accounts.first(where: { $0.coin == coin }) {
                return SpecificWalletAccount(walletId: wallet.id, account: account)
            }
        }
        return nil
    }

    private func addMnemonicAccounts(to wallet: WalletContainer,
                                     password: String,
                                     coinDerivations: [(coin: WalletCoin, derivation: WalletDerivation)]) throws {
        guard wallet.isMnemonic else { return }

        let hdWallet = wallet.key.wallet(password: Data(password.utf8))
        for (coin, derivation) in coinDerivations
        where !wallet.accounts.contains(where: { $0.coin == coin && $0.derivation == derivation }) {
            guard wallet.key.accountForCoinDerivation(coin: coin, derivation: derivation, wallet: hdWallet) != nil else {
                throw WalletKeyStoreError.invalidPassword
            }
        }
    }

    private func addDefaultMnemonicAccounts(to wallet: WalletContainer, password: String) throws {
        try addMnemonicAccounts(to: wallet, password: password, coinDerivations: defaultMnemonicCoinDerivations)
    }

    private static func previewAccountIndexRange(page: Int) -> Range<Int>? {
        guard page >= 0 else { return nil }

        let startResult = page.multipliedReportingOverflow(by: previewAccountsPageSize)
        guard !startResult.overflow else { return nil }

        let endResult = startResult.partialValue.addingReportingOverflow(previewAccountsPageSize)
        guard !endResult.overflow else { return nil }

        let end = endResult.partialValue
        guard UInt32(exactly: end - 1) != nil else { return nil }

        return startResult.partialValue..<end
    }

    private func previewSolanaAccounts(hdWallet: WalletHDWallet, page: Int) throws -> [WalletAccount] {
        guard let range = Self.previewAccountIndexRange(page: page) else { throw Error.failedToDeriveAccount }
        guard let accounts = hdWallet.solanaPreviewAccounts(accountRange: range) else { throw Error.failedToDeriveAccount }
        return accounts
    }

    private func makeNewWalletId() -> String {
        let uuid = UUID().uuidString
        let date = Date().timeIntervalSince1970
        let walletId = "\(uuid)-\(date)"
        return walletId
    }

}

extension WalletsManager {

    func getPrivateKey(wallet: WalletContainer, account: WalletAccount) -> WalletPrivateKey? {
        return getPrivateKey(walletId: wallet.id, account: account)
    }

    func getPrivateKey(walletId: String, account: WalletAccount) -> WalletPrivateKey? {
        guard let password = Keychain.shared.password,
              let wallet = currentWallet(id: walletId)
        else { return nil }
        guard wallet.hasAccountMatching(account) else { return nil }
        return try? wallet.privateKey(password: password, account: account)
    }

    func getPrivateKey(coin: WalletCoin, address: String) -> WalletPrivateKey? {
        guard let (wallet, account) = getWalletAndAccount(coin: coin, address: address) else { return nil }
        return getPrivateKey(walletId: wallet.id, account: account)
    }

    func getWalletAndAccount(coin: WalletCoin, address: String) -> (WalletContainer, WalletAccount)? {
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

    func hasAccountMatching(_ account: WalletAccount) -> Bool {
        let normalizedAddress = account.coin.normalizedAddress(account.address)
        return accounts.contains { currentAccount in
            currentAccount.coin == account.coin &&
            currentAccount.derivationPath == account.derivationPath &&
            account.coin.normalizedAddress(currentAccount.address) == normalizedAddress
        }
    }

}

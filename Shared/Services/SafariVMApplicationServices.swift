import WalletDomain
import WalletNetworking
#if BW_SAFARI_VM_TESTING
@testable import WalletAuthority
import WalletFlows
import CryptoKit
import Darwin
import Foundation

@MainActor
struct SafariVMApplicationServices {
    let runtime: AuthorityRuntime
    let authorization: any AlchemyAuthorizationProviding
    let prices: PriceService
#if os(macOS)
    let ethereum: EthereumTransactionPreparation
#endif

    static func make(configuration: AuthorityRuntimeConfiguration) -> SafariVMApplicationServices {
        let fixtures = SafariVMFixtures.shared
        do { try fixtures.initializeApplicationWallets() }
        catch { fatalError("Safari VM wallet initialization failed: \(error)") }
        let environment = SafariVMRuntimeEnvironment(configuration: configuration)
        var management = WalletManagementServices.Dependencies()
        management.makeKeychain = { fixtures.isLocal ? fixtures.keychain : Keychain() }
        management.makeMetadata = environment.metadata
        management.notifications = fixtures.isLocal ? WalletStoreChangeNotifications(
            postLocalChange: { WalletStoreSync.postLocalChange() },
            postMutation: { WalletStoreSync.postLocalAndExternalChange(defaultsAlreadySynchronized: true) },
            startObserving: { WalletStoreSync.startObserving($0, selector: $1) },
            stopObserving: { WalletStoreSync.stopObserving($0) },
            isExternalChange: { WalletStoreSync.isExternalChange($0) }
        ) : .live
        management.credentialAuthentication = fixtures.isLocal
            ? .init(canUseBiometrics: { false }, attemptBiometrics: { _ in .failed }) : .live
        let authorization = SafariVMRPCFixtureAuthorization()
        let prices = PriceService(fetchPrices: { ["ETH": 2_000] })
#if os(macOS)
        let rpc = EthereumRPC(authorizationProvider: authorization, authorizeRequest: environment.routing.authorize)
        let ethereum = EthereumTransactionPreparation(rpc: rpc, interpretTransaction: { _ in nil })
        let solana = SolanaRPCClient(urlSession: WalletHTTPSession.make(), authorizationProvider: authorization,
            messages: .init(failedToSend: Strings.failedToSend, blockhashNotFound: Strings.solanaBlockhashNotFound),
            authorizeRequest: environment.routing.authorize)
        let runtime = AuthorityRuntime(composition: environment.composition, management: management,
            solanaEndpoints: SolanaRPCClient.RPCConfiguration.bundled,
            broadcaster: SignedBroadcastClient(ethereum: EthereumBroadcastClient(rpc: rpc), solana: solana))
        return SafariVMApplicationServices(runtime: runtime,
            authorization: authorization, prices: prices, ethereum: ethereum)
#else
        management.makeVault = { _, _ in environment.vault() }
        management.makeIntegrityKeyStore = {
            if fixtures.isLocal { return SafariVMApprovalKeyStore() }
            return SafariApprovalIntegrityKeychainStore()
        }
        management.vaultHostDefaults = fixtures.isLocal ? environment.preferences : UserDefaultsPreferenceStorage.standard
        let runtime = AuthorityRuntime(composition: environment.composition, management: management)
        return SafariVMApplicationServices(runtime: runtime,
            authorization: authorization, prices: prices)
#endif
    }

    static func restoreWallet(wallets: WalletsManager, fixtures: SafariVMFixtures) async throws {
        guard !wallets.wallets.contains(where: { $0.id == "fixture-ethereum" }) else { return }
        let prepared = WalletRepository.PreparedCreation(walletID: "fixture-ethereum",
            data: try fixtures.originalWalletData(id: "fixture-ethereum"),
            credentialDigest: Data(SHA256.hash(data: Data("approval-fixture-password".utf8))))
        let repository = wallets.repository
#if os(iOS)
        _ = try await wallets.approvalVaultHost.performSourceMutation { willMutate in
            try await repository.saveNewWallet(prepared, willMutateSource: willMutate, validateAccess: {})
        }
#else
        _ = try await repository.saveNewWallet(prepared, willMutateSource: {}, validateAccess: {})
#endif
        guard await wallets.reloadFromStore() else { throw SafariVMFixtures.Failure.unavailable }
#if os(macOS)
        DistributedNotificationCenter.default().post(name: .walletStoreChanged, object: String(ProcessInfo.processInfo.processIdentifier))
#endif
    }

#if os(iOS)
    static func replaceVaultGeneration(services: ApplicationServices, fixtures: SafariVMFixtures) async throws -> (previous: String, current: String) {
        let preferences: any SharedPreferenceStorage = fixtures.isLocal ? SafariVMRuntimeEnvironment.preferenceStorage(fixtures) : UserDefaultsPreferenceStorage.standard
        let key = "SafariApprovalVault.hostPublicationMetadata.v1"
        func generation() throws -> UUID {
            guard let data = preferences.object(forKey: key) as? Data,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = object["generation"] as? String, let generation = UUID(uuidString: raw) else {
                throw SafariVMFixtures.Failure.unavailable
            }
            return generation
        }
        await services.waitForVaultReconciliation()
        let previous = try generation()
        try await services.invalidateVaultForTesting()
        let current = try generation()
        guard current != previous else { throw SafariVMFixtures.Failure.unavailable }
        return (previous.uuidString.lowercased(), current.uuidString.lowercased())
    }
#endif

    static func replaceCustomNetwork(chainID: Int, rpcURL: URL, services: ApplicationServices, fixtures: SafariVMFixtures) throws {
        let container = fixtures.isLocal ? fixtures.root : AuthorityStorageConfiguration.application.containerURL
        let storage = SafariVMCustomNetworks(preferences: SafariVMRuntimeEnvironment.preferenceStorage(fixtures), containerURL: container)
        try storage.replace(chainID: chainID, rpcURL: rpcURL)
        services.invalidateNetworkCache()
        CustomNetworkChangeNotification.post()
    }

}

@MainActor
final class SafariVMMutations {
    static let shared = SafariVMMutations()
    private var isProcessing = false

    func processPending() async {
        await SafariVMLockProbe.shared.contendIfRequested()
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        let fixtures = SafariVMFixtures.shared
        do {
            guard let mutation = try fixtures.claimMutation() else { return }
            let context = SafariVMFixtures.Operation(requestID: nil, scenarioID: mutation.scenario.id, iteration: mutation.scenario.iteration)
            let result: Result<[String: String], any Error> = await SafariVMFixtures.$operation.withValue(context) {
                do { return .success(try await perform(mutation, fixtures: fixtures)) }
                catch { return .failure(error) }
            }
            fixtures.completeMutation(mutation, result: result)
        } catch {
            fixtures.event("mutationRejected", metadata: ["error": String(describing: error)])
        }
    }

    private func perform(_ mutation: SafariVMFixtures.Mutation, fixtures: SafariVMFixtures) async throws -> [String: String] {
        let wallets = ApplicationServices.shared.wallets
        guard await wallets.start() else { throw SafariVMFixtures.Failure.unavailable }
        switch mutation.operation {
        case .removeEthereumAccount:
            guard let wallet = wallets.wallets.first(where: { $0.id == "fixture-ethereum" }),
                  wallet.accounts.count == 1, wallet.accounts[0].coin == .ethereum else { throw SafariVMFixtures.Failure.invalidFixture }
            let credentials = ApplicationServices.shared.credentials
            let challenge = credentials.makeWalletAccessChallenge()
            guard let grant = try credentials.verify(password: "approval-fixture-password", challenge: challenge),
                  let access = credentials.accessSession(authorization: grant) else { throw SafariVMFixtures.Failure.unavailable }
            defer { access.invalidate() }
            try await wallets.delete(wallet: wallet, access: access)
        case .restoreEthereumAccount:
            try await SafariVMApplicationServices.restoreWallet(wallets: wallets, fixtures: fixtures)
        case .replaceVaultGeneration:
#if os(iOS)
            let generations = try await SafariVMApplicationServices.replaceVaultGeneration(services: ApplicationServices.shared, fixtures: fixtures)
            return ["previousGeneration": generations.previous, "generation": generations.current]
#else
            throw SafariVMFixtures.Failure.invalidFixture
#endif
        case .replaceCustomNetwork:
            guard let chainID = mutation.chainId, let rawURL = mutation.rpcURL else { throw SafariVMFixtures.Failure.invalidFixture }
            let rpcURL = try fixtures.validateMutationRPCURL(rawURL)
            try SafariVMApplicationServices.replaceCustomNetwork(chainID: chainID, rpcURL: rpcURL,
                services: ApplicationServices.shared, fixtures: fixtures)
        }
#if os(iOS)
        await ApplicationServices.shared.waitForVaultReconciliation()
#endif
        return [:]
    }
}

extension SafariVMFixtures {
    fileprivate func initializeApplicationWallets() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              ["org.lil.wallet", "org.lil.wallet.ambient"].contains(Bundle.main.bundleIdentifier ?? "") else {
            throw Failure.invalidFixture
        }
        guard activationPreparation == nil else { return }
        try initializeWallets()
        if !isLocal { try initializeAppleWallets() }
    }

    private func initializeWallets() throws {
        try withStorage {
            let file = root.appendingPathComponent("wallets.plist")
            let exists: Bool
            do { _ = try Self.read(file, maximum: 8 * 1_024 * 1_024); exists = true }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { exists = false }
            if exists {
                _ = try Self.read(root.appendingPathComponent("original-wallets.plist"), maximum: 8 * 1_024 * 1_024)
                return
            }
            let password = SecretBytes(utf8: "approval-fixture-password")
            defer { password.invalidate() }
            var records = ["org.lil.wallet.password": Data("approval-fixture-password".utf8)]
            for (name, coin, seed) in [("fixture-ethereum", WalletCoin.ethereum, UInt8(1)), ("fixture-solana", .solana, UInt8(2))] {
                guard let privateKey = WalletPrivateKey(data: Data(repeating: seed, count: 32)) else { throw Failure.invalidFixture }
                defer { privateKey.invalidate() }
                guard let key = WalletStoredKey.importPrivateKey(privateKey: privateKey, name: name, password: password, coin: coin) else { throw Failure.invalidFixture }
                let wallet = WalletContainer(id: name, key: key)
                _ = try wallet.getAccount(password: password, coin: coin)
                guard let data = key.exportJSON() else { throw Failure.invalidFixture }
                records["org.lil.wallet.wallet." + name] = data
            }
            let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
            guard let stored = WalletStoredKey.importHDWallet(mnemonic: mnemonic, name: "fixture-multicoin", password: password, coin: .ethereum),
                  let hd = WalletHDWallet(mnemonic: mnemonic, passphrase: ""),
                  let ethereum = hd.ethereumPreviewAccounts(accountRange: 0..<2),
                  let solana = hd.solanaPreviewAccounts(accountRange: 0..<2) else { throw Failure.invalidFixture }
            let wallet = WalletContainer(id: "fixture-multicoin", key: stored)
            for account in wallet.accounts { stored.removeAccountForCoinDerivationPath(coin: account.coin, derivationPath: account.derivationPath) }
            for account in ethereum + solana {
                stored.addAccountDerivation(address: account.address, coin: account.coin, derivation: account.derivation,
                    derivationPath: account.derivationPath, publicKey: account.publicKey, extendedPublicKey: account.extendedPublicKey)
            }
            guard let data = stored.exportJSON() else { throw Failure.invalidFixture }
            records["org.lil.wallet.wallet.fixture-multicoin"] = data
            try saveDataRecords(records, name: "original-wallets.plist")
            try saveDataRecords(records, name: "wallets.plist")
        }
    }

    private func initializeAppleWallets() throws {
        let walletCount = try withStorage {
            let keychain = Keychain()
            let password = "approval-fixture-password"
            let expectedIDs = Set(["fixture-ethereum", "fixture-solana", "fixture-multicoin"])
            let existingIDs = Set(try keychain.readAllWalletIDs())
            guard existingIDs.isSubset(of: expectedIDs) else { throw Failure.invalidFixture }
            if let existingPassword = try keychain.readPasswordSecret() {
                defer { existingPassword.invalidate() }
                guard try existingPassword.withUnsafeBytes({ $0.elementsEqual(password.utf8) }) else { throw Failure.invalidFixture }
            } else {
                guard existingIDs.isEmpty else { throw Failure.invalidFixture }
                _ = try keychain.createPasswordIfMissing(password, beforeInsert: {})
                guard let stored = try keychain.readPasswordSecret() else { throw Failure.invalidFixture }
                defer { stored.invalidate() }
                guard try stored.withUnsafeBytes({ $0.elementsEqual(password.utf8) }) else { throw Failure.invalidFixture }
            }
            let records = try dataRecords("wallets.plist")
            let initialized = try dataRecords("apple-wallet-bootstrap.plist")["complete"] != nil
            for id in expectedIDs.sorted() {
                guard let expected = records["org.lil.wallet.wallet." + id],
                      let expectedKey = WalletStoredKey.importJSON(json: expected) else { throw Failure.invalidFixture }
                if let existing = try keychain.readWalletData(id: id) {
                    guard let key = WalletStoredKey.importJSON(json: existing), key.isMnemonic == expectedKey.isMnemonic else { throw Failure.invalidFixture }
                    let current = WalletContainer(id: id, key: key)
                    let intended = WalletContainer(id: id, key: expectedKey)
                    let accounts = Set(current.accounts.map { WalletAccountDescriptor(walletID: id, account: $0) })
                    let expectedAccounts = Set(intended.accounts.map { WalletAccountDescriptor(walletID: id, account: $0) })
                    guard accounts == expectedAccounts else { throw Failure.invalidFixture }
                    let credential = SecretBytes(utf8: password)
                    defer { credential.invalidate() }
                    let actual = key.isMnemonic ? key.decryptMnemonicSecret(password: credential) : key.decryptPrivateKey(password: credential)
                    let intendedSecret = key.isMnemonic ? expectedKey.decryptMnemonicSecret(password: credential) : expectedKey.decryptPrivateKey(password: credential)
                    defer { actual?.invalidate(); intendedSecret?.invalidate() }
                    guard let actual, let intendedSecret,
                          try actual.withUnsafeBytes({ left in try intendedSecret.withUnsafeBytes { left.elementsEqual($0) } }) else { throw Failure.invalidFixture }
                } else if !initialized {
                    try keychain.saveWallet(id: id, data: expected)
                }
            }
            try saveDataRecords(["complete": Data([1])], name: "apple-wallet-bootstrap.plist")
            return try keychain.readAllWalletIDs().count
        }
        event("fixtureWalletsReady", metadata: ["storage": "production", "walletCount": walletCount])
    }

}
#endif

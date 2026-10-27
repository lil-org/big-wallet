import CryptoKit
import Foundation
import Security
import WalletDomain
@testable import WalletAuthority

@MainActor
final class UpgradeVerification {
    private let fixture: URL
    private let state: URL
    private let expectations: FixtureExpectations
    private let fixtureStorage: FixtureStorage
    private let attempts = NetworkAttempts()
    private var activeStorage: FixtureStorage?
    private(set) var report: ConsumerReport
    private let restoredPassword = "wallet-upgrade-restored-password"
    private let addedName = "Created by current consumer"

    init(mode: String, fixture: URL, state: URL) throws {
        self.fixture = fixture
        self.state = state
        expectations = try JSONDecoder().decode(FixtureExpectations.self,
            from: readRegularFile(fixture.appendingPathComponent("expectations.json")))
        fixtureStorage = try FixtureStorage(root: fixture)
        let hashes = try StorageHashes(root: state)
        report = ConsumerReport(mode: mode, storage: .init(before: hashes, after: hashes))
    }

    func run() async throws {
        try expectations.validate()
        report.checks.append("baseline")
        switch report.mode {
        case "verify-existing": try await verifyExisting()
        case "mutate-existing": try await mutateExisting()
        case "verify-reopened": try await verifyReopened()
        case "restore": try await restore()
        case "verify-restored": try await verifyRestored()
        case "failures": try await failures()
        default: throw UpgradeFailure.invalid("Unknown consumer mode")
        }
        try activeStorage?.check()
        try require(attempts.count == 0, "Consumer attempted external work")
        report.status = "passed"
        try finishReport()
    }

    func failed(_ error: Error) {
        report.status = "failed"
        report.error = String(describing: error)
        try? finishReport()
    }

    private func finishReport() throws {
        report.storage.after = try StorageHashes(root: state)
        report.networkAttempts = attempts.count
        report.keychainWrites = activeStorage?.keychainWrites ?? 0
        report.preferenceWrites = activeStorage?.preferenceWrites ?? 0
    }

    private func services(permitsEmpty: Bool = false) throws -> ConsumerServices {
        let storage = try FixtureStorage(root: state, permitsEmpty: permitsEmpty)
        activeStorage = storage
        return try ConsumerServices(storage: storage, fixtureStorage: fixtureStorage, attempts: attempts)
    }

    private func load(_ services: ConsumerServices, password: String) async throws {
        try require(try services.credentials.passwordState() == .present, "Stored credential is missing")
        let session = try services.authenticate(password: password)
        defer { session.invalidate() }
        try require(services.credentials.validateAccess(session), "Stored credential authentication is stale")
        let loaded = await services.wallets.start()
        try require(loaded, "Stored wallets could not be loaded")
        report.checks.append("password-authentication")
        updateCounts(services)
    }

    private func updateCounts(_ services: ConsumerServices) {
        report.counts.wallets = services.wallets.wallets.count
        report.counts.accounts = services.wallets.wallets.reduce(0) { $0 + $1.accounts.count }
    }

    private func verifyExisting() async throws {
        let services = try services()
        try services.storage.validateNamespaces()
        report.checks.append("storage-namespaces")
        try await load(services, password: expectations.fixturePassword)
        try originalWallets(services, allowsAdded: false)
        report.checks.append("wallet-identity")
        try originalMetadata(services)
        report.checks.append("account-metadata")
        try networkSettings(services.preferences)
        report.checks.append("network-settings")
        try historicalSignatures()
        report.checks.append("historical-signatures")
        try await exports(services, mappings: [:], password: expectations.fixturePassword)
        report.checks.append("exports")
        try await signatures(services, mappings: [:], password: expectations.fixturePassword)
        report.checks.append("approved-signatures")
        try unchanged(services)
    }

    private func mutateExisting() async throws {
        let services = try services()
        try await load(services, password: expectations.fixturePassword)
        try originalWallets(services, allowsAdded: false)
        let original = try ethereumWallet()
        let added = try await services.wallets.addWallet(input: original.accounts[0].privateKeyBackup, inputPassword: nil)
        try require(added.id != original.walletID && !expectations.wallets.contains { $0.walletID == added.id }, "Import reused a historical wallet identifier")
        try verifyAccounts(added, expected: original)
        report.checks.append("wallet-created")
        services.metadata.saveWalletName(addedName, wallet: added)
        try services.storage.check()
        try require(services.metadata.getWalletName(wallet: added) == addedName, "Current wallet name was not persisted")
        report.checks.append("metadata-written")
        try originalWallets(services, allowsAdded: true)
        try originalMetadata(services)
        try originalRecordsPreserved(services.storage)
        report.checks.append("old-sources-preserved")
        let mapping = WalletMapping(version: 1, fixtureID: expectations.fixtureID, baseline: expectations.baseline,
            walletIDs: ["added-ethereum": added.id], password: expectations.fixturePassword, addedWalletName: addedName)
        try writeJSON(mapping, to: state.appendingPathComponent("mutation.json"))
        report.checks.append("mutation-record-written")
        updateCounts(services)
    }

    private func verifyReopened() async throws {
        let mapping = try readMapping("mutation.json")
        try require(mapping.password == expectations.fixturePassword && mapping.addedWalletName == addedName &&
            Set(mapping.walletIDs.keys) == Set(["added-ethereum"]), "Invalid mutation record")
        let services = try services()
        try await load(services, password: mapping.password)
        try originalWallets(services, allowsAdded: true)
        try originalMetadata(services)
        try networkSettings(services.preferences)
        try originalRecordsPreserved(services.storage)
        report.checks.append("original-wallets")
        guard let id = mapping.walletIDs["added-ethereum"], let added = services.wallets.currentWallet(id: id) else {
            throw UpgradeFailure.invalid("Created wallet did not survive restart")
        }
        let original = try ethereumWallet()
        try verifyAccounts(added, expected: original)
        try require(services.wallets.wallets.last?.id == added.id, "New wallet did not retain its creation order")
        report.checks.append("created-wallet")
        try require(services.metadata.getWalletName(wallet: added) == mapping.addedWalletName, "Created wallet name did not survive restart")
        report.checks.append("mutation-metadata")
        try await exports(services, mappings: [:], password: mapping.password)
        let extra = try await services.export(wallet: added, account: added.accounts[0], password: mapping.password, mnemonic: false)
        try require(extra == original.accounts[0].privateKeyBackup, "Created wallet export changed after restart")
        report.counts.exports += 1
        report.checks.append("exports")
        try await signatures(services, mappings: [:], password: mapping.password)
        try await services.sign(account: .init(walletId: added.id, account: added.accounts[0]), expected: original.accounts[0],
            password: mapping.password, solanaMessage: hexData(expectations.solanaMessageHex))
        report.counts.approvedSignatures += 1
        report.checks.append("approved-signatures")
        try unchanged(services)
    }

    private func restore() async throws {
        try require(report.storage.before.keychainSHA256 == nil && report.storage.before.preferencesSHA256 == nil,
            "Restore requires empty storage")
        try require(try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty, "Restore directory is not empty")
        report.checks.append("empty-store")
        let services = try services(permitsEmpty: true)
        try services.storage.initializeEmptyPreferences()
        try require(restoredPassword != expectations.fixturePassword, "Restore password must be different")
        let creation = try await services.credentials.createPasswordIfMissing(restoredPassword)
        try require(creation == .created, "Replacement password was not created")
        let access = try services.authenticate(password: restoredPassword)
        access.invalidate()
        report.checks.append("replacement-password")
        var mapping = [String: String]()
        for original in expectations.wallets {
            let input = original.mnemonicBackup ?? original.accounts[0].privateKeyBackup
            let wallet = try await services.wallets.addWallet(input: input, inputPassword: nil)
            try require(wallet.id != original.walletID, "Restoration reused a historical wallet identifier")
            mapping[original.fixtureID] = wallet.id
        }
        report.checks.append("backups-imported")
        for original in expectations.wallets where original.isMnemonic {
            guard let id = mapping[original.fixtureID], let wallet = services.wallets.currentWallet(id: id) else {
                throw UpgradeFailure.invalid("Restored mnemonic wallet is missing")
            }
            let preview = try await services.wallets.previewSession(wallet: wallet)
            defer { preview.invalidate() }
            let candidates = try await preview.previewAccounts(page: 0)
            let selected = try original.accounts.map { expected -> WalletAccount in
                guard let account = candidates.first(where: { $0.coin.rawValue == expected.coin && $0.derivationPath == expected.derivationPath }) else {
                    throw UpgradeFailure.invalid("Historical derivation path is absent from current preview")
                }
                return account
            }
            try await services.wallets.update(wallet: wallet, enabledAccounts: selected)
        }
        report.checks.append("hd-paths-restored")
        try restoredIdentities(services, mapping: mapping)
        report.checks.append("restored-identities")
        try await exports(services, mappings: mapping, password: restoredPassword)
        report.checks.append("exports")
        try await signatures(services, mappings: mapping, password: restoredPassword)
        report.checks.append("approved-signatures")
        try writeJSON(WalletMapping(version: 1, fixtureID: expectations.fixtureID, baseline: expectations.baseline,
            walletIDs: mapping, password: restoredPassword, addedWalletName: nil), to: state.appendingPathComponent("restore-map.json"))
        report.checks.append("restore-map-written")
        updateCounts(services)
    }

    private func verifyRestored() async throws {
        let services = try services()
        try await load(services, password: restoredPassword)
        let mapping = try readMapping("restore-map.json")
        try require(mapping.password == restoredPassword && mapping.addedWalletName == nil, "Invalid restore password mapping")
        report.checks.append("restore-map")
        try restoredIdentities(services, mapping: mapping.walletIDs)
        report.checks.append("restored-identities")
        try await exports(services, mappings: mapping.walletIDs, password: restoredPassword)
        report.checks.append("exports")
        try await signatures(services, mappings: mapping.walletIDs, password: restoredPassword)
        report.checks.append("approved-signatures")
        try unchanged(services)
    }

    private func originalWallets(_ services: ConsumerServices, allowsAdded: Bool) throws {
        let wallets = services.wallets.wallets
        try require(wallets.count == expectations.wallets.count + (allowsAdded ? 1 : 0), "Current wallet inventory differs from fixture")
        try require(Array(wallets.prefix(expectations.wallets.count)).map(\.id) == expectations.wallets.map(\.walletID),
            "Historical wallet identity or creation order changed")
        for expected in expectations.wallets {
            guard let wallet = services.wallets.currentWallet(id: expected.walletID),
                  let data = try services.storage.walletData(id: expected.walletID) else { throw UpgradeFailure.invalid("Historical wallet is missing") }
            try require(sha256(data) == expected.walletDataSHA256, "Historical wallet ciphertext changed")
            try verifyAccounts(wallet, expected: expected)
        }
    }

    private func verifyAccounts(_ wallet: WalletSnapshot, expected: FixtureExpectations.Wallet) throws {
        try require(wallet.isMnemonic == expected.isMnemonic && wallet.accounts.count == expected.accounts.count, "Wallet kind or account count changed")
        for (account, old) in zip(wallet.accounts, expected.accounts) {
            try require(account.coin.rawValue == old.coin && account.derivation.rawValue == old.derivation &&
                account.derivationPath == old.derivationPath && account.address == old.address &&
                account.publicKey == old.publicKey && account.extendedPublicKey == old.extendedPublicKey,
                "Historical account metadata changed")
        }
    }

    private func originalMetadata(_ services: ConsumerServices) throws {
        for expected in expectations.wallets {
            guard let wallet = services.wallets.currentWallet(id: expected.walletID) else { throw UpgradeFailure.invalid("Historical metadata wallet is missing") }
            try require(services.metadata.getWalletName(wallet: wallet) == expected.name, "Historical wallet name changed")
            for (account, old) in zip(wallet.accounts, expected.accounts) {
                try require(services.metadata.getAccountName(walletId: wallet.id, account: account) == old.name, "Historical account name changed")
            }
        }
    }

    private func originalRecordsPreserved(_ storage: FixtureStorage) throws {
        try require(try storage.preservesOriginalRecords(from: fixtureStorage), "Current mutation changed original Keychain attributes or data")
        for expected in expectations.wallets {
            try require(try storage.walletData(id: expected.walletID) == fixtureStorage.walletData(id: expected.walletID),
                "Current mutation rewrote an original wallet")
        }
        try require(try storage.keychain.readPasswordData() == fixtureStorage.keychain.readPasswordData(),
            "Current mutation changed the original credential")
    }

    private func networkSettings(_ preferences: FixturePreferences) throws {
        guard case .loaded(let snapshot) = SharedDefaults.loadCustomNetworkSnapshotResult(from: preferences) else {
            throw UpgradeFailure.invalid("Historical network settings could not be decoded")
        }
        try require(snapshot.orderedEntries.count == expectations.networks.count, "Historical network inventory changed")
        for (entry, expected) in zip(snapshot.orderedEntries, expectations.networks) {
            let definition = entry.definition
            try require(entry.chainId == expected.chainID && entry.rpcURL.absoluteString == expected.rpcURL &&
                definition.chainId == expected.chainIDHex && definition.chainName == expected.name &&
                definition.nativeCurrency.name == expected.currencyName && definition.nativeCurrency.symbol == expected.symbol &&
                definition.nativeCurrency.decimals == expected.decimals && definition.rpcUrls == expected.rpcURLs &&
                definition.blockExplorerUrls == expected.blockExplorerURLs, "Historical network settings changed")
        }
    }

    private func historicalSignatures() throws {
        for wallet in expectations.wallets {
            for account in wallet.accounts {
                let publicKey = try hexData(account.signing.publicKeyHex)
                let signature = try hexData(account.signing.signatureHex)
                if account.coin == 60 {
                    let address = WalletCrypto.recoverEthereumAddress(signature: signature, messageHash: try hexData(expectations.ethereumDigestHex))
                    try require(address?.lowercased() == account.address.lowercased() &&
                        WalletCrypto.addressFromPublicKeyData(publicKey, coin: .ethereum).lowercased() == account.address.lowercased(),
                        "Historical Ethereum signature is invalid")
                } else {
                    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
                    try require(key.isValidSignature(signature, for: hexData(expectations.solanaMessageHex)) &&
                        WalletEncoding.base58Encode(publicKey) == account.address, "Historical Solana signature is invalid")
                }
            }
        }
    }

    private func exports(_ services: ConsumerServices, mappings: [String: String], password: String) async throws {
        for expected in expectations.wallets {
            let id = mappings[expected.fixtureID] ?? expected.walletID
            guard let wallet = services.wallets.currentWallet(id: id) else { throw UpgradeFailure.invalid("Export wallet is missing") }
            if let mnemonic = expected.mnemonicBackup {
                let exported = try await services.export(wallet: wallet, account: nil, password: password, mnemonic: true)
                try require(exported == mnemonic, "Mnemonic export differs from historical producer")
                report.counts.exports += 1
            }
            for (account, old) in zip(wallet.accounts, expected.accounts) {
                let exported = try await services.export(wallet: wallet, account: account, password: password, mnemonic: false)
                try require(exported == old.privateKeyBackup, "Private key export differs from historical producer")
                report.counts.exports += 1
            }
        }
    }

    private func signatures(_ services: ConsumerServices, mappings: [String: String], password: String) async throws {
        let message = try hexData(expectations.solanaMessageHex)
        for expected in expectations.wallets {
            let id = mappings[expected.fixtureID] ?? expected.walletID
            guard let wallet = services.wallets.currentWallet(id: id) else { throw UpgradeFailure.invalid("Signing wallet is missing") }
            for (account, old) in zip(wallet.accounts, expected.accounts) {
                try await services.sign(account: .init(walletId: id, account: account), expected: old, password: password, solanaMessage: message)
                report.counts.approvedSignatures += 1
            }
        }
    }

    private func restoredIdentities(_ services: ConsumerServices, mapping: [String: String]) throws {
        try require(Set(mapping.keys) == Set(expectations.wallets.map(\.fixtureID)) && Set(mapping.values).count == 3,
            "Restore mapping is incomplete")
        try require(services.wallets.wallets.map(\.id) == expectations.wallets.compactMap { mapping[$0.fixtureID] }, "Restored wallet order changed")
        for expected in expectations.wallets {
            guard let id = mapping[expected.fixtureID], let wallet = services.wallets.currentWallet(id: id) else {
                throw UpgradeFailure.invalid("Restored wallet is missing")
            }
            try require(id != expected.walletID, "Restoration reused a historical wallet identifier")
            try verifyAccounts(wallet, expected: expected)
            try require(services.metadata.getWalletName(wallet: wallet) == nil && wallet.accounts.allSatisfy {
                services.metadata.getAccountName(walletId: id, account: $0) == nil
            }, "Text backups unexpectedly restored names")
        }
        guard case .loaded(let networks) = SharedDefaults.loadCustomNetworkSnapshotResult(from: services.preferences) else {
            throw UpgradeFailure.invalid("Restored preferences are unreadable")
        }
        try require(networks.orderedEntries.isEmpty, "Text backups unexpectedly restored networks")
        updateCounts(services)
    }

    private func unchanged(_ services: ConsumerServices) throws {
        try require(try StorageHashes(root: state) == report.storage.before && services.storage.keychainWrites == 0 &&
            services.storage.preferenceWrites == 0, "Verification rewrote persisted source data")
        report.checks.append("unchanged-storage")
    }

    private func ethereumWallet() throws -> FixtureExpectations.Wallet {
        guard let wallet = expectations.wallets.first(where: { $0.fixtureID == "ethereum" }), wallet.accounts.count == 1 else {
            throw UpgradeFailure.invalid("Ethereum fixture wallet is missing")
        }
        return wallet
    }

    private func readMapping(_ name: String) throws -> WalletMapping {
        let mapping = try JSONDecoder().decode(WalletMapping.self, from: readRegularFile(state.appendingPathComponent(name)))
        try require(mapping.version == 1 && mapping.fixtureID == expectations.fixtureID && mapping.baseline == expectations.baseline,
            "Mapping belongs to another fixture")
        return mapping
    }

    private func failures() async throws {
        try require(try FileManager.default.contentsOfDirectory(atPath: state.path).isEmpty, "Failure directory is not empty")
        report.failureCases = []
        for name in ["wrong-password", "locked-read", "failed-add", "malformed-import"] {
            let root = state.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for file in ["keychain.plist", "preferences.plist"] {
                try FileManager.default.copyItem(at: fixture.appendingPathComponent(file), to: root.appendingPathComponent(file))
            }
            let before = try StorageHashes(root: root)
            let storage = try FixtureStorage(root: root)
            let services = try ConsumerServices(storage: storage, fixtureStorage: fixtureStorage, attempts: attempts)
            let loaded = await services.wallets.start()
            try require(loaded, "Failure fixture could not load")
            let originalWallets = services.wallets.wallets
            let rejected: Bool
            switch name {
            case "wrong-password":
                let challenge = services.credentials.makeWalletAccessChallenge()
                let password = expectations.fixturePassword + "-incorrect"
                let accessRejected = try services.credentials.verify(password: password, challenge: challenge) == nil
                guard let wallet = originalWallets.first else { throw UpgradeFailure.invalid("Missing export rejection wallet") }
                let exportChallenge = try await services.wallets.makeExportChallenge(wallet: wallet, account: wallet.accounts.first, kind: .privateKey)
                let exportRejected = try services.credentials.verify(password: password, challenge: exportChallenge) == nil
                rejected = accessRejected && exportRejected
            case "locked-read":
                storage.setFault(.lockedRead)
                do {
                    _ = try services.credentials.passwordState()
                    rejected = false
                } catch WalletCredentialError.failedToRead(errSecInteractionNotAllowed) {
                    rejected = true
                }
                let reloaded = await services.wallets.reloadFromStore()
                try require(!reloaded && services.wallets.wallets == originalWallets,
                    "Locked read discarded the last good wallet state")
            case "failed-add":
                storage.setFault(.failedAdd)
                do {
                    _ = try await services.wallets.addWallet(input: ethereumWallet().accounts[0].privateKeyBackup, inputPassword: nil)
                    rejected = false
                } catch WalletCredentialError.failedToSave(errSecIO) {
                    rejected = true
                }
            default:
                do {
                    _ = try await services.wallets.addWallet(input: "{\"crypto\":{}}", inputPassword: "incorrect")
                    rejected = false
                } catch {
                    rejected = true
                }
            }
            try require(rejected, "Negative fixture case unexpectedly succeeded")
            try storage.check()
            let after = try StorageHashes(root: root)
            try require(before == after && storage.keychainWrites == 0 && storage.preferenceWrites == 0,
                "Failure modified persisted source data")
            report.failureCases?.append(.init(name: name, rejected: true, before: before, after: after,
                keychainWrites: storage.keychainWrites, preferenceWrites: storage.preferenceWrites))
            report.checks.append(name + "-rejected")
            report.counts.wallets = originalWallets.count
            report.counts.accounts = originalWallets.reduce(0) { $0 + $1.accounts.count }
        }
        report.checks.append("failures-preserve-storage")
    }
}

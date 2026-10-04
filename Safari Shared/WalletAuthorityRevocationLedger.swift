import Foundation

struct WalletAuthorityRevocationLedger: Codable, Equatable, Sendable {
    struct Cursor: Codable, Equatable, Sendable {
        let epoch: UUID
        let sequence: Int
    }

    struct WalletRemoval: Codable, Equatable, Sendable {
        let walletID: String
        let sequence: Int
    }

    struct AccountRemoval: Codable, Equatable, Sendable {
        let account: WalletAccountDescriptor
        let sequence: Int
    }

    enum Error: Swift.Error, Sendable {
        case invalidRemoval
        case sequenceExhausted
    }

    let schemaVersion: Int
    let epoch: UUID
    private(set) var sequence: Int
    private(set) var walletRemovals: [WalletRemoval]
    private(set) var accountRemovals: [AccountRemoval]

    init(epoch: UUID) {
        schemaVersion = 1
        self.epoch = epoch
        sequence = 0
        walletRemovals = []
        accountRemovals = []
    }

    var cursor: Cursor {
        Cursor(epoch: epoch, sequence: sequence)
    }

    var isValid: Bool {
        guard schemaVersion == 1, sequence >= 0,
              Set(walletRemovals.map(\.walletID)).count == walletRemovals.count,
              Set(accountRemovals.map(\.account)).count == accountRemovals.count,
              walletRemovals.allSatisfy({
                  Self.validWalletID($0.walletID) && $0.sequence > 0 && $0.sequence <= sequence
              }),
              accountRemovals.allSatisfy({
                  $0.account.isValid && $0.sequence > 0 && $0.sequence <= sequence
              }) else { return false }
        let wallets = Dictionary(uniqueKeysWithValues: walletRemovals.map { ($0.walletID, $0.sequence) })
        guard max(walletRemovals.map(\.sequence).max() ?? 0,
                  accountRemovals.map(\.sequence).max() ?? 0) == sequence else { return false }
        return accountRemovals.allSatisfy {
            $0.sequence > (wallets[$0.account.walletID] ?? 0)
        }
    }

    @discardableResult
    mutating func record(_ removals: [WalletAuthorityRemoval]) throws -> Bool {
        var wallets = Set<String>()
        var accounts = Set<WalletAccountDescriptor>()
        for removal in removals {
            switch removal {
            case .wallet(let walletID):
                guard Self.validWalletID(walletID) else { throw Error.invalidRemoval }
                wallets.insert(walletID)
            case .accounts(let removed):
                guard removed.allSatisfy(\.isValid) else { throw Error.invalidRemoval }
                accounts.formUnion(removed)
            }
        }
        accounts = accounts.filter { !wallets.contains($0.walletID) }
        guard !wallets.isEmpty || !accounts.isEmpty else { return false }
        guard sequence < Int.max else { throw Error.sequenceExhausted }
        sequence += 1
        var latestWallets = Dictionary(uniqueKeysWithValues: walletRemovals.map { ($0.walletID, $0.sequence) })
        var latestAccounts = Dictionary(uniqueKeysWithValues: accountRemovals.filter {
            !wallets.contains($0.account.walletID)
        }.map { ($0.account, $0.sequence) })
        for walletID in wallets { latestWallets[walletID] = sequence }
        for account in accounts { latestAccounts[account] = sequence }
        walletRemovals = latestWallets.map {
            WalletRemoval(walletID: $0.key, sequence: $0.value)
        }.sorted { $0.walletID < $1.walletID }
        accountRemovals = latestAccounts.map {
            AccountRemoval(account: $0.key, sequence: $0.value)
        }.sorted { Self.accountPrecedes($0.account, $1.account) }
        return true
    }

    func removals(after appliedSequence: Int) -> [WalletAuthorityRemoval] {
        var removals = walletRemovals.filter { $0.sequence > appliedSequence }
            .sorted { $0.walletID < $1.walletID }
            .map { WalletAuthorityRemoval.wallet(id: $0.walletID) }
        let accounts = Set(accountRemovals.filter { $0.sequence > appliedSequence }.map(\.account))
        if !accounts.isEmpty { removals.append(.accounts(accounts)) }
        return removals
    }

    static func decode(_ data: Data) -> Self? {
        guard let ledger = try? PropertyListDecoder().decode(Self.self, from: data),
              ledger.isValid else { return nil }
        return ledger
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    private static func validWalletID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }

    private static func accountPrecedes(_ lhs: WalletAccountDescriptor, _ rhs: WalletAccountDescriptor) -> Bool {
        (lhs.walletID, lhs.coin.rawValue, lhs.normalizedAddress, lhs.derivationPath) <
            (rhs.walletID, rhs.coin.rawValue, rhs.normalizedAddress, rhs.derivationPath)
    }
}

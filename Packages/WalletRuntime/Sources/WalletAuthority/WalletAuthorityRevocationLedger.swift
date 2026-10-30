import WalletDomain
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
        case capacityExceeded
    }

    static let maximumEncodedBytes = 8 * 1_024 * 1_024
    static let maximumEntries = 65_536

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, epoch, sequence, walletRemovals, accountRemovals
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var wallets = try container.nestedUnkeyedContainer(forKey: .walletRemovals)
        var accounts = try container.nestedUnkeyedContainer(forKey: .accountRemovals)
        let walletCount = wallets.count ?? 0
        guard walletCount <= Self.maximumEntries,
              (accounts.count ?? 0) <= Self.maximumEntries - walletCount else {
            throw Error.capacityExceeded
        }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        epoch = try container.decode(UUID.self, forKey: .epoch)
        let decodedSequence = try container.decode(Int.self, forKey: .sequence)
        sequence = decodedSequence
        walletRemovals = try Self.decodeEntries(WalletRemoval.self, from: &wallets, limit: Self.maximumEntries) {
            Self.validWalletID($0.walletID) && $0.sequence > 0 && $0.sequence <= decodedSequence
        }
        accountRemovals = try Self.decodeEntries(
            AccountRemoval.self, from: &accounts, limit: Self.maximumEntries - walletRemovals.count
        ) {
            $0.account.isValid && $0.sequence > 0 && $0.sequence <= decodedSequence
        }
    }

    var cursor: Cursor {
        Cursor(epoch: epoch, sequence: sequence)
    }

    var isValid: Bool {
        guard schemaVersion == 1, sequence >= 0,
              walletRemovals.count <= Self.maximumEntries,
              accountRemovals.count <= Self.maximumEntries - walletRemovals.count,
              walletRemovals.allSatisfy({
                  Self.validWalletID($0.walletID) && $0.sequence > 0 && $0.sequence <= sequence
              }),
              accountRemovals.allSatisfy({
                  $0.account.isValid && $0.sequence > 0 && $0.sequence <= sequence
              }),
              Set(walletRemovals.map(\.walletID)).count == walletRemovals.count,
              Set(accountRemovals.map(\.account)).count == accountRemovals.count else { return false }
        let wallets = Dictionary(uniqueKeysWithValues: walletRemovals.map { ($0.walletID, $0.sequence) })
        guard max(walletRemovals.map(\.sequence).max() ?? 0,
                  accountRemovals.map(\.sequence).max() ?? 0) == sequence else { return false }
        return accountRemovals.allSatisfy {
            $0.sequence > (wallets[$0.account.walletID] ?? 0)
        }
    }

    @discardableResult
    mutating func record(_ removals: [WalletAuthorityRemoval]) throws -> Bool {
        for removal in removals {
            switch removal {
            case .wallet(let walletID):
                guard Self.validWalletID(walletID) else { throw Error.invalidRemoval }
            case .accounts(let removed):
                guard removed.allSatisfy(\.isValid) else { throw Error.invalidRemoval }
            }
        }
        var wallets = Set<String>()
        for case .wallet(let walletID) in removals {
            wallets.insert(walletID)
            guard wallets.count <= Self.maximumEntries else { throw Error.capacityExceeded }
        }
        var accounts = Set<WalletAccountDescriptor>()
        for case .accounts(let removed) in removals {
            for account in removed where !wallets.contains(account.walletID) {
                accounts.insert(account)
                guard accounts.count <= Self.maximumEntries - wallets.count else { throw Error.capacityExceeded }
            }
        }
        guard !wallets.isEmpty || !accounts.isEmpty else { return false }
        guard sequence < Int.max else { throw Error.sequenceExhausted }
        let nextSequence = sequence + 1
        var latestWallets = Dictionary(uniqueKeysWithValues: walletRemovals.map { ($0.walletID, $0.sequence) })
        var latestAccounts = Dictionary(uniqueKeysWithValues: accountRemovals.filter {
            !wallets.contains($0.account.walletID)
        }.map { ($0.account, $0.sequence) })
        for walletID in wallets { latestWallets[walletID] = nextSequence }
        for account in accounts { latestAccounts[account] = nextSequence }
        guard latestWallets.count <= Self.maximumEntries,
              latestAccounts.count <= Self.maximumEntries - latestWallets.count else {
            throw Error.capacityExceeded
        }
        sequence = nextSequence
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

    static func decode(_ data: Data) throws -> Self? {
        guard data.count <= maximumEncodedBytes else { throw Error.capacityExceeded }
        do {
            let ledger = try PropertyListDecoder().decode(Self.self, from: data)
            return ledger.isValid ? ledger : nil
        } catch Error.capacityExceeded {
            throw Error.capacityExceeded
        } catch {
            return nil
        }
    }

    func encoded() throws -> Data {
        guard walletRemovals.count <= Self.maximumEntries,
              accountRemovals.count <= Self.maximumEntries - walletRemovals.count else {
            throw Error.capacityExceeded
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw Error.capacityExceeded }
        return data
    }

    private static func decodeEntries<Value: Decodable>(
        _ type: Value.Type,
        from container: inout UnkeyedDecodingContainer,
        limit: Int,
        validate: (Value) -> Bool
    ) throws -> [Value] {
        guard container.count.map({ $0 <= limit }) != false else { throw Error.capacityExceeded }
        var entries = [Value]()
        entries.reserveCapacity(container.count ?? 0)
        while !container.isAtEnd {
            guard entries.count < limit else { throw Error.capacityExceeded }
            let entry = try container.decode(type)
            guard validate(entry) else { throw Error.invalidRemoval }
            entries.append(entry)
        }
        return entries
    }

    private static func validWalletID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }

    private static func accountPrecedes(_ lhs: WalletAccountDescriptor, _ rhs: WalletAccountDescriptor) -> Bool {
        (lhs.walletID, lhs.coin.rawValue, lhs.normalizedAddress, lhs.derivationPath) <
            (rhs.walletID, rhs.coin.rawValue, rhs.normalizedAddress, rhs.derivationPath)
    }
}

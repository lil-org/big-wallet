import Foundation
import Security
import Synchronization
@testable import WalletAuthority

final class FixtureStorage: Sendable {
    enum Fault: Equatable, Sendable { case none, lockedRead, failedAdd }

    private struct State: Sendable {
        var keychain: Data?
        var preferences: Data?
        var fault = Fault.none
        var keychainWrites = 0
        var preferenceWrites = 0
        var issue: String?
    }

    let root: URL
    private let state: Mutex<State>
    private static let group = "8DXC3N7E7P.org.lil.keychain"
    private static let passwordAccount = "org.lil.wallet.password"
    private static let walletPrefix = "org.lil.wallet.wallet."

    init(root: URL, permitsEmpty: Bool = false) throws {
        self.root = root
        func load(_ name: String) throws -> Data? {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try require(permitsEmpty, "Missing persisted fixture storage")
                return nil
            }
            return try readRegularFile(url)
        }
        let keychain = try load("keychain.plist")
        let preferences = try load("preferences.plist")
        try require((keychain == nil) == (preferences == nil), "Incomplete persisted fixture storage")
        if let keychain { _ = try Self.items(keychain) }
        if let preferences { _ = try Self.preferenceRoot(preferences) }
        state = Mutex(State(keychain: keychain, preferences: preferences))
    }

    var keychain: Keychain {
        Keychain(copyMatching: { [self] in copyMatching($0, $1) }, add: { [self] in add($0, $1) },
            update: { [self] in update($0, $1) }, delete: { [self] in delete($0) })
    }

    var keychainWrites: Int { state.withLock { $0.keychainWrites } }
    var preferenceWrites: Int { state.withLock { $0.preferenceWrites } }

    func setFault(_ fault: Fault) { state.withLock { $0.fault = fault } }

    func initializeEmptyPreferences() throws {
        try state.withLock { state in
            try require(state.preferences == nil && state.keychain == nil, "Restore storage is not empty")
            let data = try Self.encode(["version": 1, "standardDomain": "org.lil.wallet",
                "domains": ["org.lil.wallet": [String: Any](), SharedDefaults.suiteName: [String: Any]()]])
            try data.write(to: root.appendingPathComponent("preferences.plist"), options: .atomic)
            state.preferences = data
            state.preferenceWrites += 1
        }
    }

    func check() throws {
        if let issue = state.withLock({ $0.issue }) { throw UpgradeFailure.invalid(issue) }
    }

    func walletData(id: String) throws -> Data? {
        try state.withLock { state in
            try Self.items(state.keychain).first { ($0[kSecAttrAccount as String] as? String) == Self.walletPrefix + id }?[kSecValueData as String] as? Data
        }
    }

    func preservesOriginalRecords(from original: FixtureStorage) throws -> Bool {
        let previous = try original.state.withLock { try Self.items($0.keychain) }
        return try state.withLock { state in
            let current = try Self.items(state.keychain)
            return previous.allSatisfy { old in
                current.contains { NSDictionary(dictionary: $0).isEqual(to: old) }
            }
        }
    }

    func validateNamespaces() throws {
        try state.withLock { state in
            let items = try Self.items(state.keychain)
            try require(items.count >= 4, "Missing historical Keychain items")
            for item in items {
                try require(item[kSecClass as String] as? String == kSecClassGenericPassword as String &&
                    item[kSecAttrAccessGroup as String] as? String == Self.group &&
                    item[kSecUseDataProtectionKeychain as String] as? Bool == true &&
                    item[kSecAttrCreationDate as String] is Date && item[kSecValueData as String] is Data,
                    "Historical Keychain namespace or attributes changed")
            }
            let preferences = try Self.preferenceRoot(state.preferences)
            let domains = preferences["domains"] as? [String: Any] ?? [:]
            try require(preferences["standardDomain"] as? String == "org.lil.wallet" &&
                domains[SharedDefaults.suiteName] is [String: Any], "Historical preference namespace changed")
        }
    }

    func preferences(domain: String) -> FixturePreferences { FixturePreferences(storage: self, domain: domain) }

    fileprivate func object(domain: String, key: String) -> Any? {
        state.withLock { state in
            do {
                let root = try Self.preferenceRoot(state.preferences)
                return ((root["domains"] as? [String: Any])?[domain] as? [String: Any])?[key]
            } catch {
                state.issue = "Cannot decode preference fixture"
                return nil
            }
        }
    }

    fileprivate func set(_ value: Any?, domain: String, key: String) {
        state.withLock { state in
            do {
                var root = try Self.preferenceRoot(state.preferences)
                var domains = root["domains"] as? [String: Any] ?? [:]
                var values = domains[domain] as? [String: Any] ?? [:]
                values[key] = value
                domains[domain] = values
                root["domains"] = domains
                let data = try Self.encode(root)
                try data.write(to: self.root.appendingPathComponent("preferences.plist"), options: .atomic)
                state.preferences = data
                state.preferenceWrites += 1
            } catch { state.issue = "Cannot persist preference fixture" }
        }
    }

    fileprivate func synchronize() -> Bool { state.withLock { $0.issue == nil } }

    private static func items(_ data: Data?) throws -> [[String: Any]] {
        guard let data else { return [] }
        let root = try dictionary(data)
        try require(root["version"] as? Int == 1 && Set(root.keys) == Set(["version", "items"]), "Invalid Keychain fixture wrapper")
        guard let items = root["items"] as? [[String: Any]] else { throw UpgradeFailure.invalid("Invalid Keychain item array") }
        let accounts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        try require(accounts.count == items.count && Set(accounts).count == accounts.count, "Invalid Keychain item identity")
        return items
    }

    private static func preferenceRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return ["version": 1, "standardDomain": "org.lil.wallet", "domains": [:]] }
        let root = try dictionary(data)
        try require(root["version"] as? Int == 1 && root["standardDomain"] as? String == "org.lil.wallet" &&
            root["domains"] is [String: Any] && Set(root.keys) == Set(["version", "standardDomain", "domains"]),
            "Invalid preferences fixture wrapper")
        return root
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpgradeFailure.invalid("Invalid fixture property list")
        }
        return value
    }

    private static func encode(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        for key in [kSecClass as String, kSecAttrAccessGroup as String, kSecUseDataProtectionKeychain as String, kSecAttrAccount as String] {
            if let expected = query[key] as? NSObject {
                guard let value = item[key] as? NSObject, value.isEqual(expected) else { return false }
            }
        }
        return true
    }

    private static func validQuery(_ query: [String: Any], extra: [String], requiresAccount: Bool) -> Bool {
        let core = [kSecClass as String, kSecAttrAccount as String, kSecAttrAccessGroup as String, kSecUseDataProtectionKeychain as String]
        guard Set(query.keys).isSubset(of: Set(core + extra)),
              query[kSecClass as String] as? String == kSecClassGenericPassword as String,
              query[kSecAttrAccessGroup as String] as? String == group,
              query[kSecUseDataProtectionKeychain as String] as? Bool == true else { return false }
        if let account = query[kSecAttrAccount as String] as? String {
            return account == passwordAccount || account.hasPrefix(walletPrefix)
        }
        return !requiresAccount
    }

    private func copyMatching(_ query: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard let query = query as? [String: Any], Self.validQuery(query,
            extra: [kSecReturnData as String, kSecReturnAttributes as String, kSecMatchLimit as String], requiresAccount: false)
        else { return rejectQuery() }
        return state.withLock { state in
            if state.fault == .lockedRead { return errSecInteractionNotAllowed }
            do {
                let matches = try Self.items(state.keychain).filter { Self.matches($0, query) }
                guard !matches.isEmpty else { return errSecItemNotFound }
                if query[kSecReturnAttributes as String] as? Bool == true,
                   query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                    output?.pointee = matches.map { item in
                        var attributes = item
                        attributes[kSecValueData as String] = nil
                        return attributes
                    } as CFArray
                    return errSecSuccess
                }
                guard query[kSecReturnData as String] as? Bool == true,
                      query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,
                      let data = matches[0][kSecValueData as String] as? Data else {
                    state.issue = "Unsupported Keychain fixture read"
                    return errSecParam
                }
                output?.pointee = data as CFData
                return errSecSuccess
            } catch { state.issue = "Cannot decode Keychain fixture"; return errSecDecode }
        }
    }

    private func add(_ attributes: CFDictionary, _ output: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        guard output == nil, let attributes = attributes as? [String: Any],
              Self.validQuery(attributes, extra: [kSecValueData as String], requiresAccount: true),
              attributes[kSecValueData as String] is Data else { return rejectQuery() }
        return state.withLock { state in
            if state.fault == .failedAdd { return errSecIO }
            do {
                var items = try Self.items(state.keychain)
                guard !items.contains(where: { Self.matches($0, attributes) }) else { return errSecDuplicateItem }
                var added = attributes
                let latest = items.compactMap { $0[kSecAttrCreationDate as String] as? Date }.max() ?? Date(timeIntervalSince1970: 1_800_000_000)
                added[kSecAttrCreationDate as String] = latest.addingTimeInterval(1)
                items.append(added)
                try persist(items, state: &state)
                return errSecSuccess
            } catch { state.issue = "Cannot persist Keychain fixture"; return errSecIO }
        }
    }

    private func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        guard let query = query as? [String: Any], let attributes = attributes as? [String: Any],
              Self.validQuery(query, extra: [], requiresAccount: true),
              Set(attributes.keys) == Set([kSecValueData as String]), let data = attributes[kSecValueData as String] as? Data
        else { return rejectQuery() }
        return state.withLock { state in
            do {
                var items = try Self.items(state.keychain)
                guard let index = items.firstIndex(where: { Self.matches($0, query) }) else { return errSecItemNotFound }
                items[index][kSecValueData as String] = data
                try persist(items, state: &state)
                return errSecSuccess
            } catch { state.issue = "Cannot persist Keychain fixture"; return errSecIO }
        }
    }

    private func delete(_ query: CFDictionary) -> OSStatus {
        guard let query = query as? [String: Any], Self.validQuery(query, extra: [], requiresAccount: true) else { return rejectQuery() }
        return state.withLock { state in
            do {
                var items = try Self.items(state.keychain)
                guard let index = items.firstIndex(where: { Self.matches($0, query) }) else { return errSecItemNotFound }
                items.remove(at: index)
                try persist(items, state: &state)
                return errSecSuccess
            } catch { state.issue = "Cannot persist Keychain fixture"; return errSecIO }
        }
    }

    private func persist(_ items: [[String: Any]], state: inout State) throws {
        let data = try Self.encode(["version": 1, "items": items])
        try data.write(to: root.appendingPathComponent("keychain.plist"), options: .atomic)
        state.keychain = data
        state.keychainWrites += 1
    }

    private func rejectQuery() -> OSStatus {
        state.withLock { $0.issue = "Unexpected Keychain query in upgrade consumer" }
        return errSecParam
    }
}

final class FixturePreferences: SharedPreferenceStorage, Sendable {
    private let storage: FixtureStorage
    private let domain: String

    init(storage: FixtureStorage, domain: String) { self.storage = storage; self.domain = domain }
    func object(forKey key: String) -> Any? { storage.object(domain: domain, key: key) }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    func set(_ value: Any?, forKey key: String) { storage.set(value, domain: domain, key: key) }
    func removeObject(forKey key: String) { storage.set(nil, domain: domain, key: key) }
    func synchronize() -> Bool { storage.synchronize() }
}

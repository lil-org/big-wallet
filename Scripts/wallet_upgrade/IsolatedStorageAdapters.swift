import Foundation
import Security
import Darwin

final class ProducerStorage {
    static let standardDomain = "org.lil.wallet"
    static let sharedDomain = "8DXC3N7E7P.group.org.lil.wallet"
    private static let configurationLock = NSLock()
    private static var configured: ProducerStorage?

    static var shared: ProducerStorage {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        guard let configured else { fatalError("Producer storage was not configured") }
        return configured
    }

    static func configure(output: String) throws {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        guard configured == nil, output.hasPrefix("/") else { throw Failure.invalidDestination }
        let url = URL(fileURLWithPath: output, isDirectory: true)
        guard url.standardizedFileURL.path == output,
              url.deletingLastPathComponent().resolvingSymlinksInPath() == url.deletingLastPathComponent(),
              !FileManager.default.fileExists(atPath: output) else { throw Failure.invalidDestination }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let storage = ProducerStorage(output: url)
        try storage.persistKeychain()
        try storage.persistPreferences()
        configured = storage
    }

    enum Failure: Error { case invalidDestination, writeFailed }
    private let lock = NSLock()
    private let output: URL
    private var items = [[String: Any]]()
    private var domains: [String: [String: Any]] = [standardDomain: [:], sharedDomain: [:]]
    private var sequence = 0

    private init(output: URL) { self.output = output }

    private func synchronized<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func writeOutput(_ data: Data, named name: String) throws {
        try synchronized { try write(data, named: name) }
    }

    private func write(_ data: Data, named name: String) throws {
        guard ["keychain.plist", "preferences.plist", "expectations.json"].contains(name),
              output.resolvingSymlinksInPath() == output else { throw Failure.invalidDestination }
        let destination = output.appendingPathComponent(name)
        let temporary = output.appendingPathComponent(".write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.writeFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard Darwin.rename(temporary.path, destination.path) == 0 else { throw Failure.writeFailed }
    }

    private func persistKeychain() throws {
        try write(PropertyListSerialization.data(fromPropertyList: ["version": 1, "items": items],
            format: .binary, options: 0), named: "keychain.plist")
    }

    private func persistPreferences() throws {
        try write(PropertyListSerialization.data(fromPropertyList: ["version": 1,
            "standardDomain": Self.standardDomain, "domains": domains], format: .binary, options: 0),
            named: "preferences.plist")
    }

    private func checked(_ raw: CFDictionary, keys: Set<String>, accountRequired: Bool = true) -> [String: Any] {
        guard let value = raw as? [String: Any], Set(value.keys) == keys,
              value[kSecClass as String] as? String == kSecClassGenericPassword as String,
              value[kSecAttrAccessGroup as String] as? String == "8DXC3N7E7P.org.lil.keychain",
              isBoolean(value[kSecUseDataProtectionKeychain as String], equalTo: true) else {
            fatalError("Unsupported producer Keychain query")
        }
        if accountRequired {
            guard let account = value[kSecAttrAccount as String] as? String,
                  account == "org.lil.wallet.password" || account.hasPrefix("org.lil.wallet.wallet.") else {
                fatalError("Unsupported producer Keychain account")
            }
        }
        return value
    }

    private var identityKeys: Set<String> {
        [kSecClass as String, kSecAttrAccount as String, kSecAttrAccessGroup as String,
         kSecUseDataProtectionKeychain as String]
    }

    private func isBoolean(_ value: Any?, equalTo expected: Bool) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }

    func copyMatching(_ raw: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        synchronized {
            result?.pointee = nil
            let rawValue = raw as NSDictionary
            if rawValue[kSecMatchLimit] as? String == kSecMatchLimitAll as String {
                let keys = identityKeys.subtracting([kSecAttrAccount as String])
                    .union([kSecReturnData as String, kSecReturnAttributes as String, kSecMatchLimit as String])
                let query = checked(raw, keys: keys, accountRequired: false)
                guard isBoolean(query[kSecReturnData as String], equalTo: false),
                      isBoolean(query[kSecReturnAttributes as String], equalTo: true) else {
                    fatalError("Unsupported producer Keychain result selection")
                }
                guard !items.isEmpty else { return errSecItemNotFound }
                result?.pointee = items.map { record in
                    record.filter { $0.key != kSecValueData as String }
                } as CFArray
                return errSecSuccess
            }
            let query = checked(raw, keys: identityKeys.union([kSecReturnData as String, kSecMatchLimit as String]))
            guard query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,
                  isBoolean(query[kSecReturnData as String], equalTo: true) else {
                fatalError("Unsupported producer Keychain result selection")
            }
            guard let item = items.first(where: { ($0[kSecAttrAccount as String] as? String) == (query[kSecAttrAccount as String] as? String) }),
                  let data = item[kSecValueData as String] as? Data else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }
    }

    func add(_ raw: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        synchronized {
            let value = checked(raw, keys: identityKeys.union([kSecValueData as String]))
            guard result == nil, value[kSecValueData as String] is Data else {
                fatalError("Unsupported producer Keychain insertion")
            }
            guard !items.contains(where: { ($0[kSecAttrAccount as String] as? String) == (value[kSecAttrAccount as String] as? String) }) else {
                return errSecDuplicateItem
            }
            var item = value
            item[kSecAttrCreationDate as String] = Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence))
            sequence += 1
            items.append(item)
            persistOrFail(persistKeychain)
            return errSecSuccess
        }
    }

    func update(_ raw: CFDictionary, attributes rawAttributes: CFDictionary) -> OSStatus {
        synchronized {
            let query = checked(raw, keys: identityKeys)
            guard let attributes = rawAttributes as? [String: Any], Set(attributes.keys) == [kSecValueData as String],
                  let data = attributes[kSecValueData as String] as? Data else {
                fatalError("Unsupported producer Keychain update")
            }
            guard let index = items.firstIndex(where: { ($0[kSecAttrAccount as String] as? String) == (query[kSecAttrAccount as String] as? String) }) else { return errSecItemNotFound }
            items[index][kSecValueData as String] = data
            persistOrFail(persistKeychain)
            return errSecSuccess
        }
    }

    func delete(_ raw: CFDictionary) -> OSStatus {
        synchronized {
            let hasData = (raw as NSDictionary)[kSecValueData] != nil
            let query = checked(raw, keys: hasData ? identityKeys.union([kSecValueData as String]) : identityKeys)
            guard !hasData || query[kSecValueData as String] is Data else { fatalError("Unsupported producer Keychain deletion") }
            guard let index = items.firstIndex(where: { ($0[kSecAttrAccount as String] as? String) == (query[kSecAttrAccount as String] as? String) }) else { return errSecItemNotFound }
            items.remove(at: index)
            persistOrFail(persistKeychain)
            return errSecSuccess
        }
    }

    func preferences(domain: String) -> [String: Any] {
        synchronized {
            guard let values = domains[domain] else { fatalError("Unsupported producer preference domain") }
            return values
        }
    }

    func setPreference(_ value: Any?, key: String, domain: String) {
        synchronized {
            guard domains[domain] != nil else { fatalError("Unsupported producer preference domain") }
            if let value {
                guard PropertyListSerialization.propertyList([key: value], isValidFor: .binary) else {
                    fatalError("Unsupported producer preference value")
                }
                domains[domain]?[key] = value
            } else {
                domains[domain]?.removeValue(forKey: key)
            }
            persistOrFail(persistPreferences)
        }
    }

    private func persistOrFail(_ body: () throws -> Void) {
        do { try body() }
        catch { fatalError("Producer isolated storage could not persist") }
    }
}

func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    ProducerStorage.shared.copyMatching(query, result: result)
}

@discardableResult
func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    ProducerStorage.shared.add(attributes, result: result)
}

@discardableResult
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    ProducerStorage.shared.update(query, attributes: attributes)
}

@discardableResult
func SecItemDelete(_ query: CFDictionary) -> OSStatus { ProducerStorage.shared.delete(query) }

final class UserDefaults {
    static let standard = UserDefaults(domain: ProducerStorage.standardDomain)
    private let domain: String
    private init(domain: String) { self.domain = domain }

    init?(suiteName: String) {
        guard [ProducerStorage.standardDomain, ProducerStorage.sharedDomain].contains(suiteName) else {
            fatalError("Unsupported producer preference suite")
        }
        domain = suiteName
    }

    func object(forKey key: String) -> Any? { ProducerStorage.shared.preferences(domain: domain)[key] }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    func set(_ value: Any?, forKey key: String) { ProducerStorage.shared.setPreference(value, key: key, domain: domain) }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
    func persistentDomain(forName name: String) -> [String: Any]? { ProducerStorage.shared.preferences(domain: name) }
    @discardableResult func synchronize() -> Bool { true }
}

final class DistributedNotificationCenter {
    enum SuspensionBehavior { case deliverImmediately }
    private static let instance = DistributedNotificationCenter()
    static func `default`() -> DistributedNotificationCenter { instance }
    func addObserver(_ observer: Any, selector: Selector, name: Notification.Name?, object: String?, suspensionBehavior: SuspensionBehavior) {}
    func post(name: Notification.Name, object: String?) {}
}

// ∅ 2026 lil org

import Foundation

public struct EthereumAccessListEntry: Equatable, Sendable {
    public let address: Data
    public let storageKeys: [Data]

    public init?(address: Data, storageKeys: [Data]) {
        guard address.count == 20,
              storageKeys.allSatisfy({ $0.count == 32 }) else { return nil }
        self.address = address
        self.storageKeys = storageKeys
    }

    public init?(address: String, storageKeys: [String]) {
        guard let address = Self.data(fromStrictHex: address, byteCount: 20) else {
            return nil
        }
        let decodedStorageKeys = storageKeys.compactMap {
            Self.data(fromStrictHex: $0, byteCount: 32)
        }
        guard decodedStorageKeys.count == storageKeys.count else { return nil }
        self.init(address: address, storageKeys: decodedStorageKeys)
    }

    public var addressHexString: String {
        String.hexPrefix + WalletEncoding.hexString(address)
    }

    public var storageKeyHexStrings: [String] {
        storageKeys.map { String.hexPrefix + WalletEncoding.hexString($0) }
    }

    private static func data(fromStrictHex value: String, byteCount: Int) -> Data? {
        guard value.hasPrefix("0x") else { return nil }
        let cleanValue = String(value.dropFirst(2))
        guard cleanValue.count == byteCount * 2,
              let data = WalletEncoding.hexData(cleanValue),
              data.count == byteCount else { return nil }
        return data
    }
}

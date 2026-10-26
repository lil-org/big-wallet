import Foundation

public enum WalletEncoding {
    public static func base58Decode(_ string: String) -> Data? {
        return Base58.decode(string)
    }

    public static func base58Decode(string: String) -> Data? {
        return base58Decode(string)
    }

    public static func base58Encode(_ data: Data) -> String {
        return Base58.encode(data)
    }

    public static func base58Encode(data: Data) -> String {
        return base58Encode(data)
    }

    public static func hexData(_ string: String) -> Data? {
        let hexString = string.cleanHex
        return cleanHexData(hexString)
    }

    public static func hexData(string: String) -> Data? {
        return hexData(string)
    }

    public static func isValidNonEmptyHexData(_ string: String) -> Bool {
        let hexString = string.cleanHex
        return !hexString.isEmpty && isValidCleanHexData(hexString)
    }

    private static func cleanHexData(_ hexString: String) -> Data? {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(hexString.count / 2)

        var highNibble: UInt8?
        for byte in hexString.utf8 {
            guard let value = hexValue(byte) else { return nil }
            if let high = highNibble {
                data.append((high << 4) | value)
                highNibble = nil
            } else {
                highNibble = value
            }
        }
        return data
    }

    private static func isValidCleanHexData(_ hexString: String) -> Bool {
        guard hexString.count.isMultiple(of: 2) else { return false }
        return hexString.utf8.allSatisfy { hexValue($0) != nil }
    }

    public static func hexString(_ data: Data) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(hexAlphabet[Int(byte >> 4)])
            bytes.append(hexAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    public static func hexString(data: Data) -> String {
        return hexString(data)
    }

    public static func keccak256(data: Data) -> Data {
        return Keccak256.hash(data)
    }

    public static func keccak256(parts: [Data]) -> Data {
        return Keccak256.hash(parts: parts)
    }

    public static func isSupportedEthereumSigningDigest(_ digest: Data) -> Bool {
        return digest.count == 32 && digest.contains { $0 != 0 }
    }

    public static func ethereumTypedDataDigest(messageJson: String) -> Data {
        return EIP712.digest(json: messageJson)
    }

    public static func decodeEthereumCall(data: Data, abi: String) -> String? {
        return EthereumABI.decodeCall(data: data, abi: abi)
    }

    public static func previewDerivationIndex(derivationPath: String, coin: WalletCoin) -> Int {
        guard let path = DerivationPath(derivationPath) else { return 0 }
        switch coin {
        case .solana:
            return Int(path.account)
        case .ethereum:
            return Int(path.address)
        }
    }

    public static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static let hexAlphabet = Array("0123456789abcdef".utf8)
}

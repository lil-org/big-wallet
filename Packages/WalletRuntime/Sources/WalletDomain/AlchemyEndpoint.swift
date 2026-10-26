import Foundation

public enum AlchemyRPC {

    public static func url(network: String) -> URL? {
        guard isValidNetworkName(network) else { return nil }
        return URL(string: "https://\(network).g.alchemy.com/v2")
    }

    public static func isValidNetworkName(_ network: String) -> Bool {
        let bytes = network.utf8
        guard (1...63).contains(bytes.count),
              let first = bytes.first,
              let last = bytes.last,
              isASCIIAlphanumeric(first),
              isASCIIAlphanumeric(last) else {
            return false
        }

        return bytes.allSatisfy {
            $0 == 45 || isASCIIAlphanumeric($0)
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        return (48...57).contains(byte) || (97...122).contains(byte)
    }

}


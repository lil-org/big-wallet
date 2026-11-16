import Foundation
import WalletDomain

enum HTTPJSONBudget {
    static func normalizedBytes(from data: Data, limits: NativeRPCResponseLimits) throws -> Data? {
        try Task.checkCancellation()
        guard data.count <= limits.maximumResponseBytes else {
            throw HTTPResponsePolicyError.responseTooLarge
        }
        guard let bytes = try utf8Bytes(data, limits: limits) else { return nil }
        let json = bytes.dropFirst(bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0)
        do {
            try JSONPreflight.validate(json, maximumDepth: limits.maximumJSONDepth, maximumTokens: limits.maximumJSONTokens)
        } catch let failure as JSONPreflight.Failure {
            switch failure {
            case .tooDeep: throw HTTPResponsePolicyError.jsonTooDeep
            case .tooManyTokens: throw HTTPResponsePolicyError.tooManyJSONTokens
            case .unbalanced: return nil
            }
        }
        try Task.checkCancellation()
        return bytes
    }

    private static func utf8Bytes(_ data: Data, limits: NativeRPCResponseLimits) throws -> Data? {
        let prefix = Array(data.prefix(4))
        guard prefix.count == 4 else { return data }
        let encoding: String.Encoding
        switch (prefix[0], prefix[1], prefix[2], prefix[3]) {
        case (0, 0, 0xfe, 0xff), (0, 0, 0, _): encoding = .utf32BigEndian
        case (0xff, 0xfe, 0, 0), (_, 0, 0, 0): encoding = .utf32LittleEndian
        case (0xfe, 0xff, _, _), (0, _, 0, _): encoding = .utf16BigEndian
        case (0xff, 0xfe, _, _), (_, 0, _, 0): encoding = .utf16LittleEndian
        default: return data
        }
        guard let string = String(data: data, encoding: encoding) else { return nil }
        try Task.checkCancellation()
        guard string.utf8.count <= limits.maximumResponseBytes else {
            throw HTTPResponsePolicyError.responseTooLarge
        }
        return Data(string.utf8)
    }

}

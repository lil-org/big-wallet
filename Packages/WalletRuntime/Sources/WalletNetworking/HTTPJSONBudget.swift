import Foundation

enum HTTPJSONBudget {
    static func normalizedBytes(from data: Data, limits: NativeRPCResponseLimits) throws -> Data? {
        try Task.checkCancellation()
        guard data.count <= limits.maximumResponseBytes else {
            throw HTTPResponsePolicyError.responseTooLarge
        }
        guard let bytes = try utf8Bytes(data, limits: limits) else { return nil }
        try validateJSONBudget(bytes, limits: limits)
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

    private static func validateJSONBudget(_ bytes: Data, limits: NativeRPCResponseLimits) throws {
        var tokens = 0
        var depth = 0
        var inString = false
        var escaped = false
        var inScalar = false
        let json = bytes.dropFirst(bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0)
        for (offset, byte) in json.enumerated() {
            if offset % 4096 == 0 { try Task.checkCancellation() }
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            switch byte {
            case 34:
                tokens += 1
                inString = true
                inScalar = false
            case 91, 123:
                tokens += 1
                depth += 1
                inScalar = false
                guard depth <= limits.maximumJSONDepth else {
                    throw HTTPResponsePolicyError.jsonTooDeep
                }
            case 93, 125:
                depth -= 1
                inScalar = false
            case 9, 10, 13, 32, 44, 58:
                inScalar = false
            default:
                if !inScalar { tokens += 1 }
                inScalar = true
            }
            guard tokens <= limits.maximumJSONTokens else {
                throw HTTPResponsePolicyError.tooManyJSONTokens
            }
        }
        try Task.checkCancellation()
    }
}

import Foundation

enum NativeRPCResponseDecoder {
    static func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        expectedID: Int
    ) -> Response? {
        guard let envelope = try? JSONDecoder().decode(Envelope<Response>.self, from: data),
              envelope.id == expectedID,
              let tokens = numericTokens(in: data),
              isExactInteger(tokens.id, equalTo: expectedID) else { return nil }
        if let code = envelope.errorCode {
            guard let token = tokens.error?.code, isExactInteger(token, equalTo: code) else { return nil }
        }
        return envelope.response
    }

    private struct NumericTokens: Decodable {
        struct Failure: Decodable {
            let code: String
        }
        let id: String
        let error: Failure?
    }

    private static func numericTokens(in data: Data) -> NumericTokens? {
        guard let bytes = utf8Bytes(data) else { return nil }
        var quoted = Data(capacity: bytes.count)
        var inString = false
        var escaped = false
        var inNumber = false
        // Preserve numeric literals as strings after the original decode has checked their JSON types.
        for byte in bytes {
            if inString {
                quoted.append(byte)
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                continue
            }
            if inNumber {
                if (48...57).contains(byte) || [43, 45, 46, 69, 101].contains(byte) {
                    quoted.append(byte)
                    continue
                }
                quoted.append(34)
                inNumber = false
            }
            if byte == 34 { inString = true }
            else if byte == 45 || (48...57).contains(byte) {
                quoted.append(34)
                inNumber = true
            }
            quoted.append(byte)
        }
        if inNumber { quoted.append(34) }
        return try? JSONDecoder().decode(NumericTokens.self, from: quoted)
    }

    private static func utf8Bytes(_ data: Data) -> Data? {
        let prefix = Array(data.prefix(4))
        guard prefix.count == 4 else { return nil }
        let encoding: String.Encoding
        switch (prefix[0], prefix[1], prefix[2], prefix[3]) {
        case (0, 0, 0xfe, 0xff), (0, 0, 0, _): encoding = .utf32BigEndian
        case (0xff, 0xfe, 0, 0), (_, 0, 0, 0): encoding = .utf32LittleEndian
        case (0xfe, 0xff, _, _), (0, _, 0, _): encoding = .utf16BigEndian
        case (0xff, 0xfe, _, _), (_, 0, _, 0): encoding = .utf16LittleEndian
        default: return data
        }
        return String(data: data, encoding: encoding).map { Data($0.utf8) }
    }

    private static func isExactInteger(_ token: String, equalTo value: Int) -> Bool {
        let parts = token.split(maxSplits: 1, whereSeparator: { $0 == "e" || $0 == "E" })
        guard let mantissa = parts.first else { return false }
        let fractionalCount = mantissa.firstIndex(of: ".").map {
            mantissa.distance(from: mantissa.index(after: $0), to: mantissa.endIndex)
        } ?? 0
        var digits = mantissa.filter { $0 != "." && $0 != "-" }.drop(while: { $0 == "0" })
        guard !digits.isEmpty else { return value == 0 }
        guard (mantissa.first == "-") == (value < 0),
              let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return false }
        var trailingZeros = 0
        while digits.last == "0" {
            digits.removeLast()
            trailingZeros += 1
        }
        let (fractionalShift, underflow) = exponent.subtractingReportingOverflow(fractionalCount)
        let (scale, overflow) = fractionalShift.addingReportingOverflow(trailingZeros)
        let expected = String(value).drop(while: { $0 == "-" })
        guard !underflow, !overflow, scale >= 0, scale <= expected.count,
              digits.count == expected.count - scale else { return false }
        return expected.prefix(digits.count) == digits && expected.suffix(scale).allSatisfy { $0 == "0" }
    }

    private struct Envelope<Response: Decodable>: Decodable {
        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, result, error
        }

        private enum ErrorKeys: String, CodingKey {
            case code, message
        }

        let id: Int
        let errorCode: Int?
        let response: Response

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard try container.decode(String.self, forKey: .jsonrpc) == "2.0" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .jsonrpc, in: container, debugDescription: "Unsupported JSON-RPC version"
                )
            }
            id = try container.decode(Int.self, forKey: .id)
            let hasResult = container.contains(.result)
            guard hasResult != container.contains(.error) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected exactly one JSON-RPC result or error"
                ))
            }
            if hasResult {
                guard try !container.decodeNil(forKey: .result) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .result, in: container, debugDescription: "Expected a non-null RPC result"
                    )
                }
                errorCode = nil
            } else {
                let error = try container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
                errorCode = try error.decode(Int.self, forKey: .code)
                _ = try error.decode(String.self, forKey: .message)
            }
            response = try Response(from: decoder)
        }
    }
}

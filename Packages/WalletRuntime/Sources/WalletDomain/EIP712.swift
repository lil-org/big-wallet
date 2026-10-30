import Foundation

public struct PreparedEthereumTypedData: Equatable, Sendable {
    public let rawJSON: String
    public let digest: Data

    public init?(json: String) {
        guard let digest = try? EIP712.checkedDigest(json: json) else { return nil }
        rawJSON = json
        self.digest = digest
    }
}

public enum EIP712 {
    public struct Field: Sendable {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    struct Limits: Sendable {
        var inputBytes = 256 * 1_024
        var jsonDepth = 64
        var jsonTokens = 65_536
        var types = 256
        var fieldsPerType = 128
        var totalFields = 4_096
        var dependencyDepth = 32
        var valueDepth = 32
        var arrayTypeDepth = 32
        var arrayElements = 4_096
        var work = 65_536
        var processingBytes = 8 * 1_024 * 1_024
    }

    enum PreparationError: Error, Equatable {
        case invalid
        case inputTooLarge
        case jsonTooDeep
        case tooManyJSONTokens
        case tooManyTypes
        case tooManyFields
        case dependencyTooDeep
        case valueTooDeep
        case arrayTypeTooDeep
        case arrayTooLarge
        case tooMuchWork
        case tooManyProcessingBytes
    }

    public static func digest(json: String) -> Data {
        (try? checkedDigest(json: json)) ?? Data()
    }

    static func checkedDigest(json: String, limits: Limits = Limits()) throws -> Data {
        var computation = Computation(limits: limits)
        return try computation.digest(json: json)
    }

    private struct Budget {
        var remainingWork: Int
        var remainingBytes: Int

        mutating func work(_ count: Int = 1) throws {
            try Task.checkCancellation()
            guard count >= 0, count <= remainingWork else { throw PreparationError.tooMuchWork }
            remainingWork -= count
        }

        mutating func bytes(_ count: Int) throws {
            try Task.checkCancellation()
            guard count >= 0, count <= remainingBytes else { throw PreparationError.tooManyProcessingBytes }
            remainingBytes -= count
        }
    }

    private struct ParsedType {
        let base: String
        let arrayCounts: [Int?]
    }

    private struct PreparedField {
        let field: Field
        let parsedType: ParsedType
    }

    private struct Computation {
        let limits: Limits
        var budget: Budget
        var types = [String: [PreparedField]]()
        var parsedTypes = [Data: ParsedType]()
        var typeHashes = [Data: Data]()

        init(limits: Limits) {
            self.limits = limits
            budget = Budget(remainingWork: limits.work, remainingBytes: limits.processingBytes)
        }

        mutating func digest(json: String) throws -> Data {
            try Task.checkCancellation()
            guard limits.inputBytes >= 0, limits.inputBytes < Int.max,
                  json.utf8.prefix(limits.inputBytes + 1).count <= limits.inputBytes else {
                throw PreparationError.inputTooLarge
            }
            try budget.bytes(json.utf8.count)
            let data = Data(json.utf8)
            try validateJSONBudget(data)
            try budget.bytes(data.count)
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let typesObject = object["types"] as? [String: Any],
                  let primaryType = object["primaryType"] as? String,
                  let domain = object["domain"] as? [String: Any],
                  let message = object["message"] as? [String: Any] else { throw PreparationError.invalid }
            try parseTypes(typesObject)
            try budget.bytes(primaryType.utf8.count)
            guard types[primaryType] != nil, types["EIP712Domain"] != nil else {
                throw PreparationError.invalid
            }
            let domainHash = try hashStruct(type: "EIP712Domain", value: domain, depth: 0)
            let messageHash = try hashStruct(type: primaryType, value: message, depth: 0)
            var encoded = Data([0x19, 0x01])
            try budget.bytes(encoded.count)
            try append(domainHash, to: &encoded)
            try append(messageHash, to: &encoded)
            return try hash(encoded)
        }

        mutating func validateJSONBudget(_ data: Data) throws {
            try budget.bytes(data.count)
            var tokens = 0
            var depth = 0
            var inString = false
            var escaped = false
            var inScalar = false
            let json = data.dropFirst(data.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0)
            for (offset, byte) in json.enumerated() {
                if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
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
                    guard depth <= limits.jsonDepth else { throw PreparationError.jsonTooDeep }
                case 93, 125:
                    depth -= 1
                    inScalar = false
                    guard depth >= 0 else { throw PreparationError.invalid }
                case 9, 10, 13, 32, 44, 58:
                    inScalar = false
                default:
                    if !inScalar { tokens += 1 }
                    inScalar = true
                }
                guard tokens <= limits.jsonTokens else { throw PreparationError.tooManyJSONTokens }
            }
            guard !inString, depth == 0 else { throw PreparationError.invalid }
            try Task.checkCancellation()
        }

        mutating func parseTypes(_ object: [String: Any]) throws {
            guard object.count <= limits.types else { throw PreparationError.tooManyTypes }
            var totalFields = 0
            for (name, value) in object {
                try budget.work()
                try budget.bytes(name.utf8.count)
                guard let fields = value as? [[String: Any]] else { throw PreparationError.invalid }
                guard fields.count <= limits.fieldsPerType,
                      fields.count <= limits.totalFields - totalFields else { throw PreparationError.tooManyFields }
                totalFields += fields.count
                var prepared = [PreparedField]()
                prepared.reserveCapacity(fields.count)
                for field in fields {
                    try budget.work()
                    guard let fieldName = field["name"] as? String,
                          let fieldType = field["type"] as? String else { throw PreparationError.invalid }
                    try budget.bytes(fieldName.utf8.count)
                    prepared.append(PreparedField(
                        field: Field(name: fieldName, type: fieldType),
                        parsedType: try parsedType(fieldType)
                    ))
                }
                types[name] = prepared
            }
        }

        mutating func parsedType(_ type: String) throws -> ParsedType {
            try budget.bytes(type.utf8.count)
            let identity = Data(type.utf8)
            if let parsed = parsedTypes[identity] { return parsed }
            var current = type
            var arrays = [Int?]()
            while true {
                try budget.work()
                try budget.bytes(current.utf8.count)
                guard let array = EthereumType.arrayInfo(current) else { break }
                guard arrays.count < limits.arrayTypeDepth else { throw PreparationError.arrayTypeTooDeep }
                arrays.append(array.count)
                current = array.elementType
            }
            let parsed = ParsedType(base: current, arrayCounts: arrays)
            parsedTypes[identity] = parsed
            return parsed
        }

        mutating func hashStruct(type: String, value: [String: Any], depth: Int) throws -> Data {
            try budget.work()
            guard depth <= limits.valueDepth else { throw PreparationError.valueTooDeep }
            try budget.bytes(type.utf8.count)
            guard let fields = types[type] else { throw PreparationError.invalid }
            var encoded = try typeHash(type)
            for field in fields {
                try budget.work()
                try budget.bytes(field.field.name.utf8.count)
                guard let fieldValue = value[field.field.name] else { throw PreparationError.invalid }
                let word = try encodeValue(type: field.parsedType, value: fieldValue, depth: depth + 1)
                try append(word, to: &encoded)
            }
            return try hash(encoded)
        }

        mutating func typeHash(_ type: String) throws -> Data {
            try budget.bytes(type.utf8.count)
            let identity = Data(type.utf8)
            if let cached = typeHashes[identity] { return cached }
            var visited = Set<String>()
            var dependencies = [String]()
            let parsed = try parsedType(type)
            try collectDependencies(of: parsed, depth: 1, visited: &visited, into: &dependencies)
            let others = try dependencies.filter { $0 != type }.sorted { left, right in
                try budget.bytes(left.utf8.count)
                try budget.bytes(right.utf8.count)
                return left < right
            }
            var encoded = Data()
            for name in [type] + others {
                try budget.work()
                try append(name, to: &encoded)
                try append("(", to: &encoded)
                let fields = types[name] ?? []
                for (index, field) in fields.enumerated() {
                    try budget.work()
                    if index > 0 { try append(",", to: &encoded) }
                    try append(field.field.type, to: &encoded)
                    try append(" ", to: &encoded)
                    try append(field.field.name, to: &encoded)
                }
                try append(")", to: &encoded)
            }
            let result = try hash(encoded)
            typeHashes[identity] = result
            return result
        }

        mutating func collectDependencies(
            of type: ParsedType,
            depth: Int,
            visited: inout Set<String>,
            into dependencies: inout [String]
        ) throws {
            try budget.bytes(type.base.utf8.count)
            guard visited.insert(type.base).inserted else { return }
            dependencies.append(type.base)
            guard let fields = types[type.base] else { return }
            guard depth <= limits.dependencyDepth else { throw PreparationError.dependencyTooDeep }
            for field in fields {
                try budget.work()
                try budget.bytes(field.parsedType.base.utf8.count)
                if types[field.parsedType.base] != nil {
                    try collectDependencies(of: field.parsedType, depth: depth + 1, visited: &visited, into: &dependencies)
                }
            }
        }

        mutating func encodeValue(type: ParsedType, value: Any, depth: Int, arrayIndex: Int = 0) throws -> Data {
            try budget.work()
            guard depth <= limits.valueDepth else { throw PreparationError.valueTooDeep }
            if arrayIndex < type.arrayCounts.count {
                guard let array = value as? [Any] else { throw PreparationError.invalid }
                guard array.count <= limits.arrayElements else { throw PreparationError.arrayTooLarge }
                if let expected = type.arrayCounts[arrayIndex], expected != array.count { throw PreparationError.invalid }
                let (capacity, overflow) = array.count.multipliedReportingOverflow(by: 32)
                guard !overflow else { throw PreparationError.tooManyProcessingBytes }
                try budget.bytes(capacity)
                var encoded = Data(capacity: capacity)
                for item in array {
                    try budget.work()
                    let word = try encodeValue(type: type, value: item, depth: depth + 1, arrayIndex: arrayIndex + 1)
                    try append(word, to: &encoded)
                }
                return try hash(encoded)
            }
            try budget.bytes(type.base.utf8.count)
            if types[type.base] != nil {
                guard let object = value as? [String: Any] else { throw PreparationError.invalid }
                return try hashStruct(type: type.base, value: object, depth: depth)
            }
            switch type.base {
            case "string":
                guard let string = value as? String else { throw PreparationError.invalid }
                try budget.bytes(string.utf8.count)
                return try hash(Data(string.utf8))
            case "bytes":
                let data = try hexDataValue(value)
                return try hash(data)
            case "bool":
                guard let boolean = Self.boolValue(value) else { throw PreparationError.invalid }
                try budget.bytes(32)
                return Data(repeating: 0, count: 31) + Data([boolean ? 1 : 0])
            case "address":
                guard let string = value as? String else { throw PreparationError.invalid }
                try budget.bytes(string.utf8.count)
                guard let address = EthereumCodec.parseAddress(string) else { throw PreparationError.invalid }
                try budget.bytes(32)
                return address.leftPadded(to: 32)
            default:
                if let length = EthereumType.fixedBytesLength(type: type.base) {
                    let data = try hexDataValue(value, lenient: true)
                    guard !data.isEmpty, data.count <= length else { throw PreparationError.invalid }
                    try budget.bytes(32)
                    return data + Data(repeating: 0, count: 32 - data.count)
                }
                if type.base.hasPrefix("uint"), let bitWidth = EthereumType.integerBitWidth(type: type.base, prefix: "uint") {
                    let integer = try unsignedInteger(value)
                    guard integer < EthereumType.twoPower(bitWidth) else { throw PreparationError.invalid }
                    try budget.bytes(32)
                    return integer.toData(minLength: 32)
                }
                if type.base.hasPrefix("int"), let bitWidth = EthereumType.integerBitWidth(type: type.base, prefix: "int") {
                    let signed = try signedInteger(value)
                    let bound = EthereumType.twoPower(bitWidth - 1)
                    let word: BigUInt
                    if signed.negative {
                        guard signed.magnitude <= bound else { throw PreparationError.invalid }
                        word = signed.magnitude.isZero ? BigUInt() : EthereumType.twoPower(256) - signed.magnitude
                    } else {
                        guard signed.magnitude < bound else { throw PreparationError.invalid }
                        word = signed.magnitude
                    }
                    try budget.bytes(32)
                    return word.toData(minLength: 32)
                }
                throw PreparationError.invalid
            }
        }

        mutating func hexDataValue(_ value: Any, lenient: Bool = false) throws -> Data {
            guard let string = value as? String else { throw PreparationError.invalid }
            try budget.bytes(string.utf8.count)
            let clean = lenient ? string.cleanEvenHex : string.cleanHex
            try budget.bytes(clean.utf8.count)
            guard let data = WalletEncoding.hexData(clean) else { throw PreparationError.invalid }
            return data
        }

        static func boolValue(_ value: Any) -> Bool? {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }

        mutating func unsignedInteger(_ value: Any) throws -> BigUInt {
            guard Self.boolValue(value) == nil else { throw PreparationError.invalid }
            if let integer = value as? Int, integer >= 0 { return BigUInt(UInt64(integer)) }
            if let number = value as? NSNumber { return try boundedInteger(number.stringValue, hexadecimal: false) }
            guard let string = value as? String else { throw PreparationError.invalid }
            if string.hasPrefix(String.hexPrefix) {
                try budget.bytes(string.utf8.count)
                let padded = string.cleanEvenHex
                try budget.bytes(padded.utf8.count)
                return try boundedInteger(padded.cleanHex, hexadecimal: true)
            }
            return try boundedInteger(string, hexadecimal: false)
        }

        mutating func signedInteger(_ value: Any) throws -> (negative: Bool, magnitude: BigUInt) {
            guard Self.boolValue(value) == nil else { throw PreparationError.invalid }
            if let integer = value as? Int {
                if integer >= 0 { return (false, BigUInt(UInt64(integer))) }
                return (true, BigUInt(UInt64(integer.magnitude)))
            }
            let string: String
            if let number = value as? NSNumber { string = number.stringValue }
            else if let value = value as? String { string = value }
            else { throw PreparationError.invalid }
            if string.hasPrefix("-") {
                try budget.bytes(string.utf8.count)
                return (true, try boundedInteger(String(string.dropFirst()), hexadecimal: false))
            }
            return (false, try boundedInteger(string, hexadecimal: false))
        }

        mutating func boundedInteger(_ string: String, hexadecimal: Bool) throws -> BigUInt {
            try budget.bytes(string.utf8.count)
            guard !string.isEmpty else { throw PreparationError.invalid }
            let maximumDigits = hexadecimal ? 64 : 78
            var significantDigits = 0
            var leadingZeros = 0
            for (offset, byte) in string.utf8.enumerated() {
                if offset.isMultiple(of: 4_096) { try Task.checkCancellation() }
                guard hexadecimal ? WalletEncoding.hexValue(byte) != nil : (48...57).contains(byte) else {
                    throw PreparationError.invalid
                }
                if significantDigits == 0, byte == 48 { leadingZeros += 1 }
                else {
                    significantDigits += 1
                    guard significantDigits <= maximumDigits else { throw PreparationError.invalid }
                }
            }
            guard significantDigits > 0 else { return BigUInt() }
            try budget.bytes(significantDigits)
            let significant = String(decoding: string.utf8.dropFirst(leadingZeros), as: UTF8.self)
            let parsed = hexadecimal ? BigUInt(hexString: significant) : BigUInt(decimalString: significant)
            guard let parsed else { throw PreparationError.invalid }
            return parsed
        }

        mutating func append(_ data: Data, to destination: inout Data) throws {
            try budget.bytes(data.count)
            destination.append(data)
        }

        mutating func append(_ string: String, to destination: inout Data) throws {
            try budget.bytes(string.utf8.count)
            destination.append(contentsOf: string.utf8)
        }

        mutating func hash(_ data: Data) throws -> Data {
            try budget.bytes(data.count)
            try budget.bytes(32)
            let digest = WalletEncoding.keccak256(data: data)
            try Task.checkCancellation()
            return digest
        }
    }
}

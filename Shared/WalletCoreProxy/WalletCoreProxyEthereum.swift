// ∅ 2026 lil org

import Foundation

private enum EthereumType {
    static func arrayInfo(_ type: String) -> (elementType: String, count: Int?)? {
        guard let bracket = type.lastIndex(of: "["),
              type.hasSuffix("]") else { return nil }
        let elementType = String(type[..<bracket])
        let countText = type[type.index(after: bracket)..<type.index(before: type.endIndex)]
        guard !elementType.isEmpty else { return nil }
        if countText.isEmpty { return (elementType, nil) }
        guard let count = Int(countText), count > 0 else { return nil }
        return (elementType, count)
    }

    static func integerBitWidth(type: String, prefix: String) -> Int? {
        guard type.hasPrefix(prefix) else { return nil }
        let suffix = type.dropFirst(prefix.count)
        let bitWidth: Int
        if suffix.isEmpty {
            bitWidth = 256
        } else if let parsed = Int(suffix) {
            bitWidth = parsed
        } else {
            return nil
        }
        guard bitWidth >= 8, bitWidth <= 256, bitWidth.isMultiple(of: 8) else { return nil }
        return bitWidth
    }

    static func fixedBytesLength(type: String) -> Int? {
        guard type.hasPrefix("bytes"),
              let length = Int(type.dropFirst(5)),
              length > 0,
              length <= 32 else { return nil }
        return length
    }

    static func twoPower(_ bitWidth: Int) -> BigUInt {
        switch bitWidth {
        case 255: return twoPower255
        case 256: return twoPower256
        default: return computedTwoPower(bitWidth)
        }
    }

    private static let twoPower255 = computedTwoPower(255)
    private static let twoPower256 = computedTwoPower(256)

    private static func computedTwoPower(_ bitWidth: Int) -> BigUInt {
        var result = BigUInt(1)
        for _ in 0..<bitWidth {
            result = result + result
        }
        return result
    }
}

enum EIP712 {
    struct Field {
        let name: String
        let type: String
    }

    static func digest(json: String) -> Data {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let typesObject = object["types"] as? [String: Any],
              let primaryType = object["primaryType"] as? String,
              let domain = object["domain"] as? [String: Any],
              let message = object["message"] as? [String: Any] else { return Data() }
        guard let types = parseTypes(typesObject),
              types.keys.contains(primaryType),
              types.keys.contains("EIP712Domain"),
              let domainHash = hashStruct(type: "EIP712Domain", value: domain, types: types),
              let messageHash = hashStruct(type: primaryType, value: message, types: types) else { return Data() }
        return WalletCrypto.keccak256(data: Data([0x19, 0x01]) + domainHash + messageHash)
    }

    private static func parseTypes(_ object: [String: Any]) -> [String: [Field]]? {
        var result = [String: [Field]]()
        for (name, value) in object {
            guard let fields = value as? [[String: Any]] else { return nil }
            var parsedFields = [Field]()
            parsedFields.reserveCapacity(fields.count)
            for field in fields {
                guard let fieldName = field["name"] as? String,
                      let fieldType = field["type"] as? String else { return nil }
                parsedFields.append(Field(name: fieldName, type: fieldType))
            }
            result[name] = parsedFields
        }
        return result
    }

    private static func hashStruct(type: String, value: [String: Any], types: [String: [Field]]) -> Data? {
        guard let fields = types[type],
              let typeEncoding = encodeType(type, types: types) else { return nil }
        var encoded = WalletCrypto.keccak256(data: Data(typeEncoding.utf8))
        for field in fields {
            guard let fieldValue = value[field.name],
                  let encodedValue = encodeValue(type: field.type, value: fieldValue, types: types) else { return nil }
            encoded += encodedValue
        }
        return WalletCrypto.keccak256(data: encoded)
    }

    private static func encodeType(_ primaryType: String, types: [String: [Field]]) -> String? {
        guard types[primaryType] != nil else { return nil }
        var dependencies = Set<String>()
        collectDependencies(of: primaryType, types: types, into: &dependencies)
        let deps = dependencies.filter { $0 != primaryType }.sorted()
        return ([primaryType] + deps).map { typeName in
            let fields = types[typeName] ?? []
            let fieldsText = fields.map { "\($0.type) \($0.name)" }.joined(separator: ",")
            return "\(typeName)(\(fieldsText))"
        }.joined()
    }

    private static func collectDependencies(of type: String,
                                            types: [String: [Field]],
                                            into dependencies: inout Set<String>) {
        let cleanType = baseType(type)
        guard dependencies.insert(cleanType).inserted,
              let fields = types[cleanType] else { return }
        for field in fields {
            let nestedType = baseType(field.type)
            if types[nestedType] != nil {
                collectDependencies(of: nestedType, types: types, into: &dependencies)
            }
        }
    }

    private static func encodeValue(type: String, value: Any, types: [String: [Field]]) -> Data? {
        if let arrayInfo = EthereumType.arrayInfo(type) {
            guard let array = value as? [Any] else { return nil }
            if let expectedCount = arrayInfo.count, array.count != expectedCount {
                return nil
            }
            var encoded = Data()
            encoded.reserveCapacity(array.count * 32)
            for item in array {
                guard let itemEncoded = encodeValue(type: arrayInfo.elementType, value: item, types: types) else { return nil }
                encoded.append(itemEncoded)
            }
            return WalletCrypto.keccak256(data: encoded)
        }

        if types[type] != nil {
            guard let object = value as? [String: Any] else { return nil }
            return hashStruct(type: type, value: object, types: types)
        }

        switch type {
        case "string":
            guard let string = value as? String else { return nil }
            return WalletCrypto.keccak256(data: Data(string.utf8))
        case "bytes":
            guard let data = hexDataValue(value) else { return nil }
            return WalletCrypto.keccak256(data: data)
        case "bool":
            guard let bool = boolValue(value) else { return nil }
            return Data(repeating: 0, count: 31) + Data([bool ? 1 : 0])
        case "address":
            guard let string = value as? String,
                  let address = EthereumCodec.parseAddress(string) else { return nil }
            return address.leftPadded(to: 32)
        default:
            if let length = EthereumType.fixedBytesLength(type: type) {
                // WalletCore accepts odd or undersized EIP-712 bytesN values and right-pads them.
                guard let data = hexDataValue(value, lenient: true),
                      !data.isEmpty,
                      data.count <= length else { return nil }
                return data + Data(repeating: 0, count: 32 - data.count)
            }
            if type.hasPrefix("uint") {
                guard let bitWidth = EthereumType.integerBitWidth(type: type, prefix: "uint"),
                      let unsigned = unsignedIntegerWordData(value, bitWidth: bitWidth) else { return nil }
                return unsigned.leftPadded(to: 32)
            }
            if type.hasPrefix("int") {
                guard let bitWidth = EthereumType.integerBitWidth(type: type, prefix: "int"),
                      let signed = signedIntegerWordData(value, bitWidth: bitWidth) else { return nil }
                return signed.leftPadded(to: 32)
            }
            return nil
        }
    }

    private static func baseType(_ type: String) -> String {
        var current = type
        while let arrayInfo = EthereumType.arrayInfo(current) {
            current = arrayInfo.elementType
        }
        return current
    }

    private static func hexDataValue(_ value: Any, lenient: Bool = false) -> Data? {
        guard let string = value as? String else { return nil }
        return WalletCrypto.hexData(lenient ? string.cleanEvenHex : string.cleanHex)
    }

    private static func boolValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func unsignedIntegerWordData(_ value: Any, bitWidth: Int) -> Data? {
        if boolValue(value) != nil { return nil }
        let integer: BigUInt
        if let int = value as? Int, int >= 0 {
            integer = BigUInt(UInt64(int))
        } else if let number = value as? NSNumber {
            guard let parsed = BigUInt(decimalString: number.stringValue) else { return nil }
            integer = parsed
        } else if let string = value as? String {
            if string.hasPrefix(String.hexPrefix),
               let data = WalletCrypto.hexData(string.cleanEvenHex),
               !data.isEmpty {
                integer = BigUInt(data: data)
            } else {
                guard let parsed = BigUInt(decimalString: string) else { return nil }
                integer = parsed
            }
        } else {
            return nil
        }
        guard integer < EthereumType.twoPower(bitWidth) else { return nil }
        return integer.toData()
    }

    private static func signedIntegerWordData(_ value: Any, bitWidth: Int) -> Data? {
        if boolValue(value) != nil { return nil }
        let signed: (negative: Bool, magnitude: BigUInt)
        if let int = value as? Int {
            signed = signedInteger(Int64(int))
        } else if let number = value as? NSNumber {
            guard let parsed = signedInteger(decimalString: number.stringValue) else { return nil }
            signed = parsed
        } else if let string = value as? String {
            guard let parsed = signedInteger(decimalString: string) else { return nil }
            signed = parsed
        } else {
            return nil
        }

        let signedBound = EthereumType.twoPower(bitWidth - 1)
        if signed.negative {
            guard signed.magnitude <= signedBound else { return nil }
            if signed.magnitude.isZero { return Data() }
            return (EthereumType.twoPower(256) - signed.magnitude).toData(minLength: 32)
        }
        guard signed.magnitude < signedBound else { return nil }
        return signed.magnitude.toData()
    }

    private static func signedInteger(_ value: Int64) -> (negative: Bool, magnitude: BigUInt) {
        if value >= 0 {
            return (false, BigUInt(UInt64(value)))
        }
        if value == Int64.min {
            return (true, BigUInt(UInt64(Int64.max)) + BigUInt(1))
        }
        return (true, BigUInt(UInt64(-value)))
    }

    private static func signedInteger(decimalString: String) -> (negative: Bool, magnitude: BigUInt)? {
        if decimalString.hasPrefix("-"),
           let magnitude = BigUInt(decimalString: String(decimalString.dropFirst())) {
            return (true, magnitude)
        }
        if let magnitude = BigUInt(decimalString: decimalString) {
            return (false, magnitude)
        }
        return nil
    }

}

enum EthereumABI {
    private struct Parameter {
        let name: String
        let type: String
        let components: [Parameter]

        var canonicalType: String {
            if type == "tuple" {
                return "(" + components.map(\.canonicalType).joined(separator: ",") + ")"
            }
            if let suffix = arraySuffix(type), type.hasPrefix("tuple") {
                return "(" + components.map(\.canonicalType).joined(separator: ",") + ")" + suffix
            }
            return type
        }

        var isDynamic: Bool {
            if type == "string" || type == "bytes" { return true }
            if let array = EthereumType.arrayInfo(type) {
                if array.count == nil { return true }
                return Parameter(name: name, type: array.elementType, components: components).isDynamic
            }
            if type == "tuple" {
                return components.contains(where: \.isDynamic)
            }
            return false
        }
    }

    private enum DecodedValue {
        case string(String)
        case bool(Bool)
        case array([DecodedValue])
        case tuple([DecodedComponent])

        var jsonValue: JSONValue {
            switch self {
            case let .string(value):
                return .string(value)
            case let .bool(value):
                return .bool(value)
            case let .array(values):
                return .array(values.map(\.jsonValue))
            case let .tuple(components):
                return .array(components.map { .object($0.jsonObject) })
            }
        }
    }

    private struct DecodedComponent {
        let parameter: Parameter
        let value: DecodedValue

        var jsonObject: [(String, JSONValue)] {
            var result: [(String, JSONValue)] = [
                ("name", .string(parameter.name)),
                ("type", .string(parameter.type)),
            ]
            switch value {
            case let .tuple(components):
                result.append(("components", .array(components.map { .object($0.jsonObject) })))
            default:
                result.append(("value", value.jsonValue))
            }
            return result
        }
    }

    private enum JSONValue {
        case string(String)
        case bool(Bool)
        case array([JSONValue])
        case object([(String, JSONValue)])

        var json: String {
            switch self {
            case let .string(value):
                return jsonString(value)
            case let .bool(value):
                return value ? "true" : "false"
            case let .array(values):
                return "[" + values.map(\.json).joined(separator: ",") + "]"
            case let .object(pairs):
                return "{" + pairs.map { jsonString($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
            }
        }
    }

    static func decodeCall(data: Data, abi: String) -> String? {
        guard data.count >= 4,
              let abiData = abi.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: abiData)) as? [String: Any] else { return nil }
        let selector = WalletCrypto.hexString(data.prefixData(4))
        guard let function = object[selector] as? [String: Any],
              let name = function["name"] as? String,
              let inputObjects = function["inputs"] as? [[String: Any]] else { return nil }
        let inputs = inputObjects.compactMap(parseParameter)
        guard inputs.count == inputObjects.count else { return nil }
        let payload = Data(data.dropFirst(4))
        var components = [DecodedComponent]()
        var cursor = 0
        for input in inputs {
            guard let value = decode(parameter: input, payload: payload, position: cursor, head: true, base: 0) else { return nil }
            components.append(DecodedComponent(parameter: input, value: value))
            guard let size = staticSize(input),
                  let nextCursor = checkedAdd(cursor, size) else { return nil }
            cursor = nextCursor
        }
        let signature = inputs.map(\.canonicalType).joined(separator: ",")
        return JSONValue.object([
            ("function", .string("\(name)(\(signature))")),
            ("inputs", .array(components.map { .object($0.jsonObject) })),
        ]).json
    }

    private static func parseParameter(_ object: [String: Any]) -> Parameter? {
        guard let name = object["name"] as? String,
              let type = object["type"] as? String else { return nil }
        let componentObjects = object["components"] as? [[String: Any]]
        let components = componentObjects?.compactMap(parseParameter) ?? []
        if let componentObjects, components.count != componentObjects.count {
            return nil
        }
        return Parameter(name: name, type: type, components: components)
    }

    private static func decode(parameter: Parameter, payload: Data, position: Int, head: Bool, base: Int) -> DecodedValue? {
        if parameter.isDynamic, head {
            guard let offset = intValue(word(payload, position: position)),
                  let dynamicPosition = checkedAdd(base, offset) else { return nil }
            return decodeDynamic(parameter: parameter, payload: payload, position: dynamicPosition)
        }
        if parameter.isDynamic {
            return decodeDynamic(parameter: parameter, payload: payload, position: position)
        }
        return decodeStatic(parameter: parameter, payload: payload, position: position)
    }

    private static func decodeStatic(parameter: Parameter, payload: Data, position: Int) -> DecodedValue? {
        if let array = EthereumType.arrayInfo(parameter.type), let count = array.count {
            let element = Parameter(name: parameter.name, type: array.elementType, components: parameter.components)
            guard let elementSize = staticSize(element),
                  let totalSize = checkedMultiply(count, elementSize),
                  rangeIsValid(start: position, length: totalSize, count: payload.count) else { return nil }
            var values = [DecodedValue]()
            for index in 0..<count {
                guard let offset = checkedMultiply(index, elementSize),
                      let elementPosition = checkedAdd(position, offset),
                      let value = decode(parameter: element,
                                         payload: payload,
                                         position: elementPosition,
                                         head: element.isDynamic,
                                         base: position) else {
                    return nil
                }
                values.append(value)
            }
            return .array(values)
        }
        if parameter.type == "tuple" {
            return decodeTuple(parameter: parameter, payload: payload, position: position)
        }
        guard let word = word(payload, position: position) else { return nil }
        if parameter.type == "address" {
            guard word.prefix(12).allSatisfy({ $0 == 0 }) else { return nil }
            return .string(EthereumCodec.checksumAddress(word.suffixData(20)))
        }
        if parameter.type == "bool" {
            guard word.prefix(31).allSatisfy({ $0 == 0 }),
                  let value = word.last,
                  value <= 1 else { return nil }
            return .bool(value == 1)
        }
        if parameter.type.hasPrefix("uint") {
            guard let value = unsignedDecimalString(word, type: parameter.type) else { return nil }
            return .string(value)
        }
        if parameter.type.hasPrefix("int") {
            guard let value = signedDecimalString(word, type: parameter.type) else { return nil }
            return .string(value)
        }
        if let length = EthereumType.fixedBytesLength(type: parameter.type) {
            guard word.dropFirst(length).allSatisfy({ $0 == 0 }) else { return nil }
            return .string(String.hexPrefix + WalletCrypto.hexString(word.prefixData(length)))
        }
        return nil
    }

    private static func decodeDynamic(parameter: Parameter, payload: Data, position: Int) -> DecodedValue? {
        if parameter.type == "string" || parameter.type == "bytes" {
            guard let length = intValue(word(payload, position: position)),
                  let contentStart = checkedAdd(position, 32),
                  rangeIsValid(start: contentStart, length: length, count: payload.count) else { return nil }
            let bytes = payload.subdata(in: contentStart..<contentStart + length)
            if parameter.type == "string" {
                return .string(String(decoding: bytes, as: UTF8.self))
            }
            return .string(String.hexPrefix + WalletCrypto.hexString(bytes))
        }
        if let array = EthereumType.arrayInfo(parameter.type) {
            let count: Int
            let elementsStart: Int
            let offsetBase: Int
            if let fixedCount = array.count {
                count = fixedCount
                elementsStart = position
                offsetBase = position
            } else {
                guard let dynamicCount = intValue(word(payload, position: position)),
                      let dynamicElementsStart = checkedAdd(position, 32) else { return nil }
                count = dynamicCount
                elementsStart = dynamicElementsStart
                offsetBase = dynamicElementsStart
            }
            let element = Parameter(name: parameter.name, type: array.elementType, components: parameter.components)
            guard let elementSize = staticSize(element),
                  let headSize = checkedMultiply(count, elementSize),
                  rangeIsValid(start: elementsStart, length: headSize, count: payload.count) else { return nil }
            var values = [DecodedValue]()
            for index in 0..<count {
                guard let offset = checkedMultiply(index, elementSize),
                      let elementPosition = checkedAdd(elementsStart, offset),
                      let value = decode(parameter: element,
                                         payload: payload,
                                         position: elementPosition,
                                         head: element.isDynamic,
                                         base: offsetBase) else { return nil }
                values.append(value)
            }
            return .array(values)
        }
        if parameter.type == "tuple" {
            return decodeTuple(parameter: parameter, payload: payload, position: position)
        }
        return nil
    }

    private static func decodeTuple(parameter: Parameter, payload: Data, position: Int) -> DecodedValue? {
        var components = [DecodedComponent]()
        var cursor = position
        for component in parameter.components {
            guard let value = decode(parameter: component,
                                     payload: payload,
                                     position: cursor,
                                     head: component.isDynamic,
                                     base: position) else { return nil }
            components.append(DecodedComponent(parameter: component, value: value))
            guard let size = staticSize(component),
                  let nextCursor = checkedAdd(cursor, size) else { return nil }
            cursor = nextCursor
        }
        return .tuple(components)
    }

    private static func staticSize(_ parameter: Parameter) -> Int? {
        if parameter.isDynamic { return 32 }
        if let array = EthereumType.arrayInfo(parameter.type), let count = array.count {
            let element = Parameter(name: parameter.name, type: array.elementType, components: parameter.components)
            guard let elementSize = staticSize(element) else { return nil }
            return checkedMultiply(elementSize, count)
        }
        if parameter.type == "tuple" {
            var total = 0
            for component in parameter.components {
                guard let size = staticSize(component),
                      let nextTotal = checkedAdd(total, size) else { return nil }
                total = nextTotal
            }
            return total
        }
        return 32
    }

    private static func word(_ payload: Data, position: Int) -> Data? {
        guard rangeIsValid(start: position, length: 32, count: payload.count) else { return nil }
        return payload.subdata(in: position..<position + 32)
    }

    private static func intValue(_ word: Data?) -> Int? {
        guard let word, word.count == 32, word.prefix(24).allSatisfy({ $0 == 0 }) else { return nil }
        var value: UInt64 = 0
        for byte in word.suffix(8) {
            value = (value << 8) | UInt64(byte)
        }
        guard value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    private static func unsignedDecimalString(_ data: Data, type: String) -> String? {
        guard data.count == 32,
              let bitWidth = EthereumType.integerBitWidth(type: type, prefix: "uint") else { return nil }
        let value = BigUInt(data: data)
        guard value < EthereumType.twoPower(bitWidth) else { return nil }
        return value.description
    }

    private static func signedDecimalString(_ data: Data, type: String) -> String? {
        guard data.count == 32,
              let bitWidth = EthereumType.integerBitWidth(type: type, prefix: "int") else { return nil }
        let isNegative = (data.first ?? 0) & 0x80 != 0
        let value = BigUInt(data: data)
        let signedBound = EthereumType.twoPower(bitWidth - 1)
        guard isNegative else {
            guard value < signedBound else { return nil }
            return value.description
        }
        let magnitude = EthereumType.twoPower(256) - value
        guard magnitude <= signedBound else { return nil }
        return "-" + magnitude.description
    }

    private static func arraySuffix(_ type: String) -> String? {
        guard let open = type.firstIndex(of: "[") else { return nil }
        return String(type[open...])
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow, result.partialValue >= 0 else { return nil }
        return result.partialValue
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow, result.partialValue >= 0 else { return nil }
        return result.partialValue
    }

    private static func rangeIsValid(start: Int, length: Int, count: Int) -> Bool {
        guard start >= 0, length >= 0, start <= count else { return false }
        return length <= count - start
    }

    private static func jsonString(_ value: String) -> String {
        return "\"" + jsonEscaped(value) + "\""
    }

    private static func jsonEscaped(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\u{08}": output += "\\b"
            case "\u{0c}": output += "\\f"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case let control where control.value < 0x20:
                let hex = String(control.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}

enum EthereumCodec {
    static func checksumAddress(_ address: Data) -> String {
        guard address.count == 20 else { return "" }
        let lowerHex = WalletCrypto.hexString(address)
        let hash = WalletCrypto.hexString(WalletCrypto.keccak256(data: Data(lowerHex.utf8)))
        var output = "0x"
        for (index, scalar) in lowerHex.enumerated() {
            guard let nibble = Int(String(hash[hash.index(hash.startIndex, offsetBy: index)]), radix: 16) else {
                output.append(scalar)
                continue
            }
            output.append(nibble >= 8 ? Character(String(scalar).uppercased()) : scalar)
        }
        return output
    }

    static func parseAddress(_ string: String) -> Data? {
        let raw = string.cleanHex
        guard raw.count == 40, let data = WalletCrypto.hexData(raw), data.count == 20 else { return nil }
        return data
    }
}

enum RLP {
    enum Item {
        case bytes(Data)
        case list([Item])
    }

    static func encode(_ item: Item) -> Data {
        switch item {
        case let .bytes(data):
            if data.count == 1, let byte = data.first, byte < 0x80 {
                return Data([byte])
            }
            return encodeLength(data.count, offset: 0x80) + data
        case let .list(items):
            let encodedItems = items.map(encode)
            let payloadLength = encodedItems.reduce(0) { $0 + $1.count }
            var payload = Data()
            payload.reserveCapacity(payloadLength)
            for encodedItem in encodedItems {
                payload.append(encodedItem)
            }
            return encodeLength(payload.count, offset: 0xc0) + payload
        }
    }

    static func bytes(_ data: Data) -> Item {
        return .bytes(data)
    }

    static func integer(_ data: Data) -> Item {
        return .bytes(data.removingLeadingZeroBytes())
    }

    private static func encodeLength(_ length: Int, offset: UInt8) -> Data {
        if length < 56 {
            return Data([offset + UInt8(length)])
        }
        let lengthBytes = BigUInt(UInt64(length)).toData()
        return Data([offset + 55 + UInt8(lengthBytes.count)]) + lengthBytes
    }
}

enum EthereumTransactionSigner {
    static func signLegacy(chainID: Data,
                           nonce: Data,
                           gasPrice: Data,
                           gasLimit: Data,
                           toAddress: String,
                           privateKey: WalletPrivateKey,
                           amount: Data,
                           data: Data) -> Data? {
        let to: Data
        if toAddress.isEmpty {
            to = Data()
        } else {
            guard let parsedTo = EthereumCodec.parseAddress(toAddress) else { return nil }
            to = parsedTo
        }

        let chain = chainID.removingLeadingZeroBytes()
        let signingFields: [RLP.Item] = [
            RLP.integer(nonce),
            RLP.integer(gasPrice),
            RLP.integer(gasLimit),
            RLP.bytes(to),
            RLP.integer(amount),
            RLP.bytes(data),
            RLP.integer(chain),
            RLP.bytes(Data()),
            RLP.bytes(Data()),
        ]

        let digest = WalletCrypto.keccak256(data: RLP.encode(.list(signingFields)))
        guard let signature = privateKey.sign(digest: digest, coin: .ethereum), signature.count == 65 else { return nil }
        let recovery = UInt64(signature[signature.index(signature.startIndex, offsetBy: 64)])
        guard let v = legacySignatureV(chainID: chain, recovery: recovery) else { return nil }
        let signedFields: [RLP.Item] = [
            RLP.integer(nonce),
            RLP.integer(gasPrice),
            RLP.integer(gasLimit),
            RLP.bytes(to),
            RLP.integer(amount),
            RLP.bytes(data),
            RLP.integer(v),
            RLP.integer(signature.prefixData(32)),
            RLP.integer(Data(signature.dropFirst(32).prefix(32))),
        ]
        return RLP.encode(.list(signedFields))
    }

    static func legacySignatureV(chainID: Data, recovery: UInt64) -> Data? {
        guard recovery <= 1 else { return nil }
        let chain = chainID.removingLeadingZeroBytes()
        if chain.isEmpty {
            return BigUInt(27 + recovery).toData()
        }
        return ((BigUInt(data: chain) * BigUInt(2)) + BigUInt(35 + recovery)).toData()
    }
}

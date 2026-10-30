import Foundation

public enum EthereumABI {
    struct Limits: Sendable {
        var abiBytes = 262_144
        var calldataBytes = 1_048_576
        var depth = 32
        var schemaNodes = 1_024
        var decodedValues = 16_384
        var work = 65_536
        var decodedStringBytes = 1_048_576
        var outputBytes = 1_048_576
    }

    enum DecodingFailure: Error, Equatable {
        case invalid, limitExceeded
    }

    private struct Parameter {
        let name: String
        let type: String
        let components: [Parameter]
        let node: TypeNode
    }

    private struct TypeNode {
        indirect enum Kind {
            case scalar(String)
            case array(TypeNode, Int?)
            case tuple([Parameter])
        }

        let kind: Kind
        let isDynamic: Bool
        let headSize: Int
    }

    private enum DecodedValue {
        case string(String)
        case bool(Bool)
        case array([DecodedValue])
        case tuple([DecodedComponent])
    }

    private struct DecodedComponent {
        let parameter: Parameter
        let value: DecodedValue
    }

    private struct Budget {
        let limits: Limits
        let checkCancellation: @Sendable () throws -> Void
        var schemaNodes: Int
        var decodedValues: Int
        var work: Int
        var stringBytes: Int
        var outputBytes: Int

        init(limits: Limits, checkCancellation: @escaping @Sendable () throws -> Void) throws {
            guard [limits.abiBytes, limits.calldataBytes, limits.depth, limits.schemaNodes,
                   limits.decodedValues, limits.work, limits.decodedStringBytes, limits.outputBytes]
                .allSatisfy({ $0 >= 0 && $0 < Int.max }) else { throw DecodingFailure.limitExceeded }
            self.limits = limits
            self.checkCancellation = checkCancellation
            schemaNodes = limits.schemaNodes
            decodedValues = limits.decodedValues
            work = limits.work
            stringBytes = limits.decodedStringBytes
            outputBytes = limits.outputBytes
        }

        mutating func step() throws {
            try checkCancellation()
            guard work > 0 else { throw DecodingFailure.limitExceeded }
            work -= 1
        }

        mutating func schema(depth: Int) throws {
            try step()
            guard depth <= limits.depth, schemaNodes > 0 else { throw DecodingFailure.limitExceeded }
            schemaNodes -= 1
        }

        mutating func value(depth: Int) throws {
            try step()
            guard depth <= limits.depth, decodedValues > 0 else { throw DecodingFailure.limitExceeded }
            decodedValues -= 1
        }

        mutating func string(_ bytes: Int) throws {
            try checkCancellation()
            guard bytes >= 0, bytes <= stringBytes else { throw DecodingFailure.limitExceeded }
            stringBytes -= bytes
        }

        mutating func output(_ bytes: Int) throws {
            try checkCancellation()
            guard bytes >= 0, bytes <= outputBytes else { throw DecodingFailure.limitExceeded }
            outputBytes -= bytes
        }
    }

    public static func decodeCall(data: Data, abi: String) -> String? {
        try? checkedDecodeCall(data: data, abi: abi)
    }

    static func checkedDecodeCall(
        data: Data,
        abi: String,
        limits: Limits = Limits(),
        checkCancellation: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) throws -> String {
        var computation = Computation(budget: try Budget(limits: limits, checkCancellation: checkCancellation))
        return try computation.decodeCall(data: data, abi: abi)
    }

    private struct Computation {
        var budget: Budget
        var output = Data()

        mutating func decodeCall(data: Data, abi: String) throws -> String {
            try budget.step()
            guard data.count <= budget.limits.calldataBytes,
                  abi.utf8.prefix(budget.limits.abiBytes + 1).count <= budget.limits.abiBytes else {
                throw DecodingFailure.limitExceeded
            }
            guard data.count >= 4 else { throw DecodingFailure.invalid }
            let abiData = Data(abi.utf8)
            try validateJSONDepth(abiData)
            guard let object = (try? JSONSerialization.jsonObject(with: abiData)) as? [String: Any] else {
                throw DecodingFailure.invalid
            }
            try budget.step()
            let selector = WalletEncoding.hexString(data.prefixData(4))
            guard let function = object[selector] as? [String: Any],
                  let name = function["name"] as? String,
                  let inputObjects = function["inputs"] as? [[String: Any]] else { throw DecodingFailure.invalid }
            guard inputObjects.count <= budget.schemaNodes else { throw DecodingFailure.limitExceeded }
            var inputs = [Parameter]()
            for object in inputObjects { inputs.append(try parseParameter(object, depth: 0)) }
            let payload = Data(data.dropFirst(4))
            var components = [DecodedComponent]()
            var cursor = 0
            for input in inputs {
                let value = try decode(input.node, payload: payload, position: cursor, head: true, base: 0, depth: 0)
                components.append(DecodedComponent(parameter: input, value: value))
                guard let next = checkedAdd(cursor, input.node.headSize) else { throw DecodingFailure.invalid }
                cursor = next
            }
            try append("{\"function\":\"")
            try escaped(name)
            try append("(")
            for (index, input) in inputs.enumerated() {
                if index > 0 { try append(",") }
                try canonicalType(input)
            }
            try append(")\",\"inputs\":")
            try writeComponents(components)
            try append("}")
            try budget.checkCancellation()
            let result = String(decoding: output, as: UTF8.self)
            try budget.checkCancellation()
            return result
        }

        mutating func validateJSONDepth(_ data: Data) throws {
            var depth = 0
            var inString = false
            var escaped = false
            for (offset, byte) in data.enumerated() {
                if offset.isMultiple(of: 1_024) { try budget.step() }
                if inString {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { inString = false }
                } else if byte == 34 {
                    inString = true
                } else if byte == 91 || byte == 123 {
                    depth += 1
                    guard depth <= 128 else { throw DecodingFailure.limitExceeded }
                } else if byte == 93 || byte == 125 {
                    depth -= 1
                    guard depth >= 0 else { throw DecodingFailure.invalid }
                }
            }
            guard depth == 0, !inString else { throw DecodingFailure.invalid }
        }

        mutating func parseParameter(_ object: [String: Any], depth: Int) throws -> Parameter {
            try budget.schema(depth: depth)
            guard let name = object["name"] as? String,
                  let type = object["type"] as? String else { throw DecodingFailure.invalid }
            var base = type
            var arrays = [Int?]()
            while let array = EthereumType.arrayInfo(base) {
                try budget.schema(depth: depth + arrays.count + 1)
                arrays.append(array.count)
                base = array.elementType
            }
            let componentObjects = object["components"] as? [[String: Any]] ?? []
            guard componentObjects.count <= budget.schemaNodes else { throw DecodingFailure.limitExceeded }
            var components = [Parameter]()
            for component in componentObjects {
                components.append(try parseParameter(component, depth: depth + arrays.count + 1))
            }
            var node: TypeNode
            if base == "tuple" {
                let dynamic = components.contains { $0.node.isDynamic }
                var size = 0
                if !dynamic {
                    for component in components {
                        try budget.step()
                        guard let next = checkedAdd(size, component.node.headSize) else { throw DecodingFailure.invalid }
                        size = next
                    }
                }
                node = TypeNode(kind: .tuple(components), isDynamic: dynamic, headSize: dynamic ? 32 : size)
            } else {
                node = TypeNode(kind: .scalar(base), isDynamic: base == "string" || base == "bytes", headSize: 32)
            }
            for count in arrays.reversed() {
                try budget.step()
                let dynamic = count == nil || node.isDynamic
                let size: Int
                if dynamic { size = 32 }
                else {
                    guard let count, let product = checkedMultiply(count, node.headSize) else { throw DecodingFailure.invalid }
                    size = product
                }
                node = TypeNode(kind: .array(node, count), isDynamic: dynamic, headSize: size)
            }
            return Parameter(name: name, type: type, components: components, node: node)
        }

        mutating func decode(
            _ node: TypeNode, payload: Data, position rawPosition: Int, head: Bool, base: Int, depth: Int
        ) throws -> DecodedValue {
            try budget.value(depth: depth)
            let position: Int
            if node.isDynamic && head {
                guard let offset = intValue(word(payload, position: rawPosition)),
                      let resolved = checkedAdd(base, offset) else { throw DecodingFailure.invalid }
                position = resolved
            } else { position = rawPosition }
            switch node.kind {
            case .array(let element, let fixedCount):
                let count: Int
                let start: Int
                if let fixedCount { count = fixedCount; start = position }
                else {
                    guard let decoded = intValue(word(payload, position: position)),
                          let elements = checkedAdd(position, 32) else { throw DecodingFailure.invalid }
                    count = decoded
                    start = elements
                }
                guard count <= budget.decodedValues else { throw DecodingFailure.limitExceeded }
                guard let size = checkedMultiply(count, element.headSize),
                      rangeIsValid(start: start, length: size, count: payload.count) else { throw DecodingFailure.invalid }
                var values = [DecodedValue]()
                var cursor = start
                for _ in 0..<count {
                    let value = try decode(element, payload: payload, position: cursor, head: true, base: start, depth: depth + 1)
                    values.append(value)
                    guard let next = checkedAdd(cursor, element.headSize) else { throw DecodingFailure.invalid }
                    cursor = next
                }
                return .array(values)
            case .tuple(let parameters):
                guard parameters.count <= budget.decodedValues else { throw DecodingFailure.limitExceeded }
                var components = [DecodedComponent]()
                var cursor = position
                for parameter in parameters {
                    let value = try decode(parameter.node, payload: payload, position: cursor, head: true, base: position, depth: depth + 1)
                    components.append(DecodedComponent(parameter: parameter, value: value))
                    guard let next = checkedAdd(cursor, parameter.node.headSize) else { throw DecodingFailure.invalid }
                    cursor = next
                }
                return .tuple(components)
            case .scalar(let type):
                return try decodeScalar(type: type, payload: payload, position: position)
            }
        }

        mutating func decodeScalar(type: String, payload: Data, position: Int) throws -> DecodedValue {
            if type == "string" || type == "bytes" {
                guard let length = intValue(word(payload, position: position)),
                      let start = checkedAdd(position, 32),
                      rangeIsValid(start: start, length: length, count: payload.count) else { throw DecodingFailure.invalid }
                let bytes = payload[start..<start + length]
                if type == "string" {
                    var iterator = bytes.makeIterator()
                    var decoder = Unicode.UTF8()
                    var count = 0
                    var scalars = 0
                    while true {
                        if scalars.isMultiple(of: 1_024) { try budget.step() }
                        scalars += 1
                        switch decoder.decode(&iterator) {
                        case .scalarValue(let scalar):
                            count += scalar.value <= 0x7f ? 1 : scalar.value <= 0x7ff ? 2 : scalar.value <= 0xffff ? 3 : 4
                        case .error: count += 3
                        case .emptyInput:
                            try budget.string(count)
                            return .string(String(decoding: bytes, as: UTF8.self))
                        }
                        guard count <= budget.stringBytes else { throw DecodingFailure.limitExceeded }
                    }
                }
                guard let hexBytes = checkedMultiply(length, 2), let count = checkedAdd(hexBytes, 2) else {
                    throw DecodingFailure.limitExceeded
                }
                try budget.string(count)
                return .string(String.hexPrefix + WalletEncoding.hexString(bytes))
            }
            guard let word = word(payload, position: position) else { throw DecodingFailure.invalid }
            if type == "bool" {
                guard word.prefix(31).allSatisfy({ $0 == 0 }), let value = word.last, value <= 1 else {
                    throw DecodingFailure.invalid
                }
                return .bool(value == 1)
            }
            let value: String
            if type == "address" {
                guard word.prefix(12).allSatisfy({ $0 == 0 }) else { throw DecodingFailure.invalid }
                try budget.string(42)
                return .string(EthereumCodec.checksumAddress(word.suffixData(20)))
            } else if type.hasPrefix("uint") {
                guard let decoded = unsignedDecimalString(word, type: type) else { throw DecodingFailure.invalid }
                value = decoded
            } else if type.hasPrefix("int") {
                guard let decoded = signedDecimalString(word, type: type) else { throw DecodingFailure.invalid }
                value = decoded
            } else if let length = EthereumType.fixedBytesLength(type: type) {
                guard word.dropFirst(length).allSatisfy({ $0 == 0 }) else { throw DecodingFailure.invalid }
                try budget.string(length * 2 + 2)
                return .string(String.hexPrefix + WalletEncoding.hexString(word.prefixData(length)))
            } else { throw DecodingFailure.invalid }
            try budget.string(value.utf8.count)
            return .string(value)
        }

        mutating func writeComponents(_ components: [DecodedComponent]) throws {
            try append("[")
            for (index, component) in components.enumerated() {
                try budget.step()
                if index > 0 { try append(",") }
                try append("{\"name\":")
                try string(component.parameter.name)
                try append(",\"type\":")
                try string(component.parameter.type)
                if case .tuple(let nested) = component.value {
                    try append(",\"components\":")
                    try writeComponents(nested)
                } else {
                    try append(",\"value\":")
                    try write(component.value)
                }
                try append("}")
            }
            try append("]")
        }

        mutating func write(_ value: DecodedValue) throws {
            try budget.step()
            switch value {
            case .string(let value): try string(value)
            case .bool(let value): try append(value ? "true" : "false")
            case .array(let values):
                try append("[")
                for (index, value) in values.enumerated() {
                    if index > 0 { try append(",") }
                    try write(value)
                }
                try append("]")
            case .tuple(let components): try writeComponents(components)
            }
        }

        mutating func canonicalType(_ parameter: Parameter) throws {
            try budget.step()
            if parameter.type == "tuple" || parameter.type.hasPrefix("tuple") && parameter.type.contains("[") {
                try append("(")
                for (index, component) in parameter.components.enumerated() {
                    if index > 0 { try append(",") }
                    try canonicalType(component)
                }
                try append(")")
                if let bracket = parameter.type.firstIndex(of: "[") { try escaped(String(parameter.type[bracket...])) }
            } else { try escaped(parameter.type) }
        }

        mutating func string(_ value: String) throws {
            try append("\"")
            try escaped(value)
            try append("\"")
        }

        mutating func escaped(_ value: String) throws {
            for (index, scalar) in value.unicodeScalars.enumerated() {
                if index.isMultiple(of: 1_024) { try budget.step() }
                switch scalar {
                case "\"": try append("\\\"")
                case "\\": try append("\\\\")
                case "\u{08}": try append("\\b")
                case "\u{0c}": try append("\\f")
                case "\n": try append("\\n")
                case "\r": try append("\\r")
                case "\t": try append("\\t")
                case let control where control.value < 0x20:
                    let hex = String(control.value, radix: 16)
                    try append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
                default: try append(String(scalar))
                }
            }
        }

        mutating func append(_ value: String) throws {
            try budget.output(value.utf8.count)
            output.append(contentsOf: value.utf8)
        }
    }

    private static func word(_ payload: Data, position: Int) -> Data? {
        guard rangeIsValid(start: position, length: 32, count: payload.count) else { return nil }
        return payload.subdata(in: position..<position + 32)
    }

    private static func intValue(_ word: Data?) -> Int? {
        guard let word, word.count == 32, word.prefix(24).allSatisfy({ $0 == 0 }) else { return nil }
        var value: UInt64 = 0
        for byte in word.suffix(8) { value = (value << 8) | UInt64(byte) }
        return value <= UInt64(Int.max) ? Int(value) : nil
    }

    private static func unsignedDecimalString(_ data: Data, type: String) -> String? {
        guard data.count == 32, let width = EthereumType.integerBitWidth(type: type, prefix: "uint") else { return nil }
        let value = BigUInt(data: data)
        return value < EthereumType.twoPower(width) ? value.description : nil
    }

    private static func signedDecimalString(_ data: Data, type: String) -> String? {
        guard data.count == 32, let width = EthereumType.integerBitWidth(type: type, prefix: "int") else { return nil }
        let negative = (data.first ?? 0) & 0x80 != 0
        let value = BigUInt(data: data)
        let bound = EthereumType.twoPower(width - 1)
        guard negative else { return value < bound ? value.description : nil }
        let magnitude = EthereumType.twoPower(256) - value
        return magnitude <= bound ? "-" + magnitude.description : nil
    }

    private static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return !result.overflow && result.partialValue >= 0 ? result.partialValue : nil
    }

    private static func checkedMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return !result.overflow && result.partialValue >= 0 ? result.partialValue : nil
    }

    private static func rangeIsValid(start: Int, length: Int, count: Int) -> Bool {
        start >= 0 && length >= 0 && start <= count && length <= count - start
    }
}

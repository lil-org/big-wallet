import Darwin
import Foundation

private enum OracleFailure: Error, CustomStringConvertible {
    case usage
    case malformedEnvelope(line: Int)
    case unknownType(String, line: Int)
    case inconsistentValidation(id: Int)

    var description: String {
        switch self {
        case .usage:
            return "Usage: ProtocolFuzzOracle [--list-types]"
        case .malformedEnvelope(let line):
            return "Malformed input envelope on line \(line)"
        case .unknownType(let type, let line):
            return "Unknown contract \(type) on line \(line)"
        case .inconsistentValidation(let id):
            return "WireProtocol.validate and WireProtocol.decode disagree for case \(id)"
        }
    }
}

private struct OracleInput: Decodable {
    let id: Int
    let type: String
    let json: String

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        guard Set(container.allKeys.map(\.stringValue)) == ["id", "type", "json"] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected id, type, and json"
            ))
        }
        id = try container.decode(Int.self, forKey: Key(stringValue: "id")!)
        type = try container.decode(String.self, forKey: Key(stringValue: "type")!)
        json = try container.decode(String.self, forKey: Key(stringValue: "json")!)
    }
}

private struct OracleOutput: Encodable {
    let id: Int
    let parsed: Bool
    let valid: Bool
    let objectValid: Bool
    let decodedJSON: String?
    let objectJSON: String?
    let dataValid: Bool
    let dataJSON: String?
    let dataObjectValid: Bool
    let dataObjectJSON: String?
}

@main
private struct ProtocolFuzzOracle {
    static func main() {
        do {
            try run()
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data(
                "ProtocolFuzzOracle: \(error)\n".utf8
            ))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list-types"] {
            try write(WireProtocol.Message.allCases.map(\.rawValue))
            return
        }
        guard arguments.isEmpty else { throw OracleFailure.usage }

        var lineNumber = 0
        while let line = readLine(strippingNewline: true) {
            lineNumber += 1
            guard let input = try? JSONDecoder().decode(OracleInput.self, from: Data(line.utf8)) else {
                throw OracleFailure.malformedEnvelope(line: lineNumber)
            }
            guard let contract = WireProtocol.Message(rawValue: input.type) else {
                throw OracleFailure.unknownType(input.type, line: lineNumber)
            }
            try write(evaluate(input, contract: contract))
        }
    }

    private static func evaluate(
        _ input: OracleInput,
        contract: WireProtocol.Message
    ) throws -> OracleOutput {
        let data = Data(input.json.utf8)
        guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            return OracleOutput(
                id: input.id, parsed: false, valid: false, objectValid: false,
                decodedJSON: nil, objectJSON: nil,
                dataValid: false, dataJSON: nil, dataObjectValid: false, dataObjectJSON: nil
            )
        }
        let valid = WireProtocol.validate(contract, value: value)
        let decoded = WireProtocol.decode(contract, value: value)
        guard valid == (decoded != nil) else {
            throw OracleFailure.inconsistentValidation(id: input.id)
        }
        let object = WireProtocol.object(contract, value: value)
        let dataValue = WireProtocol.decode(contract, from: data)
        let dataObject = WireProtocol.object(contract, from: data)
        return OracleOutput(
            id: input.id,
            parsed: true,
            valid: valid,
            objectValid: object != nil,
            decodedJSON: try decoded.map(snapshotJSON),
            objectJSON: try object.map { try snapshotJSON($0.json) },
            dataValid: dataValue != nil,
            dataJSON: try dataValue.map(snapshotJSON),
            dataObjectValid: dataObject != nil,
            dataObjectJSON: try dataObject.map { try snapshotJSON($0.json) }
        )
    }

    private static func snapshotJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func write<Value: Encodable>(_ value: Value) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0a)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

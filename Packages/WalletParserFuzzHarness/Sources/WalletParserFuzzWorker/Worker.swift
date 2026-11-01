import CryptoKit
import Darwin
import Foundation
import ParserFuzzCanaries
@testable import WalletAuthority
@testable import WalletDomain

private struct Request: Decodable {
    let id: Int
    let mode: String
    let inputBase64: String?
    let secondaryBase64: String?
    let relation: String?
    let fixtureID: String?
    let mutation: String?
    let mutationIndex: Int?
    let entryPoint: String?
}

private struct InvariantFailure: Error {
    let code: String
}

@main
private enum Worker {
    static let modes = ["keystore", "eip712", "solana", "decrypt"]
    static let maximumLineBytes = 3 * 1_024 * 1_024

    static func main() throws {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--fixture-identity" {
            let fixture = try fixtureData()
            try write(["version": 1, "path": fixture.url.path, "sha256": hex(Data(SHA256.hash(data: fixture.data))), "bytes": fixture.data.count])
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--canary" {
            runCanary(CommandLine.arguments[2])
            return
        }
        guard CommandLine.arguments.count == 1 else { throw InvariantFailure(code: "arguments") }
        var pending = Data()
        var input = [UInt8](repeating: 0, count: 16_384)
        while true {
            let (count, readError) = input.withUnsafeMutableBytes { bytes in
                let count = Darwin.read(STDIN_FILENO, bytes.baseAddress, bytes.count)
                return (count, errno)
            }
            if count < 0, readError == EINTR { continue }
            guard count >= 0 else { throw InvariantFailure(code: "stdinRead") }
            if count == 0 {
                guard pending.isEmpty else { throw InvariantFailure(code: "truncatedRequest") }
                return
            }
            try autoreleasepool {
                pending.append(contentsOf: input.prefix(count))
                guard pending.count <= maximumLineBytes else { throw InvariantFailure(code: "requestTooLarge") }
                while let boundary = pending.firstIndex(of: 10) {
                    let line = pending.subdata(in: pending.startIndex..<boundary)
                    pending.removeSubrange(pending.startIndex...boundary)
                    try write(process(line))
                }
            }
        }
    }

    static func process(_ line: Data) -> [String: Any] {
        let started = DispatchTime.now().uptimeNanoseconds
        var response: [String: Any] = ["version": 1, "id": -1, "status": "failure"]
        do {
            let request = try JSONDecoder().decode(Request.self, from: line)
            response["id"] = request.id
            response["mode"] = request.mode
            guard request.id >= 0, modes.contains(request.mode) else { throw InvariantFailure(code: "requestShape") }
            guard request.entryPoint == nil || request.mode == "eip712" && request.entryPoint == "checked" else { throw InvariantFailure(code: "entryPoint") }
            let value: [String: Any]
            if request.mode == "decrypt" {
                guard request.inputBase64 == nil, request.secondaryBase64 == nil, request.relation == nil else {
                    throw InvariantFailure(code: "decryptAcceptsOnlyFixtureIdentifiers")
                }
                value = try decrypt(request)
            } else {
                guard let encoded = request.inputBase64, let data = Data(base64Encoded: encoded) else {
                    throw InvariantFailure(code: "base64")
                }
                let limit = request.mode == "keystore" ? 1_048_577 : request.mode == "eip712" ? 262_145 : 1_233
                guard data.count <= limit else { throw InvariantFailure(code: "harnessInputLimit") }
                switch request.mode {
                case "keystore": value = try keystore(data)
                case "eip712": value = try typedData(data, request: request)
                default: value = try solana(data)
                }
            }
            response.merge(value) { _, next in next }
            response["status"] = "ok"
        } catch let failure as InvariantFailure {
            response["invariant"] = failure.code
        } catch {
            response["invariant"] = "unexpectedWorkerError"
            response["detail"] = String(describing: error).prefix(512).description
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            response["status"] = "failure"
            response["invariant"] = "resourceMeasurement"
            return response
        }
        response["peakRSSBytes"] = usage.ru_maxrss
        response["durationNanoseconds"] = DispatchTime.now().uptimeNanoseconds - started
        return response
    }

    static func keystore(_ data: Data) throws -> [String: Any] {
        let strict = WalletStoredKey.importJSON(json: data, requireCompleteAccounts: true)
        if let strict { try checkKeystoreRoundTrip(strict, invariant: "keystoreStrictRoundTrip") }
        let key: WalletStoredKey
        do { key = try WalletStoredKey.importUserJSON(json: data) }
        catch WalletImportError.limitExceeded {
            return ["accepted": false, "strictAccepted": strict != nil, "rejection": "limitExceeded"]
        } catch WalletKeyStoreError.invalidKey {
            return ["accepted": false, "strictAccepted": strict != nil, "rejection": "invalidKey"]
        }
        try checkKeystoreRoundTrip(key, invariant: "keystoreNormalizedRoundTrip")
        if let strict, strict.accountCount != key.accountCount {
            throw InvariantFailure(code: "keystoreStrictAccountCount")
        }
        return ["accepted": true, "strictAccepted": strict != nil,
                "accountCount": key.accountCount, "isMnemonic": key.isMnemonic]
    }

    static func checkKeystoreRoundTrip(_ key: WalletStoredKey, invariant: String) throws {
        guard let serialized = key.exportJSON(),
              let restored = WalletStoredKey.importJSON(json: serialized, requireCompleteAccounts: true),
              restored.accountCount == key.accountCount,
              restored.isMnemonic == key.isMnemonic,
              restored.exportJSON() == serialized else {
            throw InvariantFailure(code: invariant)
        }
    }

    static func typedData(_ data: Data, request: Request) throws -> [String: Any] {
        let entryPoint = request.entryPoint == "checked" ? "EIP712.checkedDigest" : "PreparedEthereumTypedData"
        guard let json = String(data: data, encoding: .utf8) else {
            return ["accepted": false, "rejection": "invalidUTF8", "entryPoint": entryPoint]
        }
        let digest: Data
        if request.entryPoint == "checked" {
            do { digest = try EIP712.checkedDigest(json: json) }
            catch let failure as EIP712.PreparationError {
                return ["accepted": false, "rejection": String(describing: failure), "entryPoint": entryPoint]
            }
        } else {
            guard let prepared = PreparedEthereumTypedData(json: json) else {
                return ["accepted": false, "rejection": "invalidOrBudget", "entryPoint": entryPoint]
            }
            guard prepared.rawJSON == json else { throw InvariantFailure(code: "typedDataPreparedValue") }
            digest = prepared.digest
        }
        guard digest.count == 32 else { throw InvariantFailure(code: "typedDataDigestLength") }
        if let relation = request.relation {
            guard let encoded = request.secondaryBase64, let secondary = Data(base64Encoded: encoded),
                  secondary.count <= 262_145, let secondJSON = String(data: secondary, encoding: .utf8),
                  let second = PreparedEthereumTypedData(json: secondJSON) else {
                throw InvariantFailure(code: "typedDataRelationInput")
            }
            switch relation {
            case "equalDigest":
                guard second.digest == digest else { throw InvariantFailure(code: "typedDataEquivalentDigest") }
            case "differentDigest":
                guard second.digest != digest else { throw InvariantFailure(code: "typedDataChangedDigest") }
            default: throw InvariantFailure(code: "typedDataUnknownRelation")
            }
        }
        return ["accepted": true, "digest": hex(digest), "entryPoint": entryPoint]
    }

    static func solana(_ data: Data) throws -> [String: Any] {
        let parsed = SolanaWireMessageParser.parse(data)
        let prefixed = Data([0]) + data
        let slice = prefixed.dropFirst()
        let sliced = SolanaWireMessageParser.parse(slice)
        guard (parsed == nil) == (sliced == nil) else { throw InvariantFailure(code: "solanaSliceAcceptance") }
        guard let parsed else { return ["accepted": false, "rejection": "invalidMessage"] }
        let summary = solanaSummary(parsed, data: data)
        guard let sliced, NSDictionary(dictionary: summary).isEqual(to: solanaSummary(sliced, data: slice)) else {
            throw InvariantFailure(code: "solanaSliceValue")
        }
        guard let signerKey = parsed.accountKeys.first else { throw InvariantFailure(code: "solanaMissingSigner") }
        let signer = SolanaSigner()
        let publicKey = WalletEncoding.base58Encode(data: signerKey)
        let message = WalletEncoding.base58Encode(data: data)
        guard case .success = signer.preparedTransactionMessageForSigning(message: message, publicKey: publicKey) else {
            throw InvariantFailure(code: "solanaSigningPreparation")
        }
        var transaction = Data.encodeLength(parsed.requiredSignaturesCount)
        transaction.append(Data(repeating: 1, count: parsed.requiredSignaturesCount * 64))
        transaction.append(data)
        let prepared = signer.preparedSerializedTransactionForSignAndSend(
            serializedTransaction: WalletEncoding.base58Encode(data: transaction), publicKey: publicKey
        )
        if transaction.count <= Solana.maxWirePayloadLength {
            guard case .success(let result) = prepared,
                  result.preparedMessage.messageData == data else {
                throw InvariantFailure(code: "solanaSerializedPreparation")
            }
        } else if case .success = prepared {
            throw InvariantFailure(code: "solanaSerializedSizeLimit")
        }
        return ["accepted": true, "summary": summary]
    }

    static func solanaSummary(_ message: SolanaWireMessage, data: Data) -> [String: Any] {
        let version: String
        switch message.version {
        case .legacy: version = "legacy"
        case .version0: version = "v0"
        }
        return [
            "version": version,
            "requiredSignatures": message.requiredSignaturesCount,
            "readOnlySigned": message.readOnlySignedAccountsCount,
            "readOnlyUnsigned": message.readOnlyUnsignedAccountsCount,
            "accountKeys": message.accountKeys.map(hex),
            "blockhash": hex(data.subdata(in: message.blockhashRange)),
            "instructions": message.instructions.map {
                ["programIdIndex": $0.programIdIndex, "accountIndices": $0.accountIndices, "dataHex": hex($0.data)] as [String: Any]
            },
            "lookups": message.addressTableLookups.map {
                ["accountKey": hex($0.accountKey), "writableIndexes": $0.writableIndexes, "readOnlyIndexes": $0.readOnlyIndexes] as [String: Any]
            },
        ]
    }

    static func decrypt(_ request: Request) throws -> [String: Any] {
        guard let fixtureID = request.fixtureID, let mutation = request.mutation,
              let all = try JSONSerialization.jsonObject(with: fixtureData().data) as? [String: Any],
              let fixtures = all["keystores"] as? [[String: Any]],
              let fixture = fixtures.first(where: { $0["id"] as? String == fixtureID }),
              var document = fixture["document"] as? [String: Any],
              var crypto = document["crypto"] as? [String: Any],
              let fixturePassword = fixture["password"] as? String,
              let plaintextHex = fixture["plaintextHex"] as? String else {
            throw InvariantFailure(code: "decryptFixture")
        }
        let index = request.mutationIndex ?? 0
        guard index >= 0, index < 32 else { throw InvariantFailure(code: "decryptMutationIndex") }
        var password = fixturePassword
        var expectsPlaintext = false
        switch mutation {
        case "original": expectsPlaintext = true
        case "wrongPassword": password += "-wrong-\(index)"
        case "emptyPassword": password = ""
        case "mac", "ciphertext":
            guard let encoded = crypto[mutation] as? String, !encoded.isEmpty else {
                throw InvariantFailure(code: "decryptFixtureField")
            }
            var bytes = Array(encoded.utf8)
            let offset = index % bytes.count
            bytes[offset] = bytes[offset] == 48 ? 49 : 48
            crypto[mutation] = String(decoding: bytes, as: UTF8.self)
        case "shortIV": crypto["cipherparams"] = ["iv": "00"]
        case "emptyMAC": crypto["mac"] = ""
        case "uppercaseCrypto":
            document.removeValue(forKey: "crypto")
            expectsPlaintext = true
        default: throw InvariantFailure(code: "decryptMutation")
        }
        document[mutation == "uppercaseCrypto" ? "Crypto" : "crypto"] = crypto
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let key = try WalletStoredKey.importUserJSON(json: data)
        let secretPassword = SecretBytes(utf8: password)
        defer { secretPassword.invalidate() }
        let plaintext = key.decryptPrivateKey(password: secretPassword)
        defer { plaintext?.invalidate() }
        if expectsPlaintext {
            guard let plaintext, try plaintext.withUnsafeBytes({ hex(Data($0)) }) == plaintextHex else {
                throw InvariantFailure(code: "decryptKnownAnswer")
            }
        } else if plaintext != nil {
            throw InvariantFailure(code: "decryptTamperingAccepted")
        }
        return ["accepted": plaintext != nil, "fixtureID": fixtureID, "mutation": mutation, "kdfParametersMutated": false]
    }

    static func fixtureData() throws -> (url: URL, data: Data) {
        guard let url = Bundle.module.url(forResource: "fixtures", withExtension: "json") else { throw InvariantFailure(code: "fixtureResource") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while true {
            let chunk = file.readData(ofLength: 16_384)
            if chunk.isEmpty { break }
            guard chunk.count <= 65_536 - data.count else { throw InvariantFailure(code: "fixtureResourceLimit") }
            data.append(chunk)
        }
        return (url, data)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func write(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        FileHandle.standardOutput.write(data)
    }

    static func runCanary(_ name: String) {
        switch name {
        case "asan": _ = bw_parser_fuzz_asan_canary()
        case "crash": raise(SIGABRT)
        case "hang": while true { sleep(1) }
        case "rss": bw_parser_fuzz_rss_canary()
        case "malformed": FileHandle.standardOutput.write(Data("not-json\n".utf8)); while true { sleep(1) }
        case "invariant":
            try? write(["version": 1, "id": 0, "mode": "eip712", "status": "failure", "invariant": "deliberateCanary", "peakRSSBytes": 1, "durationNanoseconds": 1])
        default: exit(64)
        }
    }
}

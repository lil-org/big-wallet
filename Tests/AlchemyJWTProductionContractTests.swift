// ∅ 2026 lil org

import Foundation
import XCTest
@testable import Big_Wallet

final class AlchemyJWTProductionContractTests: XCTestCase {

    private let proofKey = Data((0...31).map(UInt8.init))
    private let proofNonce = Data((0...15).map(UInt8.init))
    private let proofTimestamp: TimeInterval = 1_784_558_400

    func testProductionBrokerRequestAndSuccessfulResponseContract()
        async throws {
        let session = makeSession { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.lil.org/v1/alchemy/jwt"
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"),
                "application/json"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/json"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-Lil-Alchemy-Proof"),
                "ctfhJTYThhT35Q05ptrHCn16ylcrBkNb5c5unj1u1Jk"
            )
            XCTAssertEqual(
                try Self.bodyData(from: request),
                Data(
                    """
                    {"timestamp":1784558400,"nonce":"AAECAwQFBgcICQoLDA0ODw"}
                    """.utf8
                )
            )

            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(
                    """
                    {
                      "token": "test-token",
                      "issuedAt": 2000000000,
                      "expiresAt": 2000021600
                    }
                    """.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = try makeClient(urlSession: session)

        let record = try await client.fetchToken()

        XCTAssertEqual(record.token, "test-token")
        XCTAssertEqual(record.issuedAt, 2_000_000_000)
        XCTAssertEqual(record.expiresAt, 2_000_021_600)
    }

    func testProductionBrokerMapsRateLimitAndRetryAfter() async throws {
        let session = makeSession { request in
            return (
                try Self.httpResponse(
                    for: request,
                    statusCode: 429,
                    headers: ["Retry-After": "42"]
                ),
                Data(repeating: 0, count: 16_385)
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = try makeClient(urlSession: session)

        do {
            _ = try await client.fetchToken()
            XCTFail("Expected rate limit error")
        } catch {
            XCTAssertEqual(
                error as? Big_Wallet.AlchemyJWTBrokerError,
                .rateLimited(retryAfterSeconds: 42)
            )
        }
    }

    func testProductionBrokerDefaultsMissingAndMalformedRetryAfter()
        async throws {
        let retryAfterHeaders: [[String: String]] = [
            [:],
            ["Retry-After": "not-a-delay"],
        ]

        for headers in retryAfterHeaders {
            let session = makeSession { request in
                return (
                    try Self.httpResponse(
                        for: request,
                        statusCode: 429,
                        headers: headers
                    ),
                    Data()
                )
            }
            let client = try makeClient(urlSession: session)

            do {
                _ = try await client.fetchToken()
                XCTFail("Expected rate limit error")
            } catch {
                XCTAssertEqual(
                    error as? Big_Wallet.AlchemyJWTBrokerError,
                    .rateLimited(retryAfterSeconds: 60)
                )
            }

            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
    }

    func testProductionBrokerRejectsNonSuccessMalformedAndOversizedResponses()
        async throws {
        let invalidResponses: [(statusCode: Int, data: Data)] = [
            (
                500,
                Data(
                    """
                    {"token":"ignored","issuedAt":1,"expiresAt":61}
                    """.utf8
                )
            ),
            (200, Data("{".utf8)),
            (200, Data(repeating: 0, count: 16_385)),
        ]

        for invalidResponse in invalidResponses {
            let session = makeSession { request in
                return (
                    try Self.httpResponse(
                        for: request,
                        statusCode: invalidResponse.statusCode
                    ),
                    invalidResponse.data
                )
            }
            let client = try makeClient(urlSession: session)

            do {
                _ = try await client.fetchToken()
                XCTFail(
                    "Expected invalid response for status "
                        + "\(invalidResponse.statusCode)"
                )
            } catch {
                XCTAssertEqual(
                    error as? Big_Wallet.AlchemyJWTBrokerError,
                    .invalidResponse
                )
            }

            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
    }

    func testProductionBrokerAllowsExactlyMaximumResponseSize()
        async throws {
        var body = Data(
            """
            {"token":"test-token","issuedAt":2000000000,"expiresAt":2000021600}
            """.utf8
        )
        body.append(
            Data(repeating: 0x20, count: 16_384 - body.count)
        )
        let session = makeSession { request in
            return (
                try Self.httpResponse(
                    for: request,
                    statusCode: 200,
                    headers: ["Content-Length": "16384"]
                ),
                body
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = try makeClient(urlSession: session)

        let record = try await client.fetchToken()

        XCTAssertEqual(record.token, "test-token")
    }

    func testProductionBrokerRejectsDeclaredOversizeBeforeDecoding()
        async throws {
        let session = makeSession { request in
            return (
                try Self.httpResponse(
                    for: request,
                    statusCode: 200,
                    headers: ["Content-Length": "16385"]
                ),
                Data(
                    """
                    {"token":"ignored","issuedAt":1,"expiresAt":3601}
                    """.utf8
                )
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = try makeClient(urlSession: session)

        do {
            _ = try await client.fetchToken()
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(
                error as? Big_Wallet.AlchemyJWTBrokerError,
                .invalidResponse
            )
        }
    }

    func testProductionBrokerRejectsNonHTTPResponse() async throws {
        let session = makeSession { request in
            return (
                URLResponse(
                    url: try XCTUnwrap(request.url),
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                Data()
            )
        }
        defer {
            session.invalidateAndCancel()
            ProductionAlchemyJWTURLProtocol.removeRequestHandler()
        }
        let client = try makeClient(urlSession: session)

        do {
            _ = try await client.fetchToken()
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(
                error as? Big_Wallet.AlchemyJWTBrokerError,
                .invalidResponse
            )
        }
    }

    func testProofSignerUsesFreshNonceForEachRequest() throws {
        let nonceSource = TestAlchemyJWTNonceSource(
            values: [
                Data(repeating: 0x11, count: 16),
                Data(repeating: 0x22, count: 16),
            ]
        )
        let timestamp = proofTimestamp
        let signer = try Big_Wallet.AlchemyJWTRequestProofSigner(
            keyData: proofKey,
            now: {
                Date(timeIntervalSince1970: timestamp)
            },
            nonceSource: {
                try nonceSource.next()
            }
        )

        let first = try signer.signedRequest()
        let second = try signer.signedRequest()

        XCTAssertNotEqual(first.body, second.body)
        XCTAssertNotEqual(first.headerValue, second.headerValue)
        XCTAssertEqual(nonceSource.requestCount, 2)
    }

    func testProductionTargetsOwnExactlySevenFingerprintPinnedBundlePhases()
        throws {
        let project = try Self.repositoryText(
            at: "Wallet.xcodeproj/project.pbxproj"
        )
        let nativeTargets = try Self.projectSection(
            named: "PBXNativeTarget",
            in: project
        )
        let productionTargets = [
            "Big Wallet iOS",
            "Safari iOS",
            "Big Wallet visionOS",
            "Safari visionOS",
            "Big Wallet",
            "Safari macOS",
            "Big Wallet Ambient",
        ]
        let phaseComment = "Bundle Alchemy JWT Request Proof Key"
        let requiredInputPaths = [
            "$(SRCROOT)/Scripts/bundle_alchemy_jwt_request_proof_key.sh",
            "$(SRCROOT)/Scripts/validate_alchemy_jwt_request_proof_key_file.sh",
            "$(SRCROOT)/Scripts/alchemy_jwt_request_proof_key.sha256",
        ]
        var phaseIDs = Set<String>()

        for targetName in productionTargets {
            let target = try Self.projectObject(
                commented: targetName,
                in: nativeTargets
            )
            let targetPhaseIDs = Self.objectReferenceIDs(
                commented: phaseComment,
                in: target
            )
            XCTAssertEqual(
                targetPhaseIDs.count,
                1,
                "\(targetName) must own exactly one proof-key bundle phase"
            )
            let phaseID = try XCTUnwrap(targetPhaseIDs.first)
            XCTAssertTrue(
                phaseIDs.insert(phaseID).inserted,
                "Production targets must not share a bundle phase"
            )

            let phase = try Self.projectObject(
                id: phaseID,
                commented: phaseComment,
                in: project
            )
            for inputPath in requiredInputPaths {
                XCTAssertEqual(
                    Self.occurrenceCount(of: inputPath, in: phase),
                    1,
                    "\(targetName) must automatically depend on \(inputPath)"
                )
            }
            XCTAssertEqual(
                Self.occurrenceCount(
                    of: "AlchemyJWTRequestProofKey",
                    in: phase
                ),
                1,
                "\(targetName) must produce exactly one proof-key resource"
            )
        }

        XCTAssertEqual(phaseIDs.count, 7)
        XCTAssertEqual(
            Self.occurrenceCount(
                of: "/* \(phaseComment) */ = {",
                in: project
            ),
            7
        )
    }

    func testTestTargetsCannotReceiveRequestProofResource() throws {
        let project = try Self.repositoryText(
            at: "Wallet.xcodeproj/project.pbxproj"
        )
        let nativeTargets = try Self.projectSection(
            named: "PBXNativeTarget",
            in: project
        )
        let phaseComment = "Bundle Alchemy JWT Request Proof Key"
        let productionTargets = [
            "Big Wallet iOS",
            "Safari iOS",
            "Big Wallet visionOS",
            "Safari visionOS",
            "Big Wallet",
            "Safari macOS",
            "Big Wallet Ambient",
        ]
        var projectOutsideProofPhases = project

        for targetName in productionTargets {
            let target = try Self.projectObject(
                commented: targetName,
                in: nativeTargets
            )
            let phaseID = try XCTUnwrap(
                Self.objectReferenceIDs(
                    commented: phaseComment,
                    in: target
                ).only
            )
            let phase = try Self.projectObject(
                id: phaseID,
                commented: phaseComment,
                in: project
            )
            projectOutsideProofPhases = projectOutsideProofPhases
                .replacingOccurrences(of: phase, with: "")
        }

        for targetName in [
            "Tests iOS",
            "Tests visionOS",
            "Tests macOS",
        ] {
            let target = try Self.projectObject(
                commented: targetName,
                in: nativeTargets
            )
            XCTAssertTrue(
                Self.objectReferenceIDs(
                    commented: phaseComment,
                    in: target
                ).isEmpty,
                "\(targetName) must not run the proof-key bundle phase"
            )

            let resourcesPhaseID = try XCTUnwrap(
                Self.objectReferenceIDs(
                    commented: "Resources",
                    in: target
                ).only
            )
            let resourcesPhase = try Self.projectObject(
                id: resourcesPhaseID,
                commented: "Resources",
                in: project
            )
            XCTAssertFalse(
                resourcesPhase.contains("AlchemyJWTRequestProofKey"),
                "\(targetName) must not copy the production proof key"
            )
        }

        XCTAssertFalse(
            projectOutsideProofPhases.contains("AlchemyJWTRequestProofKey"),
            "The proof resource must exist only as seven production outputs"
        )
    }

    func testCommittedProofKeyFingerprintIsCanonical() throws {
        let fingerprintURL = Self.repositoryRoot.appendingPathComponent(
            "Scripts/alchemy_jwt_request_proof_key.sha256"
        )
        let bytes = try Data(contentsOf: fingerprintURL)
        let fingerprintBytes: Data

        switch bytes.count {
        case 64:
            fingerprintBytes = bytes
        case 65:
            XCTAssertEqual(
                bytes.last,
                0x0A,
                "The fingerprint may end with one LF only"
            )
            fingerprintBytes = Data(bytes.dropLast())
        default:
            XCTFail("The fingerprint must contain exactly 64 lowercase hex bytes")
            return
        }

        let fingerprint = try XCTUnwrap(
            String(data: fingerprintBytes, encoding: .utf8)
        )
        XCTAssertEqual(fingerprint.utf8.count, 64)
        XCTAssertTrue(
            fingerprint.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            },
            "The committed fingerprint must be lowercase SHA-256 hex"
        )
    }

    func testRolloutRunbookHasNoLegacyIssuerOrRollbackEscapeHatch() throws {
        let readme = try Self.repositoryText(
            at: "Workers/alchemy-jwt/README.md"
        )
        let initialHeading = "## First HMAC production rollout"
        let futureHeading = "## Future HMAC-compatible Worker updates"
        let initialStart = try XCTUnwrap(readme.range(of: initialHeading))
        let futureStart = try XCTUnwrap(
            readme.range(
                of: futureHeading,
                range: initialStart.upperBound..<readme.endIndex
            )
        )
        let initialRollout = String(
            readme[initialStart.lowerBound..<futureStart.lowerBound]
        )
        let futureRollout = String(readme[futureStart.lowerBound...])

        XCTAssertTrue(
            initialRollout.contains(
                "Add the HMAC candidate at 0% while retaining that anchor at 100%"
            )
        )
        XCTAssertTrue(
            initialRollout.contains(
                "\"$PRELAUNCH_ANCHOR_VERSION_ID@100\""
            )
        )
        XCTAssertTrue(
            initialRollout.contains(
                "\"$HMAC_INITIAL_VERSION_ID@0\""
            )
        )
        XCTAssertTrue(initialRollout.contains("--version-override"))
        XCTAssertTrue(
            initialRollout.contains("Promote only the validated candidate")
        )
        XCTAssertTrue(futureRollout.contains("--version-override"))
        XCTAssertTrue(futureRollout.contains("@0"))

        let lowercasedRunbook = readme.lowercased()
        for removedProcedure in [
            "old_version_id",
            "installationid",
            "canonical installation uuid",
            "legacy client",
            "old-client",
            "old clients",
            "legacy embedded api key and old clients",
            "for that one legacy rollback only",
            "a missing version header is acceptable",
            "pre-metadata version",
            "pre-jwt wallet version",
            "installation uuid",
        ] {
            XCTAssertFalse(
                lowercasedRunbook.contains(removedProcedure),
                "Removed rollout procedure returned: \(removedProcedure)"
            )
        }
    }

    private func makeClient(
        urlSession: URLSession
    ) throws -> Big_Wallet.AlchemyJWTBrokerClient {
        let timestamp = proofTimestamp
        let nonce = proofNonce
        let signer = try Big_Wallet.AlchemyJWTRequestProofSigner(
            keyData: proofKey,
            now: {
                Date(timeIntervalSince1970: timestamp)
            },
            nonceSource: {
                nonce
            }
        )
        return Big_Wallet.AlchemyJWTBrokerClient(
            urlSession: urlSession,
            proofSigner: signer
        )
    }

    private func makeSession(
        requestHandler:
            @escaping ProductionAlchemyJWTURLProtocol.RequestHandler
    ) -> URLSession {
        ProductionAlchemyJWTURLProtocol.setRequestHandler(requestHandler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ProductionAlchemyJWTURLProtocol.self,
        ]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 {
                return body
            }
            if count < 0 {
                throw try XCTUnwrap(stream.streamError)
            }
            body.append(buffer, count: count)
        }
    }

    private static func httpResponse(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String] = [:]
    ) throws -> HTTPURLResponse {
        return try XCTUnwrap(
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        )
    }

    private static var repositoryRoot: URL {
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func repositoryText(at relativePath: String) throws
        -> String {
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func projectSection(
        named sectionName: String,
        in project: String
    ) throws -> String {
        let startMarker = "/* Begin \(sectionName) section */"
        let endMarker = "/* End \(sectionName) section */"
        let start = try XCTUnwrap(project.range(of: startMarker))
        let end = try XCTUnwrap(
            project.range(
                of: endMarker,
                range: start.upperBound..<project.endIndex
            )
        )
        return String(project[start.lowerBound..<end.upperBound])
    }

    private static func projectObject(
        id: String? = nil,
        commented comment: String,
        in project: String
    ) throws -> String {
        let prefix = id.map { "\($0) " } ?? ""
        let marker = "\(prefix)/* \(comment) */ = {"
        let start = try XCTUnwrap(project.range(of: marker))
        let end = try XCTUnwrap(
            project.range(
                of: "\n\t\t};",
                range: start.upperBound..<project.endIndex
            )
        )
        return String(project[start.lowerBound..<end.upperBound])
    }

    private static func objectReferenceIDs(
        commented comment: String,
        in object: String
    ) -> [String] {
        let marker = "/* \(comment) */"
        return object.split(separator: "\n").compactMap { line in
            guard line.contains(marker), !line.contains("= {") else {
                return nil
            }
            let candidate = line.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).split(separator: " ", maxSplits: 1).first
            guard
                let candidate,
                candidate.utf8.count == 24,
                candidate.utf8.allSatisfy({
                    (0x30...0x39).contains($0) || (0x41...0x46).contains($0)
                })
            else {
                return nil
            }
            return String(candidate)
        }
    }

    private static func occurrenceCount(
        of needle: String,
        in haystack: String
    ) -> Int {
        guard !needle.isEmpty else {
            return 0
        }
        return haystack.components(separatedBy: needle).count - 1
    }

}

private extension Collection {

    var only: Element? {
        return count == 1 ? first : nil
    }

}

private final class TestAlchemyJWTNonceSource: @unchecked Sendable {

    private let lock = NSLock()
    private var values: [Data]
    private var requests = 0

    init(values: [Data]) {
        self.values = values
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func next() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        guard !values.isEmpty else {
            throw AlchemyJWTRequestProofError.invalidNonce
        }
        return values.removeFirst()
    }

}

private final class ProductionAlchemyJWTURLProtocol: URLProtocol {

    typealias RequestHandler =
        (URLRequest) throws -> (URLResponse, Data)

    private static let lock = NSLock()
    private static var requestHandler: RequestHandler?

    static func setRequestHandler(_ requestHandler: @escaping RequestHandler) {
        lock.lock()
        self.requestHandler = requestHandler
        lock.unlock()
    }

    static func removeRequestHandler() {
        lock.lock()
        requestHandler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lock.lock()
        let requestHandler = Self.requestHandler
        Self.lock.unlock()

        guard let requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

}

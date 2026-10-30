import Foundation
import WalletDomain

public final class SolanaRPCClient: Sendable {
    private static let requestID = 1

    private enum Method: String {
        case getSignatureStatuses
        case sendTransaction
    }

    private enum RPCRequestOutcome<Response: Sendable>: Sendable {
        case response(Response)
        case retryableFailure
        case terminalPolicyFailure
        case authorizationAcquisitionFailed
        case authorizationRecoveryFailed(
            statusCode: Int,
            response: Response?
        )
        case authorizationRejectedAfterRecovery(
            statusCode: Int,
            response: Response?
        )
    }

    private struct SendTransactionResponse: Decodable, Sendable {
        let result: String?
        private let error: RPCResponseError?

        func failure(fallbackMessage: String) -> Solana.SendTransactionError? {
            guard let error else { return nil }
            if error.isBlockhashNotFound {
                return .blockhashNotFound
            }

            return error.sendTransactionFailure(fallbackMessage: fallbackMessage)
        }
    }

    private struct SignatureStatusesResponse: Decodable, Sendable {
        private let result: ResultValue?
        private let error: RPCResponseError?

        var status: SignatureStatus? {
            guard let values = result?.value, !values.isEmpty else { return nil }
            return values[0]
        }

        func failure(fallbackMessage: String) -> Solana.SendTransactionError? {
            guard let error else { return nil }
            return error.sendTransactionFailure(fallbackMessage: fallbackMessage)
        }

        struct ResultValue: Decodable, Sendable {
            let value: [SignatureStatus?]
        }
    }

    private struct SignatureStatus: Decodable, Sendable {
        let err: RPCErrorValue?
        let confirmations: Int?
        let confirmationStatus: Solana.Commitment?
        private let didReturnConfirmations: Bool

        private enum CodingKeys: String, CodingKey {
            case err, confirmations, confirmationStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            err = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .err)
            if container.contains(.confirmations) {
                if (try? container.decodeNil(forKey: .confirmations)) == true {
                    didReturnConfirmations = true
                    confirmations = nil
                } else if let decodedConfirmations = try? container.decode(Int.self, forKey: .confirmations),
                          decodedConfirmations >= 0 {
                    didReturnConfirmations = true
                    confirmations = decodedConfirmations
                } else {
                    didReturnConfirmations = false
                    confirmations = nil
                }
            } else {
                didReturnConfirmations = false
                confirmations = nil
            }
            confirmationStatus = try? container.decodeIfPresent(Solana.Commitment.self, forKey: .confirmationStatus)
        }

        func failure(fallbackMessage: String) -> Solana.SendTransactionError? {
            guard let err else { return nil }
            return .rpcError(message: err.displayMessage ?? fallbackMessage,
                             code: nil)
        }

        func satisfies(_ commitment: Solana.Commitment) -> Bool {
            if let confirmationStatus {
                return confirmationStatus.satisfies(commitment)
            }

            switch commitment {
            case .processed:
                return err == nil
            case .confirmed:
                guard didReturnConfirmations else { return false }
                return confirmations == nil || (confirmations ?? 0) > 0
            case .finalized:
                return didReturnConfirmations && confirmations == nil
            }
        }
    }

    private struct RPCResponseError: Decodable, Sendable {
        let code: Int?
        let message: String?
        let data: ResponseData?
        private let rawData: RPCErrorValue?

        private enum CodingKeys: String, CodingKey {
            case code, message, data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            data = try? container.decodeIfPresent(ResponseData.self, forKey: .data)
            rawData = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .data)
        }

        var displayMessage: String? {
            if let message, !message.isEmpty {
                return message
            }
            if let dataMessage = data?.message, !dataMessage.isEmpty {
                return dataMessage
            }
            return rawData?.displayMessage
        }

        func sendTransactionFailure(fallbackMessage: String) -> Solana.SendTransactionError {
            return .rpcError(message: displayMessage ?? fallbackMessage,
                             code: code)
        }

        var isBlockhashNotFound: Bool {
            return contains("BlockhashNotFound") ||
                contains("blockhash not found")
        }

        func contains(_ string: String) -> Bool {
            return message?.rpcContainsIgnoringCase(string) == true ||
                data?.contains(string) == true ||
                rawData?.contains(string) == true
        }

        struct ResponseData: Decodable, Sendable {
            let err: RPCErrorValue?
            let message: String?

            private enum CodingKeys: String, CodingKey {
                case err, message
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                err = try? container.decodeIfPresent(RPCErrorValue.self, forKey: .err)
                message = try? container.decodeIfPresent(String.self, forKey: .message)
            }

            func contains(_ string: String) -> Bool {
                return message?.rpcContainsIgnoringCase(string) == true ||
                    err?.contains(string) == true
            }
        }
    }

    private indirect enum RPCErrorValue: Decodable, Sendable {
        case string(String)
        case array([RPCErrorValue])
        case object([String: RPCErrorValue])
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([RPCErrorValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: RPCErrorValue].self) {
                self = .object(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else {
                self = .null
            }
        }

        var displayMessage: String? {
            switch self {
            case .string(let value):
                return value.isEmpty ? nil : value
            case .array(let values):
                let messages = values.compactMap { $0.displayMessage }
                return messages.isEmpty ? nil : messages.joined(separator: ", ")
            case .object(let values):
                return values["message"]?.displayMessage ??
                    values["err"]?.displayMessage
            case .number, .bool, .null:
                return nil
            }
        }

        func contains(_ string: String) -> Bool {
            switch self {
            case .string(let value):
                return value.rpcContainsIgnoringCase(string)
            case .array(let values):
                return values.contains { $0.contains(string) }
            case .object(let values):
                return values.contains { key, value in
                    key.rpcContainsIgnoringCase(string) ||
                        value.contains(string)
                }
            case .number, .bool, .null:
                return false
            }
        }
    }

    public struct RPCConfiguration: SolanaEndpointResolving {
        public static let bundled = RPCConfiguration(
            trustsAlchemyURLBuilderOutput: true
        )

        private let endpoints: [Solana.Cluster: SolanaRPCEndpoint]

        public init(endpoints: [Solana.Cluster: SolanaRPCEndpoint]) { self.endpoints = endpoints }

        public init(
            trustsAlchemyURLBuilderOutput: Bool = false,
            urlBuilder: (String) -> URL? = {
                return AlchemyRPC.url(network: $0)
            }
        ) {
            var endpoints: [Solana.Cluster: SolanaRPCEndpoint] = [
                .testnet: SolanaRPCEndpoint(
                    url: URL(string: "https://api.testnet.solana.com")!,
                    allowsAlchemyAuthorization: false
                ),
            ]
            for cluster in [Solana.Cluster.mainnetBeta, .devnet] {
                let network = cluster == .mainnetBeta ? "solana-mainnet" : "solana-devnet"
                guard let url = urlBuilder(network) else {
                    continue
                }
                endpoints[cluster] = SolanaRPCEndpoint(
                    url: url,
                    allowsAlchemyAuthorization:
                        trustsAlchemyURLBuilderOutput
                )
            }
            self.endpoints = endpoints
        }

        public func endpoint(for cluster: Solana.Cluster) -> SolanaRPCEndpoint? {
            return endpoints[cluster]
        }
    }

    public struct Timing: Sendable {
        public let now: @Sendable () -> Date
        public let sleep: @Sendable (TimeInterval) async throws -> Void

        public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
            self.now = now
            self.sleep = sleep
        }

        public static let live = Timing(
            now: { Date() },
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
    }

    public struct Messages: Sendable {
        public let failedToSend: String
        public let blockhashNotFound: String

        public init(failedToSend: String, blockhashNotFound: String) {
            self.failedToSend = failedToSend
            self.blockhashNotFound = blockhashNotFound
        }
    }

    private let timing: Timing
    private let urlSession: URLSession
    private let authorizationProvider: any AlchemyAuthorizationProviding
    private let authorizeRequest: @Sendable (inout URLRequest) throws -> Void
    private let messages: Messages
    private let signatureStatusInitialPollInterval: TimeInterval = 0.5
    private let signatureStatusMaxPollInterval: TimeInterval = 2
    private let signatureStatusPollBackoffMultiplier: TimeInterval = 1.5
    private let signatureStatusPollTimeout: TimeInterval = 45

    public init(
        urlSession: URLSession,
        authorizationProvider: any AlchemyAuthorizationProviding,
        timing: Timing = .live,
        messages: Messages,
        authorizeRequest: @escaping @Sendable (inout URLRequest) throws -> Void = { _ in }
    ) {
        self.urlSession = urlSession
        self.authorizationProvider = authorizationProvider
        self.timing = timing
        self.messages = messages
        self.authorizeRequest = authorizeRequest
    }

    @concurrent
    public func sendSignedTransaction(
        _ signedTransaction: String,
        endpoint: SolanaRPCEndpoint,
        sendOptions: Solana.PreparedSendOptions
    ) async throws -> String {
        try Task.checkCancellation()
        return try await sendTransaction(
            signed: signedTransaction,
            endpoint: endpoint,
            sendOptions: sendOptions
        )
    }

    private func createRequest(method: Method, endpointURL: URL, parameters: [Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: endpointURL)
        try authorizeRequest(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"

        var dict: [String: Any] = [
            "method": method.rawValue,
            "id": Self.requestID,
            "jsonrpc": "2.0",
        ]

        if let parameters {
            dict["params"] = parameters
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: dict, options: .fragmentsAllowed)
        return request
    }

    private func sendTransaction(
        signed: String,
        endpoint: SolanaRPCEndpoint,
        sendOptions: Solana.PreparedSendOptions
    ) async throws -> String {
        let request = try createRequest(
            method: .sendTransaction,
            endpointURL: endpoint.url,
            parameters: [signed, sendOptions.rpcOptions]
        )
        let outcome: RPCRequestOutcome<SendTransactionResponse> = try await performRequest(
            request: request,
            requestAuthorization: RPCRequestAuthorization(
                url: endpoint.url,
                allowsAlchemyAuthorization: endpoint.allowsAlchemyAuthorization,
                provider: authorizationProvider
            ),
            shouldRecoverUnauthorizedResponse: { response in
                response.map { $0.result == nil } ?? false
            }
        )
        switch outcome {
        case .retryableFailure, .terminalPolicyFailure:
            throw Solana.SendTransactionError.unknown
        case .authorizationAcquisitionFailed:
            throw Solana.SendTransactionError.notSubmitted
        case .authorizationRecoveryFailed(let statusCode, let response),
             .authorizationRejectedAfterRecovery(let statusCode, let response):
            throw response?.failure(fallbackMessage: messages.failedToSend) ?? .rpcError(message: messages.failedToSend, code: statusCode)
        case .response(let response):
            guard let signature = response.result else {
                throw response.failure(fallbackMessage: messages.failedToSend) ?? .unknown
            }
            guard let commitment = sendOptions.confirmationCommitment else { return signature }
            return try await confirmTransaction(
                signature: signature,
                commitment: commitment,
                endpoint: endpoint
            )
        }
    }

    private func confirmTransaction(
        signature: String,
        commitment: Solana.Commitment,
        endpoint: SolanaRPCEndpoint
    ) async throws -> String {
        let requestAuthorization = RPCRequestAuthorization(
            url: endpoint.url,
            allowsAlchemyAuthorization: endpoint.allowsAlchemyAuthorization,
            provider: authorizationProvider
        )
        let freshAuthorizationPoll = OneShotGate()
        let deadline = timing.now().addingTimeInterval(signatureStatusPollTimeout)
        var pollInterval = signatureStatusInitialPollInterval
        var lastFailure: Solana.SendTransactionError?
        let request = try createRequest(
            method: .getSignatureStatuses,
            endpointURL: endpoint.url,
            parameters: [[signature], ["searchTransactionHistory": true]]
        )
        while true {
            try Task.checkCancellation()
            guard timing.now() <= deadline else {
                throw lastFailure ?? .confirmationTimedOut(signature: signature)
            }
            let outcome: RPCRequestOutcome<SignatureStatusesResponse> = try await performRequest(
                request: request,
                requestAuthorization: requestAuthorization
            )
            switch outcome {
            case .retryableFailure:
                break
            case .terminalPolicyFailure:
                throw confirmationFailure(signature: signature, failure: .unknown)
            case .authorizationAcquisitionFailed:
                let failure = confirmationFailure(signature: signature, failure: .rpcUnavailable)
                lastFailure = failure
                guard freshAuthorizationPoll.claim() else { throw failure }
            case .authorizationRecoveryFailed(let statusCode, let response),
                 .authorizationRejectedAfterRecovery(let statusCode, let response):
                let failure = confirmationFailure(
                    signature: signature,
                    failure: response?.failure(fallbackMessage: messages.failedToSend) ?? .rpcError(message: messages.failedToSend, code: statusCode)
                )
                lastFailure = failure
                guard freshAuthorizationPoll.claim() else { throw failure }
            case .response(let response):
                if let failure = response.failure(fallbackMessage: messages.failedToSend) {
                    lastFailure = confirmationFailure(signature: signature, failure: failure)
                } else if let status = response.status {
                    if let failure = status.failure(fallbackMessage: messages.failedToSend) {
                        throw confirmationFailure(signature: signature, failure: failure)
                    }
                    if status.satisfies(commitment) { return signature }
                    lastFailure = nil
                } else {
                    lastFailure = nil
                }
            }
            let remaining = deadline.timeIntervalSince(timing.now())
            guard remaining > 0 else {
                throw lastFailure ?? .confirmationTimedOut(signature: signature)
            }
            try await timing.sleep(min(pollInterval, remaining))
            pollInterval = min(pollInterval * signatureStatusPollBackoffMultiplier, signatureStatusMaxPollInterval)
        }
    }

    private func confirmationFailure(signature: String, failure: Solana.SendTransactionError) -> Solana.SendTransactionError {
        switch failure {
        case .rpcError(let message, let code):
            return .confirmationFailed(signature: signature,
                                       message: message,
                                       code: code)
        case .confirmationFailed, .confirmationTimedOut:
            return failure
        case .blockhashNotFound:
            return .confirmationFailed(signature: signature,
                                       message: messages.blockhashNotFound,
                                       code: -32003)
        case .invalidMessage, .invalidSendOptions, .unsupportedMultiSignature,
             .rpcUnavailable, .notSubmitted, .unknown:
            return .confirmationFailed(signature: signature,
                                       message: messages.failedToSend,
                                       code: nil)
        }
    }

    private func performRequest<Response: Decodable & Sendable>(
        request: URLRequest,
        requestAuthorization: RPCRequestAuthorization,
        shouldRecoverUnauthorizedResponse: @Sendable (Response?) -> Bool = { _ in true }
    ) async throws -> RPCRequestOutcome<Response> {
        try Task.checkCancellation()
        let authorization: AlchemyAuthorization?
        do {
            authorization = try await requestAuthorization.acquire()
        } catch {
            try Task.checkCancellation()
            return .authorizationAcquisitionFailed
        }
        return try await executeRequest(
            request: request,
            authorization: authorization,
            requestAuthorization: requestAuthorization,
            shouldRecoverUnauthorizedResponse: shouldRecoverUnauthorizedResponse
        )
    }

    private func executeRequest<Response: Decodable & Sendable>(
        request: URLRequest,
        authorization: AlchemyAuthorization?,
        requestAuthorization: RPCRequestAuthorization,
        shouldRecoverUnauthorizedResponse: @Sendable (Response?) -> Bool
    ) async throws -> RPCRequestOutcome<Response> {
        try Task.checkCancellation()
        var authorizedRequest = request
        authorization?.apply(to: &authorizedRequest)
        let transport = try await urlSession.responsePreservingTransportError(for: authorizedRequest)
        try Task.checkCancellation()
        let httpResponse = transport.response as? HTTPURLResponse
        let decodedResponse: Response?
        do {
            if let policyError = transport.error as? NativeRPCResponsePolicyError { throw policyError }
            decodedResponse = try transport.data.flatMap {
                try NativeRPCResponseDecoder.decode(Response.self, from: $0, expectedID: Self.requestID)
            }
        } catch is NativeRPCResponsePolicyError {
            try Task.checkCancellation()
            if httpResponse?.statusCode == 401, let authorization {
                await requestAuthorization.invalidate(afterUnauthorized: authorization)
            }
            try Task.checkCancellation()
            return .terminalPolicyFailure
        }
        try Task.checkCancellation()
        if httpResponse?.statusCode == 401,
           let authorization {
            if !shouldRecoverUnauthorizedResponse(decodedResponse) {
                await requestAuthorization.invalidate(afterUnauthorized: authorization)
                try Task.checkCancellation()
                guard let decodedResponse else { return .retryableFailure }
                return .response(decodedResponse)
            }
            guard requestAuthorization.reserveUnauthorizedRecovery() else {
                await requestAuthorization.invalidate(afterUnauthorized: authorization)
                try Task.checkCancellation()
                return .authorizationRejectedAfterRecovery(statusCode: 401, response: decodedResponse)
            }
            let replacement: AlchemyAuthorization?
            do {
                replacement = try await requestAuthorization.replacement(afterUnauthorized: authorization)
            } catch {
                try Task.checkCancellation()
                return .authorizationRecoveryFailed(statusCode: 401, response: decodedResponse)
            }
            try Task.checkCancellation()
            guard let replacement else {
                return .authorizationRecoveryFailed(statusCode: 401, response: decodedResponse)
            }
            return try await executeRequest(
                request: request,
                authorization: replacement,
                requestAuthorization: requestAuthorization,
                shouldRecoverUnauthorizedResponse: shouldRecoverUnauthorizedResponse
            )
        }
        guard let decodedResponse else { return .retryableFailure }
        return .response(decodedResponse)
    }

}

private extension String {
    func rpcContainsIgnoringCase(_ string: String) -> Bool {
        range(of: string, options: .caseInsensitive) != nil
    }
}

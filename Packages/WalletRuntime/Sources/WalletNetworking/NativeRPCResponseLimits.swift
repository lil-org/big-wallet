struct HTTPResponsePolicy: Sendable {
    let maximumResponseBytes: Int
    let totalTimeout: Duration?

    static let nativeRPC = HTTPResponsePolicy(maximumResponseBytes: 16_777_216)

    init(maximumResponseBytes: Int, totalTimeout: Duration? = nil) {
        precondition(maximumResponseBytes >= 0)
        precondition(totalTimeout.map { $0 >= .zero } ?? true)
        self.maximumResponseBytes = maximumResponseBytes
        self.totalTimeout = totalTimeout
    }
}

struct NativeRPCResponseLimits: Sendable {
    let maximumResponseBytes: Int
    let maximumJSONDepth: Int
    let maximumJSONTokens: Int

    static let live = NativeRPCResponseLimits()

    init(
        maximumResponseBytes: Int = 16_777_216,
        maximumJSONDepth: Int = 64,
        maximumJSONTokens: Int = 65_536
    ) {
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumJSONDepth = maximumJSONDepth
        self.maximumJSONTokens = maximumJSONTokens
    }
}

enum HTTPResponsePolicyError: Error, Equatable, Sendable {
    case responseTooLarge
    case jsonTooDeep
    case tooManyJSONTokens
    case redirectRejected
    case deadlineExceeded
}

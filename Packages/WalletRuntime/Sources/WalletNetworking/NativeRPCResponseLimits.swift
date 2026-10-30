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

enum NativeRPCResponsePolicyError: Error, Equatable, Sendable {
    case responseTooLarge
    case jsonTooDeep
    case tooManyJSONTokens
    case redirectRejected
}

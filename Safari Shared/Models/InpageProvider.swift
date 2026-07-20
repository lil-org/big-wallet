// ∅ 2026 lil org

enum InpageProvider: String, CaseIterable, Decodable {
    case ethereum, solana, unknown, multiple

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

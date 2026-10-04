// ∅ 2026 lil org

import Foundation

@MainActor
final class PriceService {
    private struct Prices: Codable, Sendable {
        let eth: Price?
        let bnb: Price?
        let matic: Price?
        let ftm: Price?
        let avax: Price?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case eth = "ethereum"
            case bnb = "binancecoin"
            case matic = "matic-network"
            case ftm = "fantom"
            case avax = "avalanche-2"
        }
    }

    private struct Price: Codable, Sendable {
        let usd: Double
    }

    static let shared = PriceService()
    private let urlSession = URLSession(configuration: .ephemeral)
    private var currentPrices: Prices?
    private var refreshLoop: Task<Void, Never>?
    private var request: (id: UUID, task: Task<Prices?, Never>)?

    private init() {}

    isolated deinit {
        refreshLoop?.cancel()
        request?.task.cancel()
    }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.update()
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
            }
        }
    }

    func update() async {
        let current: (id: UUID, task: Task<Prices?, Never>)
        if let request {
            current = request
        } else {
            let task = Task { [urlSession] in await Self.fetchPrices(using: urlSession) }
            current = (UUID(), task)
            request = current
        }
        let prices = await current.task.value
        guard request?.id == current.id else { return }
        request = nil
        if let prices { currentPrices = prices }
    }

    func forNetwork(_ network: EthereumNetwork) -> Double? {
        guard network.mightShowPrice else { return nil }
        return switch network.symbol {
        case "ETH": currentPrices?.eth?.usd
        case "BNB": currentPrices?.bnb?.usd
        case "FTM": currentPrices?.ftm?.usd
        case "MATIC": currentPrices?.matic?.usd
        case "AVAX": currentPrices?.avax?.usd
        default: nil
        }
    }

    @concurrent
    private nonisolated static func fetchPrices(using session: URLSession) async -> Prices? {
        let ids = Prices.CodingKeys.allCases.map(\.rawValue).joined(separator: "%2C")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
            return try JSONDecoder().decode(Prices.self, from: data)
        } catch {
            return nil
        }
    }
}

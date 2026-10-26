// ∅ 2026 lil org

import Foundation
import WalletDomain

@MainActor
public final class PriceService {
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

    public typealias PriceFetcher = @Sendable () async -> [String: Double]?

    private let fetchPrices: PriceFetcher
    private var currentPrices: [String: Double]?
    private var refreshLoop: Task<Void, Never>?
    private var request: (id: UUID, task: Task<[String: Double]?, Never>)?

    public init(fetchPrices: @escaping PriceFetcher) { self.fetchPrices = fetchPrices }

    public convenience init(urlSession: URLSession) {
        self.init(fetchPrices: { await Self.fetchPrices(using: urlSession) })
    }

    isolated deinit {
        refreshLoop?.cancel()
        request?.task.cancel()
    }

    public func start() {
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

    public func update() async {
        let current: (id: UUID, task: Task<[String: Double]?, Never>)
        if let request {
            current = request
        } else {
            let fetchPrices = fetchPrices
            let task = Task { await fetchPrices() }
            current = (UUID(), task)
            request = current
        }
        let prices = await current.task.value
        guard request?.id == current.id else { return }
        request = nil
        if let prices { currentPrices = prices }

    }

    public func forNetwork(_ network: EthereumNetwork) -> Double? {
        guard network.mightShowPrice else { return nil }
        return currentPrices?[network.symbol]
    }

    @concurrent
    private nonisolated static func fetchPrices(using session: URLSession) async -> [String: Double]? {
        let ids = Prices.CodingKeys.allCases.map(\.rawValue).joined(separator: "%2C")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
            let prices = try JSONDecoder().decode(Prices.self, from: data)
            return ["ETH": prices.eth?.usd, "BNB": prices.bnb?.usd, "MATIC": prices.matic?.usd, "FTM": prices.ftm?.usd, "AVAX": prices.avax?.usd].compactMapValues { $0 }
        } catch {
            return nil
        }
    }
}

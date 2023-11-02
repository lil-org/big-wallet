// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

class PriceService {
    
    private struct Prices: Codable {
        
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
    
    private struct Price: Codable {
        let usd: Double
    }
    
    static let shared = PriceService()
    private let jsonDecoder = JSONDecoder()
    private let urlSession = URLSession(configuration: .ephemeral)
    private let idsQuery: String = {
        let ids = Prices.CodingKeys.allCases.map { $0.rawValue }
        return ids.joined(separator: "%2C")
    }()
    
    private init() {}
    
    private var currentPrices: Prices?
    
    func start() {
        getPrice(scheduleNextRequest: true)
    }
    
    func update() {
        getPrice(scheduleNextRequest: false)
    }
    
    func forNetwork(_ network: EthereumNetwork) -> Double? {
        guard network.mightShowPrice else { return nil }
        switch network.symbol {
        case "ETH":
            return currentPrices?.eth?.usd
        case "BNB":
            return currentPrices?.bnb?.usd
        case "FTM":
            return currentPrices?.ftm?.usd
        case "MATIC":
            return currentPrices?.matic?.usd
        case "AVAX":
            return currentPrices?.avax?.usd
        default:
            return nil
        }
    }
    
    private func getPrice(scheduleNextRequest: Bool) {
        let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(idsQuery)&vs_currencies=usd")!
        let dataTask = urlSession.dataTask(with: url) { [weak self] (data, _, _) in
            if let data = data,
               let pricesResponse = try? self?.jsonDecoder.decode(Prices.self, from: data) {
                DispatchQueue.main.async {
                    self?.currentPrices = pricesResponse
                }
            }
            if scheduleNextRequest {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(300)) { self?.start() }
            }
        }
        dataTask.resume()
    }
    
}

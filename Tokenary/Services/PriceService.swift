// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

class PriceService {
    
    private struct PriceResponse: Codable {
        let ethereum: Price
    }
    
    private struct Price: Codable {
        let usd: Double
    }
    
    static let shared = PriceService()
    private let jsonDecoder = JSONDecoder()
    private let urlSession = URLSession(configuration: .ephemeral)
    
    private init() {}
    
    var currentPrice: Double?
    
    func start() {
        getPrice(scheduleNextRequest: true)
    }
    
    func update() {
        getPrice(scheduleNextRequest: false)
    }
    
    private func getPrice(scheduleNextRequest: Bool) {
        let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd")!
        let dataTask = urlSession.dataTask(with: url) { [weak self] (data, _, _) in
            if let data = data,
               let priceResponse = try? self?.jsonDecoder.decode(PriceResponse.self, from: data) {
                DispatchQueue.main.async {
                    self?.currentPrice = priceResponse.ethereum.usd
                }
            }
            if scheduleNextRequest {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(300)) { self?.start() }
            }
        }
        dataTask.resume()
    }
    
}

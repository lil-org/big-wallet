// Copyright © 2021 Tokenary. All rights reserved.

import Foundation

//ServiceLocator.shared.testService
//    .combineLatest(.getUsers(userIds: [123,123]), .getVasys())
//    .subscribe {
//        onNext: {
//            
//        }
//    }
//
//open class AnyService: NSObject {
//    public private(set) retrier:
//    public private(set) queue:
//    public private(set) middleware:
//}
//
//
//class A {
//    func a() {
//        let vasya: AnyService
//        let vaysaObservable = vasya.observeValue(forKeyPath: \.retrier, of: vasay, change: [NSKeyValueChangeKey.newKey : true], context: )
//    }
//}
//
//public final class TestService: AnyService {
//    
//    var currentPrive: Relay<Double>
//    ///
//    
//    public func getUsers(userIds: [Int]) -> Observable<User, Error> {
//        self.sendRequest(
//            withParameters: requestConfig.obtainUserParameters(userIds: userIds),
//            intermidiateTransform: { (response: ApiResponseDTO<[UserDTO]>) -> in
//                let users = response.data.compactMap { UserEntity(dto: $0) }
//                self.saveToCache(...)
//                return users
//            },
//            jsonDecoder: ...
//        )
//    }
//}

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

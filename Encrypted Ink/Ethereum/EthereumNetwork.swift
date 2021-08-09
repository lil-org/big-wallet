// Copyright © 2021 Encrypted Ink. All rights reserved.

import Foundation
import Web3Swift

final class EthereumNetwork: Network {
    
    static let allByChain: [EthereumChain: Network] = [
        .main: EthereumNetwork(url: "https://eth-mainnet.alchemyapi.io/v2/" + Secrets.alchemy),
        .polygon: EthereumNetwork(url: "https://polygon-mainnet.g.alchemy.com/v2/" + Secrets.alchemy),
        .arbitrum: EthereumNetwork(url: "https://arb-mainnet.g.alchemy.com/v2/" + Secrets.alchemy),
        .optimism: EthereumNetwork(url: "https://mainnet.optimism.io"),
        .binance: EthereumNetwork(url: "https://bsc-dataseed.binance.org/"),
        .ronin: EthereumNetwork(url: "https://api.roninchain.com/rpc/")
    ]
    
    private let origin: GethNetwork
    
    init(url: String) {
        origin = GethNetwork(url: url)
    }
    
    func id() throws -> IntegerScalar {
        return try origin.id()
    }
    
    func call(method: String, params: [EthParameter]) throws -> Data {
        return try origin.call(method: method, params: params)
    }
    
}

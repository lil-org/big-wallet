// Copyright © 2021 Tokenary. All rights reserved.

import Foundation
import Web3Swift

final class EthereumNetwork: Network {
    
    private static var netwotkForChain = [EthereumChain: Network]()
    
    static func forChain(_ chain: EthereumChain) -> Network {
        if let network = netwotkForChain[chain] {
            return network
        } else {
            let network = EthereumNetwork(url: chain.nodeURLString)
            netwotkForChain[chain] = network
            return network
        }
    }
    
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

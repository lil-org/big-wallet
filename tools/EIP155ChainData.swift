// Copyright © 2023 Tokenary. All rights reserved.

import Foundation

// https://github.com/ethereum-lists/chains/blob/master/tools/schema/chainSchema.json

struct EIP155ChainData: Codable {
    
    let name: String // Name of the Network
    let shortName: String
    let chain: String
    let chainId: Int
    let networkId: Int
    let rpc: [String]
    let faucets: [String]
    let infoURL: String
    let nativeCurrency: NativeCurrency

    let title: String?
    let icon: String? // Icon type
    let features: [Feature]?
    let slip44: Int?
    let ens: ENS?
    let explorers: [Explorer]?
    let parent: Parent?
    let status: String? // Chain status
    let redFlags: [RedFlag]?

    struct NativeCurrency: Codable {
        let name: String // Name of the Native Currency
        let symbol: String // Symbol of the Native Currency
        let decimals: Int // Decimal points supported
    }

    struct Feature: Codable {
        let name: String // Feature name - e.g. EIP155
    }

    struct ENS: Codable {
        let registry: String
    }

    struct Explorer: Codable {
        let name: String
        let url: String
        let standard: String? // EIP3091 or none
    }

    struct Parent: Codable {
        let type: String
        let chain: String
        let bridges: [Bridge]?

        struct Bridge: Codable {
            let url: String
        }
    }

    enum RedFlag: String, Codable {
        case reusedChainId = "reusedChainId"
    }
    
}

// ∅ 2026 lil org

// https://github.com/ethereum-lists/chains/blob/master/tools/schema/chainSchema.json

struct EIP155ChainData: Decodable {
    
    let name: String // Name of the Network
    let chainId: Int
    let rpc: [String]
    let nativeCurrency: NativeCurrency

    let explorers: [Explorer]?
    let status: String? // Chain status
    let redFlags: [RedFlag]?

    struct NativeCurrency: Decodable {
        let symbol: String // Symbol of the Native Currency
        let decimals: Int // Decimal points supported
    }

    struct Explorer: Decodable {
        let url: String
    }

    enum RedFlag: String, Decodable {
        case reusedChainId = "reusedChainId"
    }
    
}

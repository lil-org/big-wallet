import Foundation
import WalletDomain

func forbidden(_ data: Data) throws { _ = try JSONDecoder().decode(PreparedEthereumTypedData.self, from: data) }

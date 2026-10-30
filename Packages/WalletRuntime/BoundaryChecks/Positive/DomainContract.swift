import Foundation
import WalletDomain

func domainContract(account: WalletAccount, request: SafariRequest, transaction: Transaction) throws -> Data {
    let handle = RequestHandle(id: request.id, token: RequestToken(value: UUID()), profileIdentifier: nil)
    _ = WalletSnapshot(id: "fixture", isMnemonic: true, accounts: [account])
    _ = transaction.from
    if let prepared = PreparedEthereumTypedData(json: "{}") {
        let _: String = prepared.rawJSON
        let _: Data = prepared.digest
        _ = SignaturePayload.ethereumTypedData(prepared)
    }
    return try JSONEncoder().encode(handle.token)
}

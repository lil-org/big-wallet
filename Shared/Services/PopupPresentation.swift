import Foundation
import WalletDomain
import WalletAuthority
import WalletFlows
import WalletNetworking

@MainActor
enum PopupPresentation {
    static func make(networks: NetworkResolver, prices: PriceService,
                     accountName: @escaping @MainActor @Sendable (String, WalletAccount) -> String?) -> PopupApprovalStatePresenter.Environment {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return .init(
            networks: { networks.allNetworks }, customNetworks: { networks.visibleCustomNetworks },
            price: { prices.forNetwork($0) },
            accountName: { accountName($0, $1) ?? $1.croppedAddress },
            icon: { account in
                guard let data = account.image?.pngDataRepresentation else { return nil }
                return "data:image/png;base64," + data.base64EncodedString()
            },
            transactionValue: { $0.valueWithSymbol(chain: $1, price: $2, withLabel: true) },
            transactionFeeLines: { $0.feeSummaryLines(chain: $1, price: $2) },
            transactionDataInterpretation: { $0.diplayDataInterpretation },
            solanaClusterDescription: { $0.description(for: $1) },
            approvalSubjectTitle: { $0.title },
            transactionNotice: { PopupTransactionNotice(title: $0.title, message: $0.message) },
            popupStrings: Strings.popup,
            layoutDirection: Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rtl : .ltr
        )
    }

}

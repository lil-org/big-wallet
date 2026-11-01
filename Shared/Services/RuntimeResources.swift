import Foundation
import WalletDomain
import WalletAuthority

@MainActor
enum RuntimeResources {
    static func configuration(storage: AuthorityStorageConfiguration = .application) -> AuthorityRuntimeConfiguration {
        let catalog: NetworkCatalog?
        let decodedChainIDs: Set<Int>
        do {
            catalog = try NetworkCatalog.load(in: .main)
            decodedChainIDs = []
        } catch {
            catalog = nil
            if let failure = error as? NetworkCatalogLoadError, case .invalidCatalog(let identifiers) = failure {
                decodedChainIDs = identifiers
            } else {
                decodedChainIDs = []
            }
        }
        return AuthorityRuntimeConfiguration(catalog: catalog, catalogOwnedChainIds: BundledNetworkOwnership.chainIds,
            decodedChainIds: decodedChainIDs, storage: storage, messages: messages)
    }

    static var messages: AuthorityMessages {
        AuthorityMessages(values: [
            .manualSwitchCapacityReached: Strings.manualSwitchCapacityReached,
            .addAccountToConnect: Strings.addAccountToConnect,
            .addNetwork: Strings.addNetwork,
            .approvalInterrupted: Strings.approvalInterrupted,
            .calculating: Strings.calculating,
            .cancel: Strings.cancel,
            .canceled: Strings.canceled,
            .connect: Strings.connect,
            .connectWallet: Strings.connectWallet,
            .data: Strings.data,
            .failedToLoad: Strings.failedToLoad,
            .failedToSend: Strings.failedToSend,
            .failedToSign: Strings.failedToSign,
            .failedToVerify: Strings.failedToVerify,
            .feesUpdated: Strings.feesUpdated,
            .feesUpdatedReview: Strings.feesUpdatedReview,
            .privateBrowsingUnsupported: Strings.privateBrowsingUnsupported,
            .providerNotReady: Strings.providerNotReady,
            .rawSolanaTransactionWarning: Strings.rawSolanaTransactionWarning,
            .secureApprovalSetupRequired: Strings.secureApprovalSetupRequired,
            .sendTransaction: Strings.sendTransaction,
            .solanaBlockhashNotFound: Strings.solanaBlockhashNotFound,
            .solanaConfirmationTimedOut: Strings.solanaConfirmationTimedOut,
            .somethingWentWrong: Strings.somethingWentWrong,
            .switchAccount: Strings.switchAccount,
            .transactionSubmissionStatusUnknown: Strings.transactionSubmissionStatusUnknown,
            .unrecognizedChainId: Strings.unrecognizedChainId,
            .unsafeFees: Strings.unsafeFees,
            .unsafeFeesEdit: Strings.unsafeFeesEdit,
            .unsupportedSolanaSendOptions: Strings.unsupportedSolanaSendOptions,
        ])
    }
}

extension NetworkCatalog {
    static func load(in bundle: Bundle = .main) throws -> NetworkCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw NetworkCatalogLoadError.missingResource
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NetworkCatalogLoadError.unreadableResource
        }

        do {
            return try NetworkCatalog(data: data)
        } catch {
            throw NetworkCatalogLoadError.invalidCatalog(
                decodedChainIds: decodedChainIds(from: data)
            )
        }
    }

}

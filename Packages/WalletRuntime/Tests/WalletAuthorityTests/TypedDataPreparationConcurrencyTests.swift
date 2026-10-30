import Foundation
import Synchronization
import XCTest
import WalletDomain
@testable import WalletAuthority

@MainActor
final class TypedDataPreparationConcurrencyTests: XCTestCase {
    func testCatalogResolutionPreparesTypedDataOnceOffMainActor() async throws {
        let (binding, catalog) = try fixture()
        let observations = Mutex([Bool]())
        let processor = requestProcessorForTesting(ethereumSigningContent: { body in
            observations.withLock { $0.append(Thread.isMainThread) }
            return EthereumDappRequestProcessor.signingReviewContent(for: body)
        })
        var catalogReads = 0
        let prepared = await processor.prepare(binding, loadingCatalog: {
            catalogReads += 1
            return catalog
        })
        guard case .prepared(.approval(let intent), let loadedCatalog) = prepared,
              case .approveMessage(let action) = intent.action,
              case .signature(.ethereumTypedData(let typed)) = action.payload else {
            return XCTFail("Expected the prepared typed-data review")
        }
        XCTAssertEqual(observations.withLock { $0 }, [false])
        XCTAssertEqual(catalogReads, 1)
        XCTAssertEqual(loadedCatalog?.identity, catalog.identity)
        XCTAssertEqual(typed.rawJSON, WalletCoreProxyTestVectors.typedDataJSON)
        XCTAssertEqual(WalletEncoding.hexString(typed.digest), WalletCoreProxyTestVectors.typedDataDigest)
        XCTAssertEqual(action.meta, typed.rawJSON)
        XCTAssertEqual(intent.binding, binding)
    }

    func testCatalogContinuationReusesPreparedContentWithFreshCatalog() async throws {
        let (binding, catalog) = try fixture()
        let calls = Mutex(0)
        let processor = requestProcessorForTesting(ethereumSigningContent: { body in
            calls.withLock { $0 += 1 }
            return EthereumDappRequestProcessor.signingReviewContent(for: body)
        })
        guard case .needsCatalog(let resolve) = await processor.prepare(binding, catalog: nil) else {
            return XCTFail("Expected deferred catalog resolution")
        }
        guard case .approval(let intent) = resolve(catalog),
              case .approveMessage(let action) = intent.action else {
            return XCTFail("The original catalog must produce a review")
        }
        XCTAssertEqual(action.account, catalog.orderedAccounts.first?.account)
        let empty = WalletReviewCatalog(identity: catalog.identity, orderedAccounts: [])
        guard case .immediate = resolve(empty) else {
            return XCTFail("The continuation must use the latest account availability")
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testCancelledBackgroundPreparationDiscardsLateContentWithoutLoadingCatalog() async throws {
        let (binding, catalog) = try fixture()
        let started = expectation(description: "Background preparation started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let ranOnMainThread = Mutex<Bool?>(nil)
        guard case .ethereum(let body) = binding.request.body else { return XCTFail("Expected Ethereum request") }
        let content = try XCTUnwrap(EthereumDappRequestProcessor.signingReviewContent(for: body))
        let processor = requestProcessorForTesting(ethereumSigningContent: { _ in
            ranOnMainThread.withLock { $0 = Thread.isMainThread }
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return content
        })
        var catalogReads = 0
        let pending = Task {
            await processor.prepare(binding, loadingCatalog: {
                catalogReads += 1
                return catalog
            })
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(ranOnMainThread.withLock { $0 }, false)
        pending.cancel()
        release.signal()
        guard case .prepared(.unavailable, nil) = await pending.value else {
            return XCTFail("Cancelled preparation must discard the completed content")
        }
        XCTAssertEqual(catalogReads, 0)
    }

    func testPreCancelledPreparationDoesNotStartTypedDataWork() async throws {
        let (binding, catalog) = try fixture()
        let calls = Mutex(0)
        let processor = requestProcessorForTesting(ethereumSigningContent: { body in
            calls.withLock { $0 += 1 }
            return EthereumDappRequestProcessor.signingReviewContent(for: body)
        })
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await processor.prepare(binding, catalog: catalog)
        }
        guard case .unavailable = await pending.value else {
            return XCTFail("Cancelled preparation must remain unavailable")
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    private func fixture() throws -> (ExtensionBridge.RequestBinding, WalletReviewCatalog) {
        let store = try ApprovedExecutionTestFixture()
        let account = WalletAccountDescriptor(
            walletID: "wallet", coin: .ethereum,
            normalizedAddress: WalletCoreProxyTestVectors.ethereumSignerAddress.lowercased(),
            derivationPath: "m/44'/60'/0'/0/0"
        )
        try store.establishGrant(account)
        let snapshot = try store.enqueue(
            id: 1, name: "signTypedMessage", provider: .ethereum,
            body: ["address": account.normalizedAddress, "chainId": "0x1",
                   "object": ["raw": WalletCoreProxyTestVectors.typedDataJSON]]
        )
        let catalog = WalletReviewCatalog(
            identity: .init(generation: nil, catalogData: Data()),
            orderedAccounts: [account.specificAccount]
        )
        return (try XCTUnwrap(snapshot.requestBinding), catalog)
    }
}

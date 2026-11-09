import Foundation
import XCTest
import Synchronization
import WalletDomain
@testable import WalletAuthority
#if os(macOS)
import AppKit
@testable import Big_Wallet

@MainActor
final class TransactionApprovalCoordinatorTests: XCTestCase {
    func testSigningAuthenticationRetryPreservesReviewAndRequiresFreshAuthenticationBeforePreflight() async throws {
        let transaction = Self.makeReadyTransaction()
        let network = Self.makeNetwork()
        let account = WalletAccountDescriptor(walletID: "authentication-retry", coin: .ethereum,
            normalizedAddress: transaction.from, derivationPath: "m/44'/60'/0'/0/0")
        let fixture = try ApprovedExecutionTestFixture()
        try fixture.establishGrant(account, network: network)
        let snapshot = try fixture.enqueue(id: 81, name: "signTransaction", provider: .ethereum, body: [
            "address": transaction.from, "chainId": network.chainIdHexString,
            "object": ["to": transaction.to, "value": "0x0", "data": "0x", "nonce": "0x0", "gas": "0x5208", "gasPrice": "0xa"],
        ])
        let action = DappRequestAction.approveTransaction(.init(transaction: transaction,
            resolvedNetwork: .init(network: network, source: .custom), walletId: account.walletID, account: account.account))
        let review = NativeApprovalReview(intent: try reviewIntentForTesting(binding: XCTUnwrap(snapshot.requestBinding), action: action))
        defer { review.invalidate() }
        let stub = ApprovalOperationsStub()
        var approvals = 0
        let controller = ApproveTransactionViewController.with(transaction: transaction, chain: network,
            account: account.account, walletId: account.walletID, review: review, operations: stub.operations) { result in
                XCTAssertNotNil(result)
                approvals += 1
            }
        let window = accountSelectionWindow(controller: controller)
        defer { controller.retire(); window.close() }
        let preparation = try XCTUnwrap(stub.preparationCalls.last)
        preparation.completion(.success(transaction))
        guard await expectEventually({ controller.okButton.isEnabled }) else { return }

        var challenges = [WalletAuthenticationChallenge]()
        var outcome = WalletAuthenticationResult.failed
        controller.authenticate = { [weak controller] _, challenge, currentReview in
            XCTAssertTrue(currentReview === review)
            XCTAssertEqual(controller?.titleLabel.stringValue, Strings.sendTransaction)
            challenges.append(challenge)
            return outcome
        }
        for failure in [WalletAuthenticationResult.failed, .interactionUnavailable, .cancelled] {
            outcome = failure
            let calls = challenges.count
            controller.actionButtonTapped(controller.okButton as Any)
            guard await expectEventually({ challenges.count == calls + 1 && controller.okButton.isEnabled }) else { return }
            let cancelled = if case .cancelled = failure { true } else { false }
            XCTAssertEqual(controller.titleLabel.stringValue, cancelled ? Strings.sendTransaction : Strings.failedToVerify)
            XCTAssertEqual(controller.okButton.title, cancelled ? Strings.ok : Strings.tryAgain)
            XCTAssertTrue(stub.preflightCalls.isEmpty)
            XCTAssertEqual(approvals, 0)
            let challenge = try XCTUnwrap(challenges.last)
            XCTAssertFalse(challenge.isPending(for: challenge.authorityID))
        }

        controller.authenticate = { _, challenge, _ in
            challenges.append(challenge)
            guard let grant = challenge.issueGrant(for: challenge.authorityID, credentialIdentity: .init(status: { .current })) else {
                XCTFail("A fresh signing challenge must accept authentication")
                return .failed
            }
            return .granted(grant)
        }
        controller.actionButtonTapped(controller.okButton as Any)
        await waitForCalls(stub, .preflight, count: 1)
        XCTAssertEqual(challenges.count, 4)
        XCTAssertEqual(Set(challenges.map(ObjectIdentifier.init)).count, 4)
        XCTAssertEqual(stub.preparationCalls.count, 1)
        XCTAssertEqual(approvals, 0)
        let preflight = try XCTUnwrap(stub.preflightCalls.first)
        preflight.completion(.safe(preflight.transaction, Self.makeLegacyEstimate()))
        await expectEventually { approvals == 1 }
    }

    func testPreparationSnapshotChecksAccessBeforeEnablingApproval() async throws {
        let access = WalletAccessTestFixture()
        try access.unlock()
        let transaction = Self.makeReadyTransaction()
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(transaction: transaction, stub: stub)
        let review = try nativeReviewForTesting()
        defer { review.invalidate() }
        let account = WalletAccount(address: transaction.from, coin: .ethereum, derivation: .default,
            derivationPath: "m/44'/60'/0'/0/0", publicKey: "", extendedPublicKey: "")
        let controller = ApproveTransactionViewController.with(transaction: transaction, chain: Self.makeNetwork(),
            account: account, walletId: "expired-review", review: review) { _ in XCTFail("Unexpected approval") }
        controller.walletAccess = NativeWalletAccess(access.access)
        _ = controller.view
        controller.invalidateNativeApprovalReview()
        coordinator.onSnapshot = { controller.render($0) }
        coordinator.startPreparation(forceGasCheck: false)
        let call = try XCTUnwrap(stub.preparationCalls.last)
        XCTAssertFalse(controller.okButton.isEnabled)
        access.advance(by: .seconds(900))
        call.completion(.success(transaction))
        await waitForSnapshot(coordinator) { $0.phase == .ready }
        XCTAssertTrue(access.access.isLocked)
        XCTAssertFalse(controller.okButton.isEnabled)
    }

    func testNewFeeNoticeIsVisibleAfterScrollingTransactionDetails() async throws {
        var transaction = Self.makeReadyTransaction()
        transaction.interpretation = (1...100).map { "Transaction detail line \($0)" }.joined(separator: "\n")
        let stub = ApprovalOperationsStub()
        let coordinator = makeCoordinator(transaction: transaction, stub: stub)
        await prepareToReady(coordinator, stub: stub)
        let review = try nativeReviewForTesting()
        let account = WalletAccount(
            address: transaction.from, coin: .ethereum, derivation: .default,
            derivationPath: "m/44'/60'/0'/0/0", publicKey: "", extendedPublicKey: ""
        )
        let controller = ApproveTransactionViewController.with(
            transaction: transaction, chain: Self.makeNetwork(), account: account,
            walletId: "notice-scroll-test", review: review
        ) { _ in XCTFail("Displaying a notice must not approve") }
        _ = controller.view
        controller.invalidateNativeApprovalReview()
        defer { review.invalidate() }
        coordinator.onSnapshot = { [weak controller] in controller?.render($0) }
        controller.render(coordinator.snapshot)
        let textView = try XCTUnwrap(controller.metaTextView)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        let layout = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        func scrollDown() {
            controller.view.layoutSubtreeIfNeeded()
            layout.ensureLayout(for: container)
            textView.sizeToFit()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 800))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        for index in 0..<2 {
            scrollDown()
            XCTAssertGreaterThan(textView.visibleRect.minY, 500)
            let position = scrollView.contentView.bounds.origin
            controller.render(coordinator.snapshot)
            XCTAssertEqual(scrollView.contentView.bounds.origin, position)

            let task = startPreflight(coordinator)
            await waitForCalls(stub, .preflight, count: index + 1)
            let call = stub.preflightCalls[index]
            var updated = call.transaction
            updated.replacePreparedFee(.legacy(gasPrice: BigUInt(UInt64(200 + index))), provenance: .init(gasPrice: .automatic))
            call.completion(.walletManagedUpdated(updated, Self.makeEstimate()))
            guard case .reviewRequired = await task.value else { return XCTFail("Expected a fee notice") }
            layout.ensureLayout(for: container)
            let range = (textView.string as NSString).range(of: Strings.feesUpdated)
            XCTAssertNotEqual(range.location, NSNotFound)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let noticeRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            XCTAssertTrue(noticeRect.intersects(textView.visibleRect))
            XCTAssertTrue(controller.okButton.isEnabled)
        }
    }


    func testNativePrimaryActionAndDescriptionFollowInlineRecovery() async throws {
        let cases: [(
            TransactionReviewNotice,
            ApproveTransactionViewController.PrimaryAction,
            (Transaction, GasEstimate) -> TransactionFeePreflightResult
        )] = [
            (.feesUpdated, .approve, { transaction, estimate in
                var updated = transaction
                updated.replacePreparedFee(.legacy(gasPrice: 200), provenance: .init(gasPrice: .automatic))
                return .walletManagedUpdated(updated, estimate)
            }),
            (.unsafeFees, .edit, { .userControlledUnsafe($0, $1) }),
            (.feesUnavailable, .retry, { .unavailable($0, $1) }),
        ]
        for (notice, primaryAction, result) in cases {
            let stub = ApprovalOperationsStub()
            let coordinator = makeCoordinator(stub: stub)
            await prepareToReady(coordinator, stub: stub)
            XCTAssertEqual(ApproveTransactionViewController.primaryAction(for: coordinator.snapshot), .approve)
            let reservation = try XCTUnwrap(coordinator.reserveForPreflight())
            XCTAssertEqual(ApproveTransactionViewController.primaryAction(for: coordinator.snapshot), .unavailable)
            let task = Task { await coordinator.preflight(reservation) }
            await waitForCalls(stub, .preflight, count: 1)
            XCTAssertTrue(stub.preflightCalls.count == 1)
            let call = stub.preflightCalls[0]
            call.completion(result(call.transaction, Self.makeEstimate()))
            guard case .reviewRequired = await task.value else { return XCTFail("Expected inline recovery") }

            XCTAssertEqual(coordinator.snapshot.notice, notice)
            XCTAssertEqual(ApproveTransactionViewController.primaryAction(for: coordinator.snapshot), primaryAction)
            let description = ApproveTransactionViewController.approvalDescription(
                transaction: coordinator.snapshot.transaction,
                chain: Self.makeNetwork(),
                price: nil,
                notice: coordinator.snapshot.notice
            )
            XCTAssertTrue(description.hasPrefix(notice.title))
            if let message = notice.message { XCTAssertTrue(description.contains(message)) }
            XCTAssertTrue(description.contains(Self.makeNetwork().name))
        }
        XCTAssertEqual(ApproveTransactionViewController.PrimaryAction.retry.title, Strings.tryAgain)
        XCTAssertEqual(ApproveTransactionViewController.PrimaryAction.edit.title, Strings.editFees)
    }
}
#endif

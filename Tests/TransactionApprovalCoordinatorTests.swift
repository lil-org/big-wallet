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

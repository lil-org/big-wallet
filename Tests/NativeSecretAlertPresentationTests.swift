import WalletDomain
@testable import WalletAuthority
import AppKit
import Synchronization
import XCTest
@testable import Big_Wallet

@MainActor
final class NativeSecretAlertPresentationTests: XCTestCase {
    func testCopyRevalidatesTheExportBeforeCatalogNotification() async throws {
        let fixture = PresentationFixture()
        defer { fixture.close() }
        let alert = try await fixture.show(WalletExportedSecret(text: "private-key"))
        fixture.exportIsCurrent = false

        alert.buttons[1].performClick(nil)

        await expectEventually { fixture.presentation?.alert == nil }
        XCTAssertTrue(fixture.copies.isEmpty)
        XCTAssertNil(fixture.presentation?.alert)
    }

    func testCatalogChangeDuringValidationDiscardsTheEarlierResult() async throws {
        let fixture = PresentationFixture()
        defer { fixture.close() }
        let alert = try await fixture.show(WalletExportedSecret(text: "private-key"))
        let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
        let checking = expectation(description: "First source validation started")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        var checks = 0
        fixture.checkExport = {
            checks += 1
            if checks == 1 {
                checking.fulfill()
                await release.wait()
                return true
            }
            return false
        }
        fixture.presentation?.sourceDidChange()
        XCTAssertEqual(field.stringValue, "")
        await fulfillment(of: [checking], timeout: 2)
        fixture.presentation?.sourceDidChange()
        release.resolve(())
        await expectEventually { fixture.presentation?.alert == nil }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(fixture.copies.isEmpty)
    }

    func testCopyPreservesANewerPasteboardWriteWhileValidationIsPending() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let fixture = PresentationFixture(pasteboardChangeCount: { pasteboard.changeCount })
        defer { fixture.close() }
        let alert = try await fixture.show(WalletExportedSecret(text: "private-key"))
        let checking = expectation(description: "Copy validation started")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        fixture.checkExport = {
            checking.fulfill()
            await release.wait()
            return true
        }

        alert.buttons[1].performClick(nil)
        await fulfillment(of: [checking], timeout: 2)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("public address", forType: .string))
        release.resolve(())
        await expectEventually { fixture.presentation?.alert == nil }

        XCTAssertTrue(fixture.copies.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "public address")
    }

    func testNativeCopyActionRunsBeforeSheetIsDetached() async throws {
        var sheet: NSWindow?
        let fixture = PresentationFixture(beginCopy: { sheet?.sheetParent != nil })
        defer { fixture.close() }
        let secret = WalletExportedSecret(text: "private-key")
        let alert = try await fixture.show(secret)
        sheet = alert.window

        XCTAssertTrue(alert.window.sheetParent === fixture.window)
        alert.buttons[1].performClick(nil)

        await expectEventually { fixture.copies.count == 1 }
        XCTAssertEqual(fixture.copies, ["private-key"])
        XCTAssertNil(alert.window.sheetParent)
        XCTAssertFalse(secret.withText { _ in XCTFail("Copied secret was retained") })
    }

    func testCopyRenewsAccessAtClickOnly() async throws {
        let wallet = WalletAccessTestFixture()
        try wallet.unlock()
        let fixture = PresentationFixture(beginCopy: { wallet.access.recordInteraction() })
        defer { fixture.close() }
        fixture.checkSource = { wallet.access.validateCurrentAccess() }
        let alert = try await fixture.show(WalletExportedSecret(text: "private-key"))
        let checking = expectation(description: "Copy validation started")
        let release = TestGate<Void>()
        defer { release.resolve(()) }
        fixture.checkExport = {
            checking.fulfill()
            await release.wait()
            return true
        }

        wallet.advance(by: .seconds(899))
        alert.buttons[1].performClick(nil)
        await fulfillment(of: [checking], timeout: 2)
        wallet.advance(by: .seconds(2))
        XCTAssertTrue(wallet.access.validateCurrentAccess())
        release.resolve(())
        await expectEventually { fixture.presentation?.alert == nil }

        XCTAssertEqual(fixture.copies, ["private-key"])
        wallet.advance(by: .seconds(898))
        XCTAssertFalse(wallet.access.validateCurrentAccess())
    }

    func testKeyWindowValidationRejectsStaleOwnershipAndUnrelatedWindows() {
        let owner = ReportedKeyWindow()
        let sheet = ReportedKeyWindow()
        let unrelated = ReportedKeyWindow()
        XCTAssertTrue(NativeSecretAlertPresentation.acceptsKeyWindow(owner, owner: owner, sheetWindow: sheet))
        XCTAssertTrue(NativeSecretAlertPresentation.acceptsKeyWindow(sheet, owner: owner, sheetWindow: sheet))
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(unrelated, owner: owner, sheetWindow: sheet))
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(nil, owner: owner, sheetWindow: sheet))
        owner.reportsKey = false
        sheet.reportsKey = false
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(owner, owner: owner, sheetWindow: sheet))
        XCTAssertFalse(NativeSecretAlertPresentation.acceptsKeyWindow(sheet, owner: owner, sheetWindow: sheet))
    }

    func testResignedSheetCannotUseStaleKeyWindowReferenceToCopy() async throws {
        let fixture = PresentationFixture()
        defer { fixture.close() }
        let secret = WalletExportedSecret(text: "private-key")
        let alert = try await fixture.show(secret)
        let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
        alert.window.resignKey()
        fixture.currentKeyWindow = alert.window

        alert.buttons[1].performClick(nil)

        XCTAssertTrue(fixture.copies.isEmpty)
        XCTAssertNil(fixture.presentation?.alert)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertFalse(secret.withText { _ in XCTFail("Resigned secret was retained") })
    }

    func testCopyClearsPresentationBeforeCopyingAndOnlyRunsOnce() async throws {
        let fixture = PresentationFixture()
        defer { fixture.close() }
        let secret = WalletExportedSecret(text: "private-key")
        let alert = try await fixture.show(secret)
        let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
        let target = alert.buttons[1].target
        fixture.beforeCopy = {
            XCTAssertNil(fixture.presentation?.alert)
            XCTAssertNil(alert.window.sheetParent)
            XCTAssertEqual(field.stringValue, "")
            XCTAssertFalse(secret.withText { _ in XCTFail("Copy retained the secret") })
        }

        withExtendedLifetime(target) {
            alert.buttons[1].performClick(nil)
            alert.buttons[1].performClick(nil)
        }

        await expectEventually { !fixture.copies.isEmpty }
        XCTAssertEqual(fixture.copies, ["private-key"])
    }

    func testClosingAndAbortingNeverCopy() async throws {
        for response in [NSApplication.ModalResponse.alertFirstButtonReturn, .abort, .cancel, .init(rawValue: -7)] {
            let fixture = PresentationFixture()
            defer { fixture.close() }
            let secret = WalletExportedSecret(text: "seed words")
            let alert = try await fixture.show(secret)
            let field = try XCTUnwrap(alert.accessoryView as? NSTextField)

            fixture.window.endSheet(alert.window, returnCode: response)
            await expectEventually { fixture.presentation?.alert == nil }

            XCTAssertTrue(fixture.copies.isEmpty)
            XCTAssertEqual(field.stringValue, "")
            XCTAssertFalse(secret.withText { _ in XCTFail("Dismissed secret was retained") })
        }
    }

    func testRevocationPreventsLateCopyCallback() async throws {
        let fixture = PresentationFixture()
        defer { fixture.close() }
        let secret = WalletExportedSecret(text: "private-key")
        let alert = try await fixture.show(secret)
        let target = alert.buttons[1].target

        fixture.presentation?.invalidate()
        withExtendedLifetime(target) { alert.buttons[1].performClick(nil) }

        XCTAssertTrue(fixture.copies.isEmpty)
        XCTAssertFalse(secret.withText { _ in XCTFail("Revoked secret was retained") })
    }

    func testObsoletePresentationCannotCopyOrInvalidateReplacement() async throws {
        let fixture = PresentationFixture()
        defer { fixture.close() }
        let oldSecret = WalletExportedSecret(text: "old-secret")
        let oldAlert = try await fixture.show(oldSecret)
        let oldTarget = oldAlert.buttons[1].target
        let replacement = WalletExportedSecret(text: "new-secret")
        let currentAlert = try await fixture.show(replacement)

        withExtendedLifetime(oldTarget) { oldAlert.buttons[1].performClick(nil) }
        await Task.yield()

        XCTAssertTrue(fixture.copies.isEmpty)
        XCTAssertTrue(fixture.presentation?.alert === currentAlert)
        XCTAssertFalse(oldSecret.withText { _ in XCTFail("Old secret was retained") })
        XCTAssertTrue(replacement.withText { XCTAssertEqual($0, "new-secret") })
        currentAlert.buttons[1].performClick(nil)
        await expectEventually { !fixture.copies.isEmpty }
        XCTAssertEqual(fixture.copies, ["new-secret"])
    }

    func testInactiveOwnerCannotCopyAndDisplayDoesNotAllowUnprotectedCopying() async throws {
        let fixture = PresentationFixture()
        defer { fixture.close() }
        let secret = WalletExportedSecret(text: "private-key")
        let alert = try await fixture.show(secret)
        let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
        XCTAssertFalse(field.isSelectable)
        XCTAssertFalse(field.isEditable)
        fixture.sourceIsCurrent = false

        alert.buttons[1].performClick(nil)

        XCTAssertTrue(fixture.copies.isEmpty)
        XCTAssertFalse(secret.withText { _ in XCTFail("Inactive secret was retained") })
        XCTAssertEqual(field.stringValue, "")
    }

    func testAuthenticationSurvivesInactivityUntilOwnershipIsRechecked() async throws {
        for restoresActivity in [false, true] {
            let fixture = PresentationFixture()
            defer { fixture.close() }
            let work = SuspendedReveal()
            defer { work.release() }
            let token = try fixture.begin()
            fixture.presentation?.authenticateAndReveal(for: token, authenticate: {
                await work.authenticate()
            }, export: { _ in
                work.exports += 1
                return work.secret
            })
            await fulfillment(of: [work.entered], timeout: 2)

            fixture.applicationIsActive = false
            fixture.notifications.post(name: NSApplication.willResignActiveNotification, object: nil)
            fixture.presentation?.sourceWillDisappear()
            XCTAssertEqual(work.cancellations.withLock { $0 }, 0)
            fixture.applicationIsActive = restoresActivity
            work.release()
            await fulfillment(of: [work.returned], timeout: 2)
            await Task.yield()

            if restoresActivity {
                await expectEventually { fixture.presentation?.alert != nil }
                XCTAssertEqual(work.exports, 1)
            } else {
                XCTAssertEqual(work.exports, 0)
                XCTAssertNil(fixture.presentation?.alert)
            }
            XCTAssertFalse(work.grant.consume(authorityID: work.authorityID, purpose: work.purpose))
        }
    }

    func testCloseMinimizeLockAndStoreFailureRejectLateAuthenticationAndExport() async throws {
        for exporting in [false, true] {
            for event in 0..<4 {
                let fixture = PresentationFixture()
                defer { fixture.close() }
                let work = SuspendedReveal()
                defer { work.release() }
                try fixture.start(work, exporting: exporting)
                await fulfillment(of: [work.entered], timeout: 2)

                switch event {
                case 0: fixture.notifications.post(name: NSWindow.willCloseNotification, object: fixture.window)
                case 1: fixture.notifications.post(name: NSWindow.willMiniaturizeNotification, object: fixture.window)
                case 2: fixture.presentation?.invalidate()
                default: fixture.presentation?.invalidate()
                }
                await fulfillment(of: [work.cancelled], timeout: 2)
                work.release()
                await fulfillment(of: [work.returned], timeout: 2)
                await Task.yield()

                XCTAssertEqual(work.cancellations.withLock { $0 }, 1)
                XCTAssertNil(fixture.presentation?.alert)
                XCTAssertNil(fixture.window.attachedSheet)
                XCTAssertFalse(work.grant.consume(authorityID: work.authorityID, purpose: work.purpose))
                if exporting {
                    XCTAssertFalse(work.secret.withText { _ in XCTFail("Late export survived retirement") })
                } else {
                    XCTAssertEqual(work.exports, 0)
                }
            }
        }
    }

    func testReplacementPreservesItsSecretAfterLateAuthenticationAndExport() async throws {
        for exporting in [false, true] {
            let fixture = PresentationFixture()
            defer { fixture.close() }
            let work = SuspendedReveal()
            defer { work.release() }
            try fixture.start(work, exporting: exporting)
            await fulfillment(of: [work.entered], timeout: 2)
            let replacement = WalletExportedSecret(text: "replacement")
            let alert = try await fixture.show(replacement)
            await fulfillment(of: [work.cancelled], timeout: 2)

            work.release()
            await fulfillment(of: [work.returned], timeout: 2)
            await Task.yield()

            XCTAssertTrue(fixture.presentation?.alert === alert)
            XCTAssertTrue(replacement.withText { XCTAssertEqual($0, "replacement") })
            XCTAssertFalse(work.grant.consume(authorityID: work.authorityID, purpose: work.purpose))
            if exporting { XCTAssertFalse(work.secret.withText { _ in XCTFail("Late export survived replacement") }) }
            else { XCTAssertEqual(work.exports, 0) }
        }
    }

    func testOwnerDeallocationCancelsSuspendedWorkBeforeItReturns() async throws {
        for exporting in [false, true] {
            let fixture = PresentationFixture()
            defer { fixture.close() }
            let work = SuspendedReveal()
            defer { work.release() }
            try fixture.start(work, exporting: exporting)
            await fulfillment(of: [work.entered], timeout: 2)
            weak let owner = fixture.presentation

            fixture.presentation = nil

            await fulfillment(of: [work.cancelled], timeout: 2)
            XCTAssertNil(owner)
            work.release()
            await fulfillment(of: [work.returned], timeout: 2)
            await Task.yield()
            XCTAssertNil(fixture.window.attachedSheet)
            XCTAssertFalse(work.grant.consume(authorityID: work.authorityID, purpose: work.purpose))
            if exporting { XCTAssertFalse(work.secret.withText { _ in XCTFail("Late secret survived owner release") }) }
            else { XCTAssertEqual(work.exports, 0) }
        }
    }

    func testExportSurvivesAuthenticationOnlyCancellationButNotInactivity() async throws {
        for losesActivity in [false, true] {
            let fixture = PresentationFixture()
            defer { fixture.close() }
            let work = SuspendedReveal()
            defer { work.release() }
            try fixture.start(work, exporting: true)
            await fulfillment(of: [work.entered], timeout: 2)

            fixture.presentation?.cancelAuthentication()
            XCTAssertEqual(work.cancellations.withLock { $0 }, 0)
            if losesActivity {
                fixture.applicationIsActive = false
                fixture.notifications.post(name: NSApplication.willResignActiveNotification, object: nil)
                await fulfillment(of: [work.cancelled], timeout: 2)
            }
            work.release()
            await fulfillment(of: [work.returned], timeout: 2)
            await Task.yield()

            if losesActivity {
                XCTAssertNil(fixture.presentation?.alert)
                XCTAssertFalse(work.secret.withText { _ in XCTFail("Inactive export survived") })
            } else {
                await expectEventually { fixture.presentation?.alert != nil }
                XCTAssertEqual(work.cancellations.withLock { $0 }, 0)
            }
        }
    }
}

@MainActor
private final class PresentationFixture {
    let notifications = NotificationCenter()
    let window = ReportedKeyWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false)
    var presentation: NativeSecretAlertPresentation?
    var currentKeyWindow: NSWindow?
    var applicationIsActive = true
    var exportIsCurrent = true
    var checkExport: (() async -> Bool)?
    var sourceIsCurrent = true
    var checkSource: (() -> Bool)?
    var beforeCopy: (() -> Void)?
    var copies = [String]()

    init(beginCopy: @escaping () -> Bool = { true }, pasteboardChangeCount: @escaping () -> Int = { 0 }) {
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFront(nil)
        currentKeyWindow = window
        presentation = NativeSecretAlertPresentation(
            validateSource: { [weak self] _ in
                guard let self, sourceIsCurrent else { return false }
                return checkSource?() ?? true
            },
            validateExport: { [weak self] _ in
                if let check = self?.checkExport { return await check() }
                return self?.exportIsCurrent == true
            },
            beginCopy: beginCopy,
            pasteboardChangeCount: pasteboardChangeCount,
            copy: { [weak self] text in
                self?.beforeCopy?()
                self?.copies.append(text)
            },
            notifications: notifications,
            applicationIsActive: { [weak self] in self?.applicationIsActive == true },
            keyWindow: { [weak self] in self?.currentKeyWindow }
        )
    }

    func begin() throws -> NativeSecretAlertPresentation.Token {
        try XCTUnwrap(presentation?.begin(in: window, title: "Secret"))
    }

    func show(_ secret: WalletExportedSecret) async throws -> NSAlert {
        let token = try begin()
        let work = SuspendedReveal()
        presentation?.reveal(for: token, authorization: work.grant, export: { _ in secret })
        await expectEventually { self.presentation?.alert != nil }
        return try XCTUnwrap(presentation?.alert)
    }

    func start(_ work: SuspendedReveal, exporting: Bool) throws {
        let token = try begin()
        if exporting {
            presentation?.reveal(for: token, authorization: work.grant, export: { _ in await work.export() })
        } else {
            presentation?.authenticateAndReveal(for: token, authenticate: { await work.authenticate() }, export: { _ in
                work.exports += 1
                return work.secret
            })
        }
    }

    func close() {
        presentation?.invalidate()
        presentation = nil
        checkSource = nil
        beforeCopy = nil
        window.orderOut(nil)
    }
}

@MainActor
private final class SuspendedReveal {
    let authorityID = UUID()
    let purpose = WalletAuthenticationChallenge.Purpose.walletAccess(UUID())
    let grant: WalletAuthenticationGrant
    let secret = WalletExportedSecret(text: "late-secret")
    let entered = XCTestExpectation(description: "reveal operation entered")
    let returned = XCTestExpectation(description: "reveal operation returned")
    let cancelled = XCTestExpectation(description: "reveal operation cancelled")
    let cancellations = Mutex(0)
    private let gate = TestGate<Void>()
    var exports = 0

    init() {
        let challenge = WalletAuthenticationChallenge(authorityID: authorityID, purpose: purpose,
            deadline: .now + .seconds(150))
        grant = challenge.issueGrant(for: authorityID, credentialIdentity: .init(status: { .current }))!
    }

    func authenticate() async -> WalletAuthenticationGrant? {
        await wait()
        return grant
    }

    func export() async -> WalletExportedSecret {
        exports += 1
        await wait()
        return secret
    }

    func release() { gate.resolve(()) }

    private func wait() async {
        entered.fulfill()
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: { [self] in
            cancellations.withLock { $0 += 1 }
            cancelled.fulfill()
        }
        returned.fulfill()
    }
}

@MainActor
private final class ReportedKeyWindow: NSWindow {
    var reportsKey = true
    override var isKeyWindow: Bool { reportsKey }
}

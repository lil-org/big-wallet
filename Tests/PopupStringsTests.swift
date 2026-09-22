// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

// The popup's chrome is HTML, so these keys are a contract with the `data-string` attributes in
// popup.html and the `localized(...)` calls in popup.js. Both sides are read straight off disk:
// a hand-copied list here would pass while the popup rendered a raw key.
final class PopupStringsTests: XCTestCase {

    private let reviewToken = "00000000-0000-4000-8000-000000000092"

    private func popupRequest(
        subject: InternalSafariRequest.Subject.Popup,
        payload: Any? = nil,
        id: Int = 91
    ) throws -> InternalSafariRequest {
        var message: [String: Any] = [
            "id": id,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "subject": subject.rawValue,
            "requestToken": "00000000-0000-4000-8000-000000000091",
        ]
        if subject == .getPendingRequests {
            message["requestToken"] = nil
        }
        message["payload"] = payload
        if subject != .getApprovalState && subject != .retryApproval &&
            subject != .getPendingRequests && subject != .rejectRequest {
            message["reviewToken"] = "00000000-0000-4000-8000-000000000092"
        }
        let data = try JSONSerialization.data(withJSONObject: message)
        return try JSONDecoder().decode(InternalSafariRequest.self, from: data)
    }

    private func approvalStateRequest(id: Int = 91) throws -> InternalSafariRequest {
        return try popupRequest(
            subject: .getApprovalState,
            id: id
        )
    }

    private func reviewResponse(
        _ content: PopupReview.Content,
        title: String = "Review",
        iconURL: String? = nil,
        actions: [PopupApprovalState.Action] = [.approve, .reject]
    ) -> PopupResponse {
        .command(.ok(PopupApprovalState(
            id: 91,
            host: "wallet.example",
            content: .review(PopupReview(
                reviewToken: UUID(uuidString: reviewToken)!,
                title: title,
                iconURL: iconURL,
                content: content
            ), actions: actions, feedback: nil)
        )))
    }

    private func oversizedResponse() -> PopupResponse {
        reviewResponse(.signMessage(PopupMessageReview(
            meta: String(repeating: "x", count: PopupResponseEncoder.maximumResponseBytes),
            account: .init(name: "Primary", croppedAddress: "1111...1111"),
            clusterSelection: nil
        )))
    }

    private func selectionResponse(
        count: Int,
        name: (Int) -> String,
        icon: String? = nil
    ) -> PopupResponse {
        reviewResponse(.selectAccount(PopupSelectionReview(
            accounts: (0..<count).map { index in
                .init(
                    display: .init(name: name(index), croppedAddress: "0000...0000", icon: icon),
                    walletId: "wallet-\(index)",
                    address: "0x" + String(format: "%040x", index),
                    coin: .ethereum,
                    derivationPath: "m/44'/60'/0'/0/\(index)",
                    isSelected: false
                )
            },
            networks: (0..<count).map { index in
                .init(chainId: "0x" + String(index + 1, radix: 16), name: name(index),
                      isCustom: true, isSelected: index == count - 1)
            },
            canSelectNetwork: true,
            allowsEmptySelection: false,
            emptyMessage: nil,
            primaryTitle: nil
        )), iconURL: icon)
    }

    private func boundedResponse(
        _ response: PopupResponse,
        for request: InternalSafariRequest
    ) throws -> [String: Any] {
        let data = try PopupResponseEncoder.encode(response, for: request)
        XCTAssertLessThanOrEqual(data.count, PopupResponseEncoder.maximumResponseBytes)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if case .popup(.getPendingRequests) = request.command { return json }
        XCTAssertEqual(Set(json.keys), ["status", "approval"])
        return try XCTUnwrap(json["approval"] as? [String: Any])
    }

    private func resource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Safari Shared/Resources/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func localizableCatalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Supporting Files/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func matches(_ pattern: String, in text: String) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        var keys = Set<String>()
        for match in expression.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            keys.insert(String(text[keyRange]))
        }
        return keys
    }

    func testPopupStringsCoverEveryChromeKey() throws {
        let markupKeys = try matches("data-string=\"([^\"]+)\"", in: resource("popup.html"))
        let scriptKeys = try matches("localized\\(\"([^\"]+)\"", in: resource("popup.js"))
        XCTAssertFalse(markupKeys.isEmpty)
        XCTAssertFalse(scriptKeys.isEmpty)
        XCTAssertEqual(Set(Strings.popup.keys), markupKeys.union(scriptKeys))
    }

    func testPopupStringsAreNeverEmpty() {
        for (key, value) in Strings.popup {
            XCTAssertFalse(value.isEmpty, "empty popup string for \(key)")
        }
    }

    func testSafetyStringsCoverEveryCatalogLocale() throws {
        let catalog = try localizableCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let supportedLocales = strings.values.reduce(into: Set<String>()) {
            locales, entry in
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                return
            }
            locales.formUnion(localizations.keys)
        }
        XCTAssertFalse(supportedLocales.isEmpty)

        for key in [
            "Approval interrupted. Please try again from the website.",
            "Big Wallet requests are unavailable in Private Browsing.",
            "Safari approvals require a device passcode. Enable one in Settings if needed, then open Big Wallet and return to Safari to retry.",
            "Transaction submission status is unknown. Check the transaction ID before trying again.",
        ] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), supportedLocales, key)
            for (locale, localization) in localizations {
                let localization = try XCTUnwrap(
                    localization as? [String: Any],
                    "\(key) [\(locale)]"
                )
                let stringUnit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key) [\(locale)]"
                )
                XCTAssertEqual(
                    stringUnit["state"] as? String,
                    "translated",
                    "\(key) [\(locale)]"
                )
                let value = try XCTUnwrap(
                    stringUnit["value"] as? String,
                    "\(key) [\(locale)]"
                )
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(key) [\(locale)]"
                )
            }
        }
    }

    func testApprovalErrorHasExactRefreshOnlyEnvelope() {
        let error = popupApprovalJSON(PopupApprovalStatePresenter.errorState(
            id: 91,
            host: "wallet.example",
            error: Strings.failedToLoad
        ))

        XCTAssertEqual(Set(error.keys), ["id", "state", "actions", "host", "error"])
        XCTAssertEqual(error["state"] as? String, "error")
        XCTAssertEqual(error["error"] as? String, Strings.failedToLoad)
        XCTAssertNil(error["review"])
        XCTAssertEqual(error["actions"] as? [String], ["retry"])
    }

    @MainActor
    func testSecureSetupRequiredStateAllowsRefreshAndRejection() {
        let approval = PopupApprovalStatePresenter()
            .secureSetupRequiredState(id: 91, host: "wallet.example")
        let state = popupApprovalJSON(approval)

        XCTAssertEqual(
            Set(state.keys),
            ["id", "state", "actions", "host", "error"]
        )
        XCTAssertEqual(state["state"] as? String, "error")
        XCTAssertEqual(
            state["error"] as? String,
            Strings.secureApprovalSetupRequired
        )
        XCTAssertEqual(state["actions"] as? [String], ["retry", "reject"])
        XCTAssertTrue(approval.canReject)
        XCTAssertNil(state["review"])
    }

    @MainActor
    func testBeginningApprovalRemovesReviewContentAndActions() throws {
        let request = try XCTUnwrap(SafariRequest(json: [
            "id": 91,
            "name": "switchAccount",
            "provider": "unknown",
            "host": "wallet.example",
            "configurationKey": "wallet.example",
            "enqueueAttempt": String(repeating: "a", count: 32),
            "admissionDeadline": 2_050_000_000_000,
            "workflowVersion": ExtensionBridge.workflowVersion,
            "body": ["latestConfigurations": []],
        ]))
        let handle = ExtensionBridge.Handle(
            id: request.id,
            token: .init(value: UUID()),
            profileIdentifier: nil
        )
        let action = DappRequestAction.switchAccount(SelectAccountAction(
            coinType: nil,
            selectedAccounts: [],
            initiallyConnectedProviders: [],
            network: nil
        ))
        let session = PopupRequestSession(
            handle: handle,
            request: request,
            action: action
        )
        let presenter = PopupApprovalStatePresenter()
        let review = popupApprovalJSON(presenter.approvalState(
            for: session,
            action: action,
            transactionMutationAllowed: false
        ))
        XCTAssertEqual(review["actions"] as? [String], ["approve", "reject"])
        XCTAssertNotNil((review["review"] as? [String: Any])?["reviewToken"])
        XCTAssertNil(review["reviewToken"])

        let token = try XCTUnwrap(session.beginApproval())
        let claim = ExtensionBridge.ApprovalClaim(handle: handle, value: UUID())
        for expectedState in ["working", "authenticating"] {
            if expectedState == "authenticating" {
                XCTAssertTrue(session.acceptClaim(claim, token: token))
                XCTAssertTrue(session.beginAuthentication(claim: claim, token: token))
            }
            let busy = popupApprovalJSON(presenter.approvalState(
                for: session,
                action: action,
                transactionMutationAllowed: true
            ))
            XCTAssertEqual(busy["state"] as? String, expectedState)
            XCTAssertEqual(busy["actions"] as? [String], [])
            XCTAssertNil(busy["review"])
            XCTAssertEqual(Set(busy.keys), ["id", "state", "actions", "host"])
        }
    }

    func testRejectableErrorHasExactRejectOnlyEnvelope() {
        let error = popupApprovalJSON(PopupApprovalStatePresenter.errorState(
            id: 91,
            actions: [.reject],
            host: "wallet.example",
            error: Strings.failedToLoad
        ))

        XCTAssertEqual(
            Set(error.keys),
            ["id", "state", "actions", "host", "error"]
        )
        XCTAssertEqual(error["state"] as? String, "error")
        XCTAssertNil(error["review"])
        XCTAssertEqual(error["actions"] as? [String], ["reject"])
    }

    func testQueuePositionKeepsBothPositionalSpecifiers() {
        let template = Strings.popup["queuePosition"]
        XCTAssertEqual(template?.contains("%1$@"), true)
        XCTAssertEqual(template?.contains("%2$@"), true)
    }

    func testGweiUnitsRideAlongWithTheFeeLabels() {
        for key in ["gasPrice", "maxPriorityFee", "maxFee"] {
            XCTAssertEqual(Strings.popup[key]?.hasSuffix("(\(Strings.gwei))"), true, key)
        }
    }

    func testMoreThan256AccountAndNetworkChoicesRemainExactWhenTheyFit() throws {
        let bounded = try boundedResponse(
            selectionResponse(count: 300, name: { "Choice \($0)" }),
            for: approvalStateRequest()
        )
        let review = try XCTUnwrap(bounded["review"] as? [String: Any])
        let accounts = try XCTUnwrap(review["accounts"] as? [[String: Any]])
        let networks = try XCTUnwrap(review["networks"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 300)
        XCTAssertEqual(networks.count, 300)
        XCTAssertEqual(accounts.last?["name"] as? String, "Choice 299")
        XCTAssertEqual(networks.last?["name"] as? String, "Choice 299")
    }

    func testControlHeavySelectionBecomesAtomicFallbackWithoutShorteningLabels() throws {
        let response = selectionResponse(count: 256, name: { _ in String(repeating: "\u{0000}", count: 256) })
        let bounded = try boundedResponse(response, for: approvalStateRequest())
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["review"])
    }

    func testOversizedSelectionReturnsAtomicRejectOnlyFallback() throws {
        let bounded = try boundedResponse(
            selectionResponse(count: 4_000, name: { "Account \($0)" }),
            for: approvalStateRequest()
        )
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertNil(bounded["review"])
    }

    func testNonFiniteTransactionJSONUsesGenericFallback() throws {
        let response = reviewResponse(.sendTransaction(transactionReview(position: .nan)))
        let bounded = try boundedResponse(response, for: approvalStateRequest())
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertNil(bounded["review"])
    }

    func testLongAddChainNameRemainsExactWhenResponseFits() throws {
        let name = String(repeating: "Network ", count: 100) + "exact suffix"
        let bounded = try boundedResponse(
            reviewResponse(.addChain(.init(chainName: name, rpcURL: "https://rpc.example"))),
            for: approvalStateRequest()
        )
        let review = try XCTUnwrap(bounded["review"] as? [String: Any])
        XCTAssertEqual(review["chainName"] as? String, name)
        XCTAssertEqual(review["kind"] as? String, "addChain")
    }

    func testPopupResponseDropsDecorativeImagesBeforeFailingClosed() throws {
        let icon = "data:image/png;base64," + String(repeating: "A", count: PopupResponseEncoder.maximumResponseBytes)
        var transaction = transactionReview()
        transaction.account.icon = icon
        for response in [
            selectionResponse(count: 1, name: { _ in "Account" }, icon: icon),
            reviewResponse(.signMessage(.init(
                meta: "Preserve this message", account: .init(name: "Account", croppedAddress: "1111", icon: icon),
                clusterSelection: nil
            )), iconURL: icon),
            reviewResponse(.sendTransaction(transaction), iconURL: icon),
        ] {
            let bounded = try boundedResponse(response, for: approvalStateRequest())
            let review = try XCTUnwrap(bounded["review"] as? [String: Any])
            XCTAssertEqual(bounded["state"] as? String, "review")
            XCTAssertNil(review["iconURL"])
            XCTAssertNil((review["account"] as? [String: Any])?["icon"])
            XCTAssertNil((review["accounts"] as? [[String: Any]])?.first?["icon"])
            XCTAssertEqual(review["reviewToken"] as? String, reviewToken)
            XCTAssertEqual((popupApprovalJSON(response)["review"] as? [String: Any])?["iconURL"] as? String, icon)
        }
    }

    func testOversizedPopupResponseBecomesRejectOnlyErrorWithoutTruncation() throws {
        let bounded = try boundedResponse(oversizedResponse(), for: approvalStateRequest())
        XCTAssertEqual(bounded["id"] as? Int, 91)
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["host"] as? String, "wallet.example")
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["review"])
        XCTAssertNil(bounded["reviewToken"])
    }

    func testOversizedResponsePreservesExistingRecoveryCapability() throws {
        for action in [PopupApprovalState.RecoveryAction.retry, .reject] {
            let response = PopupResponse.command(.ok(.init(
                id: 91, host: "wallet.example",
                content: .error(message: String(repeating: "x", count: PopupResponseEncoder.maximumResponseBytes), actions: [action])
            )))
            let bounded = try boundedResponse(response, for: approvalStateRequest())
            XCTAssertEqual(bounded["state"] as? String, "error")
            XCTAssertEqual(bounded["host"] as? String, "wallet.example")
            XCTAssertEqual(bounded["actions"] as? [String], [action.rawValue])
            XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
            XCTAssertNil(bounded["review"])
        }
    }

    func testOversizedHostCannotOverflowErrorEnvelope() throws {
        guard case .command(.ok(var state)) = oversizedResponse() else { return XCTFail() }
        state.host = String(repeating: "h", count: PopupResponseEncoder.maximumResponseBytes)
        let bounded = try boundedResponse(.command(.ok(state)), for: approvalStateRequest())
        XCTAssertNil(bounded["host"])
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertNil(bounded["review"])
    }

    func testOversizedIgnoredCommandPreservesDispositionAndRecovery() throws {
        let state = try XCTUnwrap(oversizedResponse().approvalState)
        let request = try popupRequest(subject: .approveRequest, payload: [:])
        let data = try PopupResponseEncoder.encode(.command(.ignored(state)), for: request)
        XCTAssertLessThanOrEqual(data.count, PopupResponseEncoder.maximumResponseBytes)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(reply.keys), ["status", "approval"])
        XCTAssertEqual(reply["status"] as? String, "ignored")
        let approval = try XCTUnwrap(reply["approval"] as? [String: Any])
        XCTAssertEqual(approval["state"] as? String, "error")
        XCTAssertEqual(approval["actions"] as? [String], ["reject"])
        XCTAssertNil(approval["review"])
    }

    func testOversizedMutationResponsesUseApprovalErrorEnvelope() throws {
        let requests = try [
            popupRequest(subject: .retryApproval),
            popupRequest(subject: .setTransactionSpeed, payload: ["interaction": "ended", "value": 0.5]),
            popupRequest(subject: .applyTransactionEdits, payload: ["mode": "suggested"]),
            popupRequest(subject: .resolveApprovalAlert, payload: ["action": "cancel"]),
        ]
        for request in requests {
            let bounded = try boundedResponse(oversizedResponse(), for: request)
            XCTAssertEqual(bounded["id"] as? Int, 91)
            XCTAssertEqual(bounded["state"] as? String, "error")
            XCTAssertEqual(bounded["host"] as? String, "wallet.example")
            XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
            XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
            XCTAssertNil(bounded["review"])
            XCTAssertNil(bounded["status"])
        }
    }

    func testOversizedQueueUsesUnavailableStatus() throws {
        let response = PopupResponse.queue(.init(
            requests: [], completedResponses: [],
            strings: ["ok": String(repeating: "x", count: PopupResponseEncoder.maximumResponseBytes)],
            layoutDirection: .ltr
        ))
        let bounded = try boundedResponse(response, for: popupRequest(subject: .getPendingRequests))
        XCTAssertEqual(bounded["status"] as? String, "unavailable")
        XCTAssertEqual(Set(bounded.keys), ["status"])
    }

    func testStatusOnlySliderMutationIsRejectedByExactDecoder() {
        XCTAssertThrowsError(try popupRequest(
            subject: .setTransactionSpeed,
            payload: ["interaction": "moved", "value": 0.5, "responseMode": "status"]
        ))
    }

    func testReviewTokenIsLowercaseAndAbsentOptionalsAreOmitted() throws {
        let token = try XCTUnwrap(UUID(uuidString: "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF"))
        let response = PopupResponse.command(.ok(.init(
            id: 91,
            host: "wallet.example",
            content: .review(.init(
                reviewToken: token,
                title: "Add Network",
                content: .addChain(.init(chainName: "Custom", rpcURL: "https://rpc.example"))
            ), actions: [.approve, .reject], feedback: nil)
        )))
        let json = popupApprovalJSON(response)
        let review = try XCTUnwrap(json["review"] as? [String: Any])
        XCTAssertEqual(review["reviewToken"] as? String, token.uuidString.lowercased())
        XCTAssertNil(review["iconURL"])
        XCTAssertNil(json["error"])
        XCTAssertNil(json["editsError"])
    }

    private func transactionReview(position: Double = 100, type2: Bool = false) -> PopupTransactionReview {
        .init(
            account: .init(name: "Primary", croppedAddress: "0x1111…1111"),
            networkName: "Ethereum",
            balance: type2 ? nil : "1 ETH",
            valueLine: type2 ? nil : "0.1 ETH",
            feeLines: ["Fee: 0.001 ETH"],
            dataInterpretation: type2 ? nil : "Transfer",
            phase: type2 ? .reviewingFees : .ready,
            slider: .init(visible: true, position: position, maximum: 200),
            editor: .init(nonce: "2", fee: type2
                ? .eip1559(maxPriorityFeePerGasGwei: "1", maxFeePerGasGwei: "20")
                : .legacy(gasPriceGwei: "10"), suggestedFee: type2
                ? .eip1559(maxPriorityFeePerGasGwei: "2", maxFeePerGasGwei: "22")
                : .legacy(gasPriceGwei: "11")),
            alert: type2 ? .init(title: "Fees updated", message: "Review the fees", actions: [
                .init(title: "OK", action: .acknowledge), .init(title: "Edit", action: .edit),
            ]) : nil,
            editorRequestToken: type2 ? 1 : nil
        )
    }

    func testTypedResponsesMatchSharedPopupContract() throws {
        let revisions = try XCTUnwrap(ExtensionBridge.ProviderRevisions(rawValue: ["ethereum": 2, "solana": 3]))
        let responses: [String: PopupResponse] = [
            "queue": .queue(.init(
                requests: [.init(
                    id: 91, host: "wallet.example", receivedAt: 1_700_000_000.25, sequence: 1,
                    requestToken: "00000000-0000-4000-8000-000000000091",
                    enqueueAttempt: String(repeating: "01", count: 16),
                    configurationKey: "https://wallet.example", provider: .ethereum, revisions: revisions
                )],
                completedResponses: [.init(
                    id: 92, host: "wallet.example", configurationKey: "https://wallet.example",
                    requestToken: reviewToken, revisions: revisions
                )], strings: ["ok": "OK"], layoutDirection: .ltr
            )),
            "missing": .command(.ok(.init(id: 91, content: .missing))),
            "working": .command(.ok(.init(id: 91, host: "wallet.example", content: .working))),
            "authenticating": .command(.ok(.init(id: 91, host: "wallet.example", content: .authenticating))),
            "retryError": .command(.ok(.init(id: 91, host: "wallet.example", content: .error(message: "Failed to load", actions: [.retry])))),
            "rejectError": .command(.ok(.init(id: 91, content: .error(message: "Review unavailable", actions: [.reject])))),
            "selectAccount": reviewResponse(.selectAccount(.init(
                accounts: [.init(
                    display: .init(name: "Primary", croppedAddress: "0x1111…1111"),
                    walletId: "wallet-1", address: "0x" + String(repeating: "1", count: 40), coin: .ethereum,
                    derivationPath: "m/44'/60'/0'/0/0", isSelected: true
                )],
                networks: [.init(chainId: "0x1", name: "Ethereum", isCustom: false, isSelected: true)],
                canSelectNetwork: true, allowsEmptySelection: false, emptyMessage: nil, primaryTitle: "Connect"
            )), title: "Connect Wallet"),
            "switchAccount": reviewResponse(.switchAccount(.init(
                accounts: [], networks: nil, canSelectNetwork: false,
                allowsEmptySelection: true, emptyMessage: "No accounts", primaryTitle: nil
            )), title: "Switch Account"),
            "signMessage": reviewResponse(.signMessage(.init(
                meta: "Hello", account: .init(name: "Primary", croppedAddress: "0x1111…1111", icon: "data:image/png;base64,AA=="),
                clusterSelection: nil
            )), title: "Sign Message", iconURL: "https://wallet.example/icon.png"),
            "solanaSignMessage": reviewResponse(.signMessage(.init(
                meta: "Transaction", account: .init(name: "Solana", croppedAddress: "1111…1111"),
                clusterSelection: .init(clusters: [
                    .init(value: .mainnetBeta, label: "Mainnet", isSelected: false),
                    .init(value: .devnet, label: "Devnet", isSelected: false),
                    .init(value: .testnet, label: "Testnet", isSelected: false),
                ], requiresSelection: true)
            )), title: "Sign Message"),
            "addChain": reviewResponse(.addChain(.init(chainName: "Custom", rpcURL: "https://rpc.example")), title: "Add Network"),
            "legacyTransaction": reviewResponse(.sendTransaction(transactionReview()), title: "Send Transaction",
                                                actions: [.approve, .reject, .editTransaction, .setTransactionSpeed]),
            "type2Transaction": reviewResponse(.sendTransaction(transactionReview(type2: true)), title: "Send Transaction",
                                               actions: [.reject, .resolveApprovalAlert]),
            "ok": .command(.ok(.init(id: 91, content: .missing))),
            "ignored": .command(.ignored(nil)), "unavailable": .command(.unavailable),
        ]
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Safari Shared/Tests/fixtures/popup_contract.json")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(responses.keys), Set(expected.keys))
        for (name, response) in responses {
            let encoded = try JSONEncoder().encode(response)
            let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            XCTAssertEqual(actual, expected[name] as? NSDictionary, name)
        }
    }
}

func popupResponseJSON(_ response: PopupResponse) -> [String: Any] {
    do {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
    } catch {
        XCTFail("Failed to encode popup response: \(error)")
        return [:]
    }
}

private func popupApprovalJSON(_ response: PopupResponse) -> [String: Any] {
    let reply = popupResponseJSON(response)
    XCTAssertEqual(Set(reply.keys), ["status", "approval"])
    XCTAssertEqual(reply["status"] as? String, "ok")
    guard let approval = reply["approval"] as? [String: Any] else {
        XCTFail("Expected approval state")
        return [:]
    }
    return approval
}

private func popupApprovalJSON(_ state: PopupApprovalState) -> [String: Any] {
    do {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    } catch {
        XCTFail("Failed to encode popup approval state: \(error)")
        return [:]
    }
}

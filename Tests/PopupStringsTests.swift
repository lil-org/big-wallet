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

    private func oversizedResponse(
        state: String,
        actions: [String]? = nil,
        reviewToken: String? = "00000000-0000-4000-8000-000000000092"
    ) -> [String: Any] {
        var response: [String: Any] = [
            "id": 91,
            "state": state,
            "actions": actions ?? (state == "review" ? ["approve", "reject"] : []),
            "host": "wallet.example",
        ]
        let largeText = String(
            repeating: "x",
            count: PopupApprovalStatePresenter.maximumResponseBytes
        )
        if state == "review" {
            var review: [String: Any] = ["kind": "signMessage", "meta": largeText]
            review["reviewToken"] = reviewToken
            response["review"] = review
        } else {
            response["error"] = largeText
        }
        return response
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
            "Big Wallet requests are unavailable in Private Browsing.",
            "Open Big Wallet once to enable secure Safari approvals.",
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
        let error = PopupApprovalStatePresenter.errorState(
            id: 91,
            host: "wallet.example",
            error: Strings.failedToLoad
        )

        XCTAssertEqual(Set(error.keys), ["id", "state", "actions", "host", "error"])
        XCTAssertEqual(error["state"] as? String, "error")
        XCTAssertEqual(error["error"] as? String, Strings.failedToLoad)
        XCTAssertNil(error["review"])
        XCTAssertEqual(error["actions"] as? [String], ["retry"])
    }

    @MainActor
    func testSecureSetupRequiredStateIsDistinctAndRefreshOnly() {
        let state = PopupApprovalStatePresenter()
            .secureSetupRequiredState(id: 91, host: "wallet.example")

        XCTAssertEqual(
            Set(state.keys),
            ["id", "state", "actions", "host", "error"]
        )
        XCTAssertEqual(state["state"] as? String, "error")
        XCTAssertEqual(
            state["error"] as? String,
            Strings.secureApprovalSetupRequired
        )
        XCTAssertEqual(state["actions"] as? [String], ["retry"])
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
            purpose: .approval(action)
        )
        let presenter = PopupApprovalStatePresenter()
        let review = presenter.approvalState(
            for: session,
            action: action,
            transactionMutationAllowed: false
        )
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
            let busy = presenter.approvalState(
                for: session,
                action: action,
                transactionMutationAllowed: true
            )
            XCTAssertEqual(busy["state"] as? String, expectedState)
            XCTAssertEqual(busy["actions"] as? [String], [])
            XCTAssertNil(busy["review"])
            XCTAssertEqual(Set(busy.keys), ["id", "state", "actions", "host"])
        }
    }

    func testRejectableErrorHasExactRejectOnlyEnvelope() {
        let error = PopupApprovalStatePresenter.errorState(
            id: 91,
            actions: [.reject],
            host: "wallet.example",
            error: Strings.failedToLoad
        )

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

    @MainActor
    func testMoreThan256AccountAndNetworkChoicesRemainExactWhenTheyFit() throws {
        let choiceCount = 300
        let accounts = (0..<choiceCount).map { index in
            return [
                "walletId": "00000000-0000-4000-8000-000000000000-\(index)",
                "address": "0x" + String(format: "%040x", index),
                "coin": "ethereum",
                "name": "Account \(index)",
                "croppedAddress": "0000...0000",
                "isSelected": false,
            ] as [String: Any]
        }
        let networks = (0..<choiceCount).map { index in
            return [
                "chainId": "0x" + String(index + 1, radix: 16),
                "name": "Network \(index)",
                "isCustom": true,
                "isSelected": index == choiceCount - 1,
            ] as [String: Any]
        }
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "host": "wallet.example",
            "actions": ["approve", "reject"],
            "review": [
                "kind": "selectAccount",
                "reviewToken": reviewToken,
                "accounts": accounts,
                "networks": networks,
            ],
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(((bounded["review"] as? [String: Any])?["accounts"] as? [[String: Any]])?.count, choiceCount)
        XCTAssertEqual(((bounded["review"] as? [String: Any])?["networks"] as? [[String: Any]])?.count, choiceCount)
        XCTAssertEqual(
            ((bounded["review"] as? [String: Any])?["accounts"] as? [[String: Any]])?.last?["name"] as? String,
            "Account 299"
        )
        XCTAssertEqual(
            ((bounded["review"] as? [String: Any])?["networks"] as? [[String: Any]])?.last?["name"] as? String,
            "Network 299"
        )
        XCTAssertLessThanOrEqual(
            try JSONSerialization.data(withJSONObject: bounded).count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testControlHeavySelectionBecomesAtomicFallbackWithoutShorteningLabels() throws {
        let displayName = String(repeating: "\u{0000}", count: 256)
        let accounts = (0..<256).map { index in
            return [
                "walletId": "00000000-0000-4000-8000-000000000000-\(index)",
                "address": "0x" + String(format: "%040x", index),
                "coin": "ethereum",
                "name": displayName,
                "croppedAddress": "0000...0000",
                "isSelected": false,
            ] as [String: Any]
        }
        let networks = (0..<256).map { index in
            return [
                "chainId": "0x" + String(index + 1, radix: 16),
                "name": displayName,
                "isCustom": true,
                "isSelected": false,
            ] as [String: Any]
        }
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "host": "wallet.example",
            "actions": ["approve", "reject"],
            "review": [
                "kind": "selectAccount",
                "reviewToken": reviewToken,
                "accounts": accounts,
                "networks": networks,
            ],
        ]

        XCTAssertEqual(((response["review"] as? [String: Any])?["accounts"] as? [[String: Any]])?.first?["name"] as? String, displayName)
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["review"])
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertNil((bounded["review"] as? [String: Any])?["kind"])
        XCTAssertNil((bounded["review"] as? [String: Any])?["accounts"])
        XCTAssertNil((bounded["review"] as? [String: Any])?["networks"])
        XCTAssertLessThanOrEqual(
            try JSONSerialization.data(withJSONObject: bounded).count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testOversizedSelectionReturnsAtomicRejectOnlyFallback() throws {
        let accounts = (0..<4_000).map { index in
            return [
                "walletId": "00000000-0000-4000-8000-000000000000-\(index)",
                "address": "0x" + String(format: "%040x", index),
                "coin": "ethereum",
                "name": "Account \(index)",
                "croppedAddress": "0000...0000",
                "isSelected": false,
            ] as [String: Any]
        }
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "host": "wallet.example",
            "actions": ["approve", "reject"],
            "review": [
                "kind": "selectAccount",
                "reviewToken": reviewToken,
                "accounts": accounts,
                "networks": [[String: Any]](),
            ],
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil(bounded["review"])
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertNil((bounded["review"] as? [String: Any])?["kind"])
        XCTAssertNil((bounded["review"] as? [String: Any])?["accounts"])
        XCTAssertNil((bounded["review"] as? [String: Any])?["networks"])
    }

    @MainActor
    func testInvalidSelectionJSONUsesGenericFallback() throws {
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "host": "wallet.example",
            "actions": ["approve", "reject"],
            "review": [
                "kind": "selectAccount",
                "accounts": [["invalid": Date()]],
            ],
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
    }

    @MainActor
    func testLongAddChainNameRemainsExactWhenResponseFits() throws {
        let chainName = String(repeating: "Network ", count: 100) + "exact suffix"
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "host": "wallet.example",
            "actions": ["approve", "reject"],
            "review": [
                "kind": "addChain",
                "chainName": chainName,
                "rpcURL": "https://rpc.example",
            ],
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertEqual((bounded["review"] as? [String: Any])?["chainName"] as? String, chainName)
        XCTAssertEqual((bounded["review"] as? [String: Any])?["kind"] as? String, "addChain")
    }

    @MainActor
    func testPopupResponseDropsDecorativeImagesBeforeFailingClosed() throws {
        let icon = "data:image/png;base64," + String(
            repeating: "A",
            count: PopupApprovalStatePresenter.maximumResponseBytes
        )
        let response: [String: Any] = [
            "id": 91,
            "state": "review",
            "host": "wallet.example",
            "actions": ["approve", "reject"],
            "review": [
                "kind": "selectAccount",
                "iconURL": icon,
                "accounts": [[
                    "name": "Account",
                    "croppedAddress": "0000...0000",
                    "icon": icon,
                ]],
            ],
        ]

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )
        let accounts = try XCTUnwrap((bounded["review"] as? [String: Any])?["accounts"] as? [[String: Any]])

        XCTAssertNil((bounded["review"] as? [String: Any])?["iconURL"])
        XCTAssertNil(accounts.first?["icon"])
        XCTAssertEqual((bounded["review"] as? [String: Any])?["kind"] as? String, "selectAccount")
        let data = try JSONSerialization.data(withJSONObject: bounded)
        XCTAssertLessThanOrEqual(
            data.count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testOversizedPopupResponseBecomesRejectOnlyErrorWithoutTruncation() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "review"),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["id"] as? Int, 91)
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["host"] as? String, "wallet.example")
        XCTAssertNil(bounded["review"])
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertNil((bounded["review"] as? [String: Any])?["meta"])
    }

    @MainActor
    func testOversizedNonReviewResponseBecomesNonRejectableError() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "authenticating"),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["id"] as? Int, 91)
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertEqual(bounded["host"] as? String, "wallet.example")
        XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
        XCTAssertEqual(bounded["actions"] as? [String], ["retry"])
        XCTAssertNil(bounded["review"])
        XCTAssertNil((bounded["review"] as? [String: Any])?["meta"])
    }

    @MainActor
    func testOversizedResponsePreservesExistingRejectionCapability() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "error", actions: ["reject"]),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertNil(bounded["review"])
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
    }

    @MainActor
    func testOversizedHostCannotOverflowErrorEnvelope() throws {
        var response = oversizedResponse(state: "review")
        response["host"] = String(
            repeating: "h",
            count: PopupApprovalStatePresenter.maximumResponseBytes
        )

        let bounded = PopupApprovalStatePresenter.boundedResponse(
            response,
            for: try approvalStateRequest()
        )

        XCTAssertNil(bounded["host"])
        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertNil(bounded["review"])
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
        let data = try JSONSerialization.data(withJSONObject: bounded)
        XCTAssertLessThanOrEqual(
            data.count,
            PopupApprovalStatePresenter.maximumResponseBytes
        )
    }

    @MainActor
    func testOversizedMutationResponsesUseApprovalErrorEnvelope() throws {
        let requests = try [
            popupRequest(subject: .retryApproval),
            popupRequest(
                subject: .setTransactionSpeed,
                payload: ["interaction": "ended", "value": 0.5]
            ),
            popupRequest(
                subject: .applyTransactionEdits,
                payload: ["mode": "suggested"]
            ),
            popupRequest(
                subject: .resolveApprovalAlert,
                payload: ["action": "cancel"]
            ),
        ]

        for request in requests {
            let bounded = PopupApprovalStatePresenter.boundedResponse(
                oversizedResponse(state: "review"),
                for: request
            )
            XCTAssertEqual(bounded["id"] as? Int, 91)
            XCTAssertEqual(bounded["state"] as? String, "error")
            XCTAssertEqual(bounded["host"] as? String, "wallet.example")
            XCTAssertNil(bounded["review"])
            XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
            XCTAssertEqual(bounded["error"] as? String, Strings.somethingWentWrong)
            XCTAssertNil(bounded["status"])
            XCTAssertNil((bounded["review"] as? [String: Any])?["meta"])
        }
    }

    @MainActor
    func testStatusOnlySliderMutationIsRejectedByExactDecoder() {
        XCTAssertThrowsError(try popupRequest(
            subject: .setTransactionSpeed,
            payload: [
                "interaction": "moved",
                "value": 0.5,
                "responseMode": "status",
            ]
        ))
    }

    @MainActor
    func testOversizedReviewWithoutAuthoritativeTokenRemainsRejectable() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(state: "review", reviewToken: nil),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertNil(bounded["review"])
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
    }

    @MainActor
    func testOversizedReviewDoesNotExposeAuthoritativeToken() throws {
        let bounded = PopupApprovalStatePresenter.boundedResponse(
            oversizedResponse(
                state: "review",
                reviewToken: reviewToken.uppercased()
            ),
            for: try approvalStateRequest()
        )

        XCTAssertEqual(bounded["state"] as? String, "error")
        XCTAssertNil(bounded["review"])
        XCTAssertEqual(bounded["actions"] as? [String], ["reject"])
    }

}

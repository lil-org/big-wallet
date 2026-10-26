import Foundation
import Dispatch
import Synchronization
import XCTest
import WalletDomain
import WalletRuntimeTestSupport
@testable import WalletNetworking

final class SafariRPCRequestTests: XCTestCase {
    func testRejectsMalformedJSONAndNonSingleRequests() throws {
        for body in ["", "{", "not JSON"] {
            assertFailure(.invalidJSON, body: body)
        }
        for body in [
            "null", "[]", #"[{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber"}]"#,
            #"{"id":1,"method":"eth_blockNumber"}"#,
            #"{"jsonrpc":"1.0","id":1,"method":"eth_blockNumber"}"#,
            #"{"jsonrpc":"2.0","method":"eth_blockNumber"}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"eth_blockNumber"}"#,
            #"{"jsonrpc":"2.0","id":"1","method":"eth_blockNumber"}"#,
            #"{"jsonrpc":"2.0","id":1.1,"method":"eth_blockNumber"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":" "}"#,
        ] {
            assertFailure(.invalidRequest, body: body)
        }
    }

    func testBlocksPrivilegedAndProviderOwnedMethodsAfterNormalization() throws {
        let prohibited = [
            "admin_peers", "personal_unlockAccount", "miner_start", "engine_newPayloadV3",
            "hardhat_setBalance", "anvil_setCode", "evm_mine", "signer_confirmRequest", "eth_sign",
            "eth_signTransaction", "eth_signTypedData_v4", "eth_accounts", "eth_coinbase", "net_version",
            "eth_chainId", "eth_requestAccounts", "wallet_getPermissions", "wallet_requestPermissions",
            "wallet_revokePermissions", "wallet_switchEthereumChain", "wallet_addEthereumChain",
            "eth_sendTransaction", "eth_sendUnsignedTransaction", "eth_submitTransaction", "eth_newFilter",
            "eth_sendTransactionSync",
            "eth_newBlockFilter", "eth_newPendingTransactionFilter", "eth_uninstallFilter", "eth_subscribe",
            "eth_unsubscribe", "debug_setHead", "debug_startCPUProfile", "debug_stopCPUProfile",
            "debug_writeBlockProfile", "debug_standardTraceBlockToFile", "debug_traceBlockFromFile",
            "debug_backtraceAt", "debug_blockProfile", "debug_cpuProfile", "debug_mutexProfile",
            "debug_goTrace", "debug_freeOSMemory", "debug_freezeClient", "debug_chaindbCompact",
            "eth_resend", "parity_postTransaction", "debug_deleteChainSlice", "debug_resetHead",
            "debug_verbosity", "debug_vmodule",
            "debug_clearTxpool", "tenderly_setBalance", "tenderly_addBalance",
            "tenderly_setErc20Balance", "tenderly_addErc20Balance", "tenderly_setMaxErc20Balance",
            "tenderly_setStorageAt", "tenderly_setCode", "tenderly_setNextBlockTimestamp",
            "tenderly_startSync", "tenderly_stopSync", "tenderly_syncNext", "tenderly_revertSync",
            "debug_insertReceipts", "debug_migrateReceipts",
            "testing_commitBlockV1",
            "parity_postSign", "parity_signMessage", "parity_setMode",
            "parity_acceptNonReservedPeers", "parity_addReservedPeer", "parity_dropNonReservedPeers",
            "parity_executeUpgrade", "parity_removeReservedPeer", "parity_setAuthor", "parity_setChain",
            "parity_setEngineSigner", "parity_setExtraData", "parity_setGasCeilTarget", "parity_setGasFloorTarget",
            "parity_setMaxTransactionGas", "parity_setMinGasPrice", "parity_setTransactionsLimit",
            "parity_changePassword", "parity_deriveAddressHash", "parity_deriveAddressIndex", "parity_importGethAccounts",
            "parity_killAccount", "parity_newAccountFromPhrase", "parity_newAccountFromSecret", "parity_newAccountFromWallet",
            "parity_removeAddress", "parity_setAccountMeta", "parity_setAccountName", "parity_changeVault",
            "parity_changeVaultPassword", "parity_closeVault", "parity_newVault", "parity_openVault", "parity_setVaultMeta",
            "parity_hardwarePinMatrixAck", "parity_removeTransaction", "parity_exportAccount", "parity_testPassword",
            "parity_decryptMessage",
            "perm_addAccountsToAllowlist", "perm_removeAccountsFromAllowlist",
            "perm_addNodesToAllowlist", "perm_removeNodesFromAllowlist", "perm_reloadPermissionsFromFile",
            "qbft_proposeValidatorVote", "qbft_discardValidatorVote",
            "ibft_proposeValidatorVote", "ibft_discardValidatorVote", "clique_propose", "clique_discard",
        ]
        for method in prohibited {
            for variant in [method, " \n" + method.uppercased() + "\t"] {
                assertFailure(.prohibitedMethod, body: try body(method: variant))
            }
        }
    }

    func testPreservesPermissiveCallsAndOpaqueParameters() throws {
        let methods = [
            "eth_sendRawTransaction", "eth_sendRawTransactionSync", "eth_sendUserOperation",
            "vendor_futureMethod", "vendor_exportToFile", "debug_traceTransaction", "trace_call", "alchemy_simulateAssetChanges",
            "eth_getFilterChanges", "eth_getFilterLogs", "eth_getLogs", " Vendor_FutureMethod ",
            "parity_pendingTransactions", "debug_executionWitness", "debug_getRawBlock",
            "debug_getRawReceipts", "debug_getSyncStage",
            "testing_buildBlockV1",
            "parity_call", "parity_mode", "parity_verifySignature",
            "parity_hashContent", "parity_upgradeReady", "parity_netPeers", "parity_chain", "parity_setVendorExtension",
            "parity_composeTransaction", "parity_encryptMessage", "parity_listAccounts",
            "tenderly_getSyncStatus", "tenderly_simulateTransaction", "tenderly_simulateBundle", "tenderly_setVendorExtension",
            "perm_getAccountsAllowlist", "perm_getNodesAllowlist",
            "qbft_getPendingVotes", "qbft_getValidatorsByBlockNumber",
            "ibft_getPendingVotes", "ibft_getValidatorsByBlockNumber",
            "clique_proposals", "clique_getSigners", "clique_status",
        ]
        let parameters: [Any] = [NSNull(), true, 1.25, "opaque", ["latest"], ["nested": ["value": 4]]]
        for method in methods {
            for params in parameters {
                let input = try body(method: method, params: params)
                let request = try ValidatedRPCRequest(body: input, id: 1)
                XCTAssertEqual(request.method, method)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                XCTAssertEqual(try canonical(decoded["params"]!), try canonical(params))
            }
        }
        let request = try ValidatedRPCRequest(body: body(method: "vendor_method"), id: 1)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertNil(decoded["params"])
    }

    func testBadBlockFileOutputIsRejectedWithoutBlockingReadsOrVendorMethods() throws {
        let reads: [Any?] = [nil, NSNull(), [Any](), [NSNull()], ["file": NSNull()]]
        let writes: [Any] = [["/tmp/bad-blocks.json"], [""], ["file": "/tmp/bad-blocks.json"], ["file": ""]]
        for method in ["debug_getBadBlocks", " \nDEBUG_GETBADBLOCKS\t"] {
            for params in reads {
                let request = try ValidatedRPCRequest(body: body(method: method, params: params), id: 1)
                XCTAssertEqual(request.method, method)
                let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
                if let params {
                    XCTAssertEqual(try canonical(decoded["params"]!), try canonical(params))
                } else {
                    XCTAssertNil(decoded["params"])
                }
            }
            for params in writes {
                assertFailure(.prohibitedMethod, body: try body(method: method, params: params))
            }
        }
        for params in writes {
            XCTAssertNoThrow(try ValidatedRPCRequest(body: body(method: "vendor_getBadBlocks", params: params), id: 1))
        }
    }

    func testRebuildsSingleCanonicalEnvelopeAfterDuplicateKeys() throws {
        for input in [
            #"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","method":"eth_sendTransaction"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"eth_sendTransaction","method":"eth_blockNumber","unexpected":{"method":"personal_sign"}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","\u006dethod":"eth_sendTransaction"}"#,
        ] {
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            if parsed["method"] as? String == "eth_sendTransaction" {
                assertFailure(.prohibitedMethod, body: input)
            } else {
                let request = try ValidatedRPCRequest(body: input, id: 1)
                XCTAssertEqual(request.method, parsed["method"] as? String)
                XCTAssertEqual(String(decoding: request.body, as: UTF8.self), #"{"id":1,"jsonrpc":"2.0","method":"eth_blockNumber"}"#)
            }
        }
    }

    func testRequestLimitsCountUTF8AndApplyBeforeParsing() throws {
        let input = try body(method: "vendor_method", params: ["🪙"])
        let bytes = input.utf8.count
        XCTAssertGreaterThan(bytes, input.count)
        XCTAssertNoThrow(try ValidatedRPCRequest(body: input, id: 1, limits: .init(maximumRequestBytes: bytes)))
        XCTAssertThrowsError(try ValidatedRPCRequest(body: input, id: 1, limits: .init(maximumRequestBytes: bytes - 1))) {
            XCTAssertEqual($0 as? SafariRPCFailure, .requestTooLarge)
        }
        XCTAssertThrowsError(try ValidatedRPCRequest(body: String(repeating: "{", count: 16), id: 1,
                                                   limits: .init(maximumRequestBytes: 15))) {
            XCTAssertEqual($0 as? SafariRPCFailure, .requestTooLarge)
        }
    }

    func testPreparedEncodingCountsEscapedStringsAndPreservesUnicode() throws {
        let controls = String((0...31).compactMap(UnicodeScalar.init).map(Character.init))
        let value = controls + "\"/\\🪙é\u{301}\u{2028}\u{2029}"
        let params: [String: Any] = [value: [value, true, false, NSNull(), ["nested": value]]]
        let input = try body(method: "vendor_🪙", params: params)
        let prepared = try ValidatedRPCRequest.prepare(body: input, id: 1)
        let request = try prepared.serialize()

        XCTAssertEqual(request.body.count, prepared.canonicalByteCount)
        XCTAssertEqual(try prepared.serialize().body, request.body)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(decoded["method"] as? String, "vendor_🪙")
        XCTAssertEqual(try canonical(decoded["params"]!), try canonical(params))
    }

    func testComplexityLimitCountsValuesAndKeysWithoutCountingStringContents() throws {
        let input = try body(method: "vendor_method", params: ["key": "\"\\[]{}:, 🪙", "value": -1.25e30])
        XCTAssertNoThrow(try ValidatedRPCRequest(body: input, id: 1, limits: .init(maximumRequestTokens: 13)))
        XCTAssertThrowsError(try ValidatedRPCRequest(body: input, id: 1, limits: .init(maximumRequestTokens: 12))) {
            XCTAssertEqual($0 as? SafariRPCFailure, .requestTooLarge)
        }
    }

    func testComplexityLimitRejectsWideContainersAndNumbersBeforeParsing() {
        for element in ["[]", "0.5"] {
            let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"vendor_method\",\"params\":[" +
                String(repeating: element + ",", count: 65_536)
            XCTAssertLessThan(input.utf8.count, SafariRPCLimits.live.maximumRequestBytes)
            assertFailure(.requestTooLarge, body: input)
        }
        let discarded = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","ignored":[[],[],[],[]]}"#
        let duplicate = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","extra":0,"extra":0,"extra":0}"#
        for input in [discarded, duplicate] {
            XCTAssertThrowsError(try ValidatedRPCRequest(body: input, id: 1, limits: .init(maximumRequestTokens: 10))) {
                XCTAssertEqual($0 as? SafariRPCFailure, .requestTooLarge)
            }
        }
    }

    func testPreflightChecksCancellationWithinLongStrings() throws {
        let input = try body(method: "vendor_method", params: String(repeating: "x", count: 20_000))
        let checks = Mutex(0)
        XCTAssertThrowsError(try ValidatedRPCRequest.prepare(body: input, id: 1) {
            try checks.withLock { count in
                count += 1
                if count == 2 { throw CancellationError() }
            }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks.withLock { $0 }, 2)
    }

    func testCountingAndSerializationCheckCancellationDuringTraversal() {
        let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"vendor_method\",\"params\":[" +
            String(repeating: "0,", count: 9_999) + "0]}"
        for cancelDuringSerialization in [false, true] {
            let state = Mutex((enabled: !cancelDuringSerialization, checks: 0))
            XCTAssertThrowsError(try {
                let prepared = try ValidatedRPCRequest.prepare(body: input, id: 1) {
                    try state.withLock { state in
                        guard state.enabled else { return }
                        state.checks += 1
                        if state.checks == 16 { throw CancellationError() }
                    }
                }
                if cancelDuringSerialization {
                    state.withLock { $0.enabled = true }
                    _ = try prepared.serialize()
                }
            }()) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(state.withLock { $0.checks }, 16)
        }
    }

    func testPreparedEncodingPreservesIntegerDecimalAndFloatingPointValues() throws {
        let input = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","params":[-9223372036854775808,18446744073709551615,1.2345678901234567890123456789012345678,1e-128,1.7976931348623157e308,-0.0,1e20,0.5,5e-324,-1e-128,1e-7,0.0000000000000000000000000000000000001]}"#
        let prepared = try ValidatedRPCRequest.prepare(body: input, id: 1)
        let request = try prepared.serialize()
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])

        XCTAssertEqual(request.body.count, prepared.canonicalByteCount)
        let values = try XCTUnwrap(decoded["params"] as? [NSNumber])
        XCTAssertEqual(values[5].doubleValue.sign, .minus)
        XCTAssertEqual(
            String(decoding: try canonical(decoded["params"]!), as: UTF8.self),
            String(decoding: try canonical(original["params"]!), as: UTF8.self)
        )
    }

    func testPreparationRejectsCanonicalExpansionBeforeCreatingOutput() throws {
        let input = #"{"jsonrpc":"2.0","id":1,"method":"vendor_method","params":["////////"]}"#
        let prepared = try ValidatedRPCRequest.prepare(body: input, id: 1)
        XCTAssertGreaterThan(prepared.canonicalByteCount, input.utf8.count)
        XCTAssertThrowsError(try ValidatedRPCRequest.prepare(
            body: input, id: 1, limits: .init(maximumRequestBytes: prepared.canonicalByteCount - 1)
        )) {
            XCTAssertEqual($0 as? SafariRPCFailure, .requestTooLarge)
        }
        let exact = try ValidatedRPCRequest.prepare(
            body: input, id: 1, limits: .init(maximumRequestBytes: prepared.canonicalByteCount)
        )
        XCTAssertEqual(try exact.serialize().body.count, prepared.canonicalByteCount)
    }

    func testOpaqueParametersStillRespectWireDepth() {
        let boundary = String(repeating: "[", count: WireProtocol.maximumJSONDepth - 1) + "0" +
            String(repeating: "]", count: WireProtocol.maximumJSONDepth - 1)
        XCTAssertNoThrow(try ValidatedRPCRequest(
            body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":" + boundary + "}", id: 1
        ))
        let nested = String(repeating: "[", count: WireProtocol.maximumJSONDepth + 1) + "0" +
            String(repeating: "]", count: WireProtocol.maximumJSONDepth + 1)
        assertFailure(.invalidRequest, body: "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_call\",\"params\":" + nested + "}")
    }

    func testOnlyKnownExactlyNamedReadMethodsAllowReplay() throws {
        for method in ["eth_blockNumber", "eth_estimateUserOperationGas", "eth_getLogs", "debug_traceTransaction", "alchemy_getAssetTransfers"] {
            XCTAssertTrue(try ValidatedRPCRequest(body: body(method: method), id: 1).allowsUnauthorizedReplay, method)
        }
        for method in [
            "eth_sendRawTransaction", "eth_sendRawTransactionSync", "eth_sendUserOperation", "vendor_getSomething", "ETH_GETLOGS", " eth_call ",
            "eth_getVendorMutation", "alchemy_getUnknown", "alchemy_simulateUnknown", "debug_traceUnknown", "trace_unknown",
        ] {
            XCTAssertFalse(try ValidatedRPCRequest(body: body(method: method), id: 1).allowsUnauthorizedReplay, method)
        }
    }

    func testResponseBudgetDoesNotOvercommitOrReleaseTwice() throws {
        let budget = SafariRPCResponseBudget(maximumBytes: 10)
        let first = budget.acquire()
        let second = budget.acquire()
        try first.reserve(6)
        XCTAssertThrowsError(try second.reserve(8)) { XCTAssertEqual($0 as? SafariRPCFailure, .busy) }
        try second.reserve(4)
        XCTAssertEqual(budget.bufferedBytes, 10)
        XCTAssertThrowsError(try first.reserve(1)) { XCTAssertEqual($0 as? SafariRPCFailure, .busy) }
        first.release()
        first.release()
        XCTAssertEqual(budget.bufferedBytes, 4)
        XCTAssertThrowsError(try first.reserve(1)) { XCTAssertEqual($0 as? SafariRPCFailure, .busy) }
        try second.reserve(6)
        second.release()
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testResponseLeaseReleasesOnDeinitialization() throws {
        let budget = SafariRPCResponseBudget(maximumBytes: 4)
        var lease: SafariRPCResponseBudget.Lease? = budget.acquire()
        try lease?.reserve(4)
        XCTAssertEqual(budget.bufferedBytes, 4)
        lease = nil
        XCTAssertEqual(budget.bufferedBytes, 0)
    }

    func testExecutionCannotDispatchAfterDeadline() throws {
        let instant = ContinuousClock.now
        let execution = SafariRPCExecution(deadline: instant, now: { instant },
                                           responseBudget: SafariRPCResponseBudget(maximumBytes: 1))
        XCTAssertThrowsError(try execution.markDispatched()) { XCTAssertEqual($0 as? SafariRPCFailure, .timeout) }
        XCTAssertFalse(execution.dispatched)
        let response = SafariRPCFailure.timeout.response(id: 5, dispatched: false).json
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32_603)
        XCTAssertEqual((error["data"] as? [String: Any])?["dispatched"] as? Bool, false)
    }

    func testCancellationBlocksUndispatchedWorkAndPreservesPriorDispatch() throws {
        let before = SafariRPCExecution(deadline: .now.advanced(by: .seconds(10)),
                                        responseBudget: SafariRPCResponseBudget(maximumBytes: 1))
        before.cancel()
        XCTAssertThrowsError(try before.markDispatched()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try before.checkCancellationAndDeadline()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(before.dispatched)
        let after = SafariRPCExecution(deadline: .now.advanced(by: .seconds(10)),
                                       responseBudget: SafariRPCResponseBudget(maximumBytes: 1))
        try after.markDispatched()
        after.cancel()
        XCTAssertTrue(after.dispatched)
        XCTAssertThrowsError(try after.markDispatched()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testConcurrentCancellationNeverReportsFalseForAnAdmittedDispatch() {
        for _ in 0..<200 {
            let execution = SafariRPCExecution(deadline: .now.advanced(by: .seconds(10)),
                                               responseBudget: SafariRPCResponseBudget(maximumBytes: 1))
            let outcomes = Mutex((dispatchSucceeded: false, reportedDispatched: false))
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    do {
                        try execution.markDispatched()
                        outcomes.withLock { $0.dispatchSucceeded = true }
                    } catch {}
                } else {
                    execution.cancel()
                    let dispatched = execution.dispatched
                    outcomes.withLock { $0.reportedDispatched = dispatched }
                }
            }
            let result = outcomes.withLock { $0 }
            XCTAssertFalse(result.dispatchSucceeded && !result.reportedDispatched)
        }
    }

    private func body(method: String, params: Any? = nil) throws -> String {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        object["params"] = params
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    private func assertFailure(_ failure: SafariRPCFailure, body: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ValidatedRPCRequest(body: body, id: 1), body, file: file, line: line) {
            XCTAssertEqual($0 as? SafariRPCFailure, failure, body, file: file, line: line)
        }
    }
}

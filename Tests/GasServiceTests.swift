// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

final class GasServiceTests: XCTestCase {

    private let rpcURL = "https://rpc.example"
    private let fetchedInfo = GasService.Info(standard: 200, slow: 150, fast: 250, rapid: 300)

    func testFetchEstimateRequestsExpectedHistoryAndUsesUpperMedianWithNextBaseFee() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0xffff", "0x1", "0x2", "0x3", "0x64"],
            reward: [
                ["0x1", "0xa", "0x14", "0x1e"],
                ["0x4", "0xd", "0x17", "0x21"],
                ["0x2", "0xb", "0x15", "0x1f"],
                ["0x3", "0xc", "0x16", "0x20"]
            ]
        )
        let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertEqual(rpc.feeHistoryCalls.count, 1)
        XCTAssertEqual(rpc.feeHistoryCalls.first?.rpcURL, rpcURL)
        XCTAssertEqual(rpc.feeHistoryCalls.first?.blockCount, 10)
        XCTAssertEqual(rpc.feeHistoryCalls.first?.rewardPercentiles, [10, 25, 50, 75])
        XCTAssertEqual(estimate.nextBaseFee, 100)
        XCTAssertEqual(estimate.info, GasService.Info(standard: 112, slow: 103, fast: 122, rapid: 132))
        XCTAssertEqual(estimate.info?.sliderValues, [103, 112, 122, 132])
    }

    func testFeeHistoryRejectsAnyInvalidRowAndRetainsNextBaseFee() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0x1", "0x2", "0x3", "0x64"],
            reward: [
                ["0x1", "0x2", "0x3", "0x4"],
                ["0x1", "not-hex", "0x3", "0x4"],
                ["0x5", "0x6", "0x7", "0x8"]
            ]
        )
        let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertNil(estimate.info)
        XCTAssertEqual(estimate.nextBaseFee, 100)
    }

    func testFeeHistoryUsesFallbackMetadataWhenPercentileTotalsCollide() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0x1", "0x65"],
            reward: [["0x0", "0x0", "0x0", "0x0"]]
        )
        let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertNil(estimate.info)
        XCTAssertEqual(estimate.nextBaseFee, 101)
    }

    func testInvalidFeeHistoriesRetainParseableBaseWithoutFetchingGasPrice() {
        let maximum = String.hex(UInt.max, withPrefix: true)
        let histories: [(String, EthereumFeeHistory)] = [
            (
                "malformed row",
                EthereumFeeHistory(baseFeePerGas: ["0x1", "0x64"], reward: [["0x1", "0x2", "0x3"]])
            ),
            (
                "descending row",
                EthereumFeeHistory(baseFeePerGas: ["0x1", "0x64"], reward: [["0x1", "0x3", "0x2", "0x4"]])
            ),
            (
                "invalid hex",
                EthereumFeeHistory(baseFeePerGas: ["0x1", "0x64"], reward: [["0x1", "invalid", "0x3", "0x4"]])
            ),
            (
                "missing rewards",
                EthereumFeeHistory(baseFeePerGas: ["0x64"], reward: nil)
            ),
            (
                "addition overflow",
                EthereumFeeHistory(baseFeePerGas: ["0x1", maximum], reward: [["0x1", "0x2", "0x3", "0x4"]])
            )
        ]

        for (name, history) in histories {
            let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

            let estimate = fetchEstimate(using: GasService(rpc: rpc), description: name)

            XCTAssertNil(estimate.info, name)
            XCTAssertEqual(estimate.nextBaseFee, UInt(hexString: history.baseFeePerGas.last ?? ""), name)
            XCTAssertEqual(rpc.feeHistoryCalls.count, 1, name)
        }
    }

    func testInvalidNextBaseFeeReturnsEmptyEstimate() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0x1", "invalid"],
            reward: [["0x1", "0x2", "0x3", "0x4"]]
        )
        let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertEqual(estimate, GasService.Estimate(info: nil, nextBaseFee: nil))
    }

    func testFeeHistoryErrorCompletesEmptyEstimateExactlyOnceOnMainQueue() {
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .failure(StubError.expected),
            feeHistoryCompletionCount: 2
        )
        let completed = expectation(description: "completed once")
        let overCompleted = expectation(description: "did not complete twice")
        overCompleted.isInverted = true
        var completionCount = 0

        GasService(rpc: rpc).fetchEstimate(rpcUrl: rpcURL) { estimate in
            completionCount += 1
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(estimate, GasService.Estimate(info: nil, nextBaseFee: nil))
            if completionCount == 1 {
                completed.fulfill()
            } else {
                overCompleted.fulfill()
            }
        }

        wait(for: [completed, overCompleted], timeout: 0.2)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(rpc.feeHistoryCalls.count, 1)
    }

    func testRelativeTiersUseExactPercentagesAndRoundingDirections() {
        XCTAssertEqual(GasService.Info.relative(to: 100)?.sliderValues, [85, 100, 120, 140])
        XCTAssertEqual(GasService.Info.relative(to: 101)?.sliderValues, [85, 101, 122, 142])
    }

    func testRelativeTiersRepairTinyAnchorCollisions() {
        XCTAssertEqual(GasService.Info.relative(to: 1)?.sliderValues, [1, 1, 2, 3])
        XCTAssertEqual(GasService.Info.relative(to: 2)?.sliderValues, [1, 2, 3, 4])
    }

    func testRelativeTiersClampSlowToKnownBaseFee() {
        XCTAssertEqual(
            GasService.Info.relative(to: 102, minimumGasPrice: 100)?.sliderValues,
            [100, 102, 123, 143]
        )
    }

    func testRelativeTiersRemainEnabledWhenBaseExceedsReference() {
        XCTAssertEqual(
            GasService.Info.relative(to: 80, minimumGasPrice: 100)?.sliderValues,
            [100, 100, 120, 140]
        )
    }

    func testRelativeTiersRejectZeroAndOverflow() {
        XCTAssertNil(GasService.Info.relative(to: 0))
        let nearMaximum = UInt.max - 2
        let expectedSlow = (nearMaximum / 100) * 85 + ((nearMaximum % 100) * 85) / 100
        XCTAssertEqual(GasService.Info.relative(to: nearMaximum)?.sliderValues,
                       [expectedSlow, nearMaximum, UInt.max - 1, UInt.max])
        XCTAssertNil(GasService.Info.relative(to: UInt.max - 1))
        XCTAssertNil(GasService.Info.relative(to: UInt.max))
    }

    func testGasSpeedConfigurationKeepsRPCInfoWhenItArrivesFirst() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertFalse(configuration.installTransactionFallback(gasPrice: 100))
        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertFalse(configuration.didUserSetGasPrice)
    }

    func testGasSpeedConfigurationReplacesTransactionFallbackBeforeInteraction() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(gasPrice: 100))
        XCTAssertEqual(configuration.info?.sliderValues, [85, 100, 120, 140])
        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertEqual(configuration.info, fetchedInfo)
    }

    func testGasSpeedConfigurationFreezesTierMappingWithoutCommittingGasPrice() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(gasPrice: 100))
        configuration.markGasSliderInteraction()

        XCTAssertFalse(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertFalse(configuration.installTransactionFallback(gasPrice: 200))
        XCTAssertEqual(configuration.info?.sliderValues, [85, 100, 120, 140])
        XCTAssertFalse(configuration.didUserSetGasPrice)
    }

    func testGasSpeedConfigurationReclampsRelativeFallbackBeforeInteraction() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(gasPrice: 100))
        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: nil, nextBaseFee: 90)))
        XCTAssertEqual(configuration.info?.sliderValues, [90, 100, 120, 140])
        XCTAssertFalse(configuration.didUserSetGasPrice)
    }

    func testManualGasCommitRecentersRelativeFallback() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(gasPrice: 100))
        configuration.commitManualGasPrice(140)

        XCTAssertEqual(configuration.info?.sliderValues, [119, 140, 168, 196])
        XCTAssertFalse(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertTrue(configuration.didUserSetGasPrice)
    }

    func testManualGasCommitPreservesLiveTiers() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        configuration.commitManualGasPrice(1_000)

        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertTrue(configuration.didUserSetGasPrice)
    }

    func testUnrepresentableManualGasCommitClearsRelativeFallback() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(gasPrice: 100))
        configuration.commitManualGasPrice(nil)

        XCTAssertNil(configuration.info)
        XCTAssertTrue(configuration.didUserSetGasPrice)
    }

    func testUnrepresentableManualGasCommitPreservesLiveTiers() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        configuration.commitManualGasPrice(nil)

        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertTrue(configuration.didUserSetGasPrice)
    }

    func testNonceOnlyEditLeavesFallbackEligibleForLiveReplacement() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(gasPrice: 100))
        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertFalse(configuration.didUserSetGasPrice)
    }

    func testGasSpeedConfigurationRejectsInvalidTransactionGasPrices() {
        var configuration = GasSpeedConfiguration()

        XCTAssertFalse(configuration.installTransactionFallback(gasPrice: 0))
        XCTAssertFalse(configuration.installTransactionFallback(gasPrice: UInt.max))
        XCTAssertNil(configuration.info)
    }

    func testGasSpeedConfigurationPreservesInteractedGasPriceWhileMergingPreparedFields() {
        let gasInfo = GasService.Info(standard: 100, slow: 85, fast: 120, rapid: 140)
        var stalePrepared = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        stalePrepared.gasPrice = String.hex(100)
        var current = stalePrepared
        current.setGasPrice(value: 100, inRelationTo: gasInfo)
        stalePrepared.nonce = "2"
        stalePrepared.gas = "5208"
        stalePrepared.interpretation = "prepared interpretation"
        stalePrepared.externalInterpretation = "prepared external interpretation"
        var configuration = GasSpeedConfiguration()
        configuration.markGasSliderInteraction()
        configuration.markGasSliderGasPriceChange()

        let merged = configuration.mergingPreparedTransaction(stalePrepared, with: current)

        XCTAssertEqual(stalePrepared.id, current.id, "The fixture must model a stale callback accepted by the ID guard")
        XCTAssertTrue(configuration.didUserSetGasPrice)
        XCTAssertEqual(merged.gasPrice, current.gasPrice)
        XCTAssertEqual(merged.nonce, stalePrepared.nonce)
        XCTAssertEqual(merged.gas, stalePrepared.gas)
        XCTAssertEqual(merged.interpretation, stalePrepared.interpretation)
        XCTAssertEqual(merged.externalInterpretation, stalePrepared.externalInterpretation)
        XCTAssertEqual(merged.id, stalePrepared.id)
    }

    func testGasSpeedConfigurationAcceptsPreparedGasPriceAfterUnmovedSliderInteraction() {
        var prepared = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        prepared.gasPrice = String.hex(140)
        var current = prepared
        current.gasPrice = String.hex(100)
        var configuration = GasSpeedConfiguration()
        configuration.markGasSliderInteraction()

        let merged = configuration.mergingPreparedTransaction(prepared, with: current)

        XCTAssertFalse(configuration.didUserSetGasPrice)
        XCTAssertEqual(merged.gasPrice, prepared.gasPrice)
        XCTAssertEqual(merged.id, prepared.id)
    }

    func testGasSpeedConfigurationAcceptsPreparedGasPriceBeforeInteraction() {
        var stalePrepared = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        stalePrepared.gasPrice = String.hex(100)
        stalePrepared.nonce = "2"
        stalePrepared.gas = "5208"
        var current = stalePrepared
        current.gasPrice = String.hex(140)
        let configuration = GasSpeedConfiguration()

        let merged = configuration.mergingPreparedTransaction(stalePrepared, with: current)

        XCTAssertFalse(configuration.didUserSetGasPrice)
        XCTAssertEqual(merged.gasPrice, stalePrepared.gasPrice)
        XCTAssertEqual(merged.nonce, stalePrepared.nonce)
        XCTAssertEqual(merged.gas, stalePrepared.gas)
        XCTAssertEqual(merged.id, stalePrepared.id)
    }

    func testGasSpeedConfigurationAcceptsPreparedGasPriceWhenInteractedCurrentPriceIsMissing() {
        var prepared = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        prepared.gasPrice = String.hex(100)
        var current = prepared
        current.gasPrice = nil
        var configuration = GasSpeedConfiguration()
        configuration.markGasSliderInteraction()
        configuration.markGasSliderGasPriceChange()

        let merged = configuration.mergingPreparedTransaction(prepared, with: current)

        XCTAssertEqual(merged.gasPrice, prepared.gasPrice)
        XCTAssertEqual(merged.id, prepared.id)
    }

    func testStandardFallbackTickIsOneThirdAlongSlider() throws {
        let info = try XCTUnwrap(GasService.Info.relative(to: 100))
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = String.hex(100)

        XCTAssertEqual(transaction.currentGasInRelationTo(info: info), 100.0 / 3.0, accuracy: 0.000_001)
    }

    func testGasSliderHandlesClampedDuplicateSlowAndStandardTiers() throws {
        let info = try XCTUnwrap(GasService.Info.relative(to: 80, minimumGasPrice: 100))
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = String.hex(100)

        XCTAssertEqual(transaction.currentGasInRelationTo(info: info), 0)

        transaction.setGasPrice(value: 100.0 / 6.0, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceWei, 100)

        transaction.setGasPrice(value: 50, inRelationTo: info)
        let increasedPrice = try XCTUnwrap(transaction.gasPriceWei)
        XCTAssertGreaterThan(increasedPrice, 100)
        XCTAssertLessThan(increasedPrice, 120)
    }

    func testGasSliderInterpolationHandlesUIntBoundaryTiers() throws {
        let info = GasService.Info(
            standard: UInt.max - 2,
            slow: 1,
            fast: UInt.max - 1,
            rapid: UInt.max
        )
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")

        transaction.setGasPrice(value: 0, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceWei, 1)

        transaction.setGasPrice(value: 100.0 / 3.0, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceWei, UInt.max - 2)

        transaction.setGasPrice(value: (100.0 / 3.0).nextDown, inRelationTo: info)
        let valueBelowStandard = try XCTUnwrap(transaction.gasPriceWei)
        XCTAssertGreaterThanOrEqual(valueBelowStandard, 1)
        XCTAssertLessThanOrEqual(valueBelowStandard, UInt.max - 2)

        transaction.setGasPrice(value: 100, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceWei, UInt.max)
    }

    func testGasSliderInterpolationPreservesNormalFlooringAndRejectsInvalidValues() {
        let info = GasService.Info(standard: 200, slow: 100, fast: 300, rapid: 400)
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")

        transaction.setGasPrice(value: 100.0 / 6.0, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceWei, 150)

        let validGasPrice = transaction.gasPrice
        for invalidValue in [Double.nan, Double.infinity, -Double.infinity, -1, 101] {
            transaction.setGasPrice(value: invalidValue, inRelationTo: info)
            XCTAssertEqual(transaction.gasPrice, validGasPrice)
        }
    }

    func testExactGasPriceParserSupportsFractionalAndUIntOverflowValues() throws {
        XCTAssertEqual(Transaction.gasPriceWei(fromGwei: "1.5"), BigUInt(1_500_000_000))
        XCTAssertEqual(Transaction.gasPriceWei(fromGwei: ".0000000015"), BigUInt(2))
        XCTAssertEqual(Transaction.gasPriceWei(fromGwei: ".0000000025"), BigUInt(2))
        XCTAssertNil(Transaction.gasPriceWei(fromGwei: ""))
        XCTAssertNil(Transaction.gasPriceWei(fromGwei: "1.2.3"))
        XCTAssertNil(Transaction.gasPriceWei(fromGwei: "not-a-number"))
        XCTAssertNil(Transaction.gasPriceWei(fromGwei: "1.000000000١"))

        let largeGasPrice = try XCTUnwrap(Transaction.gasPriceWei(fromGwei: "18446744074"))
        XCTAssertGreaterThan(largeGasPrice, BigUInt(UInt64.max))

        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = largeGasPrice.hexString
        XCTAssertNil(transaction.gasPriceWei)
        XCTAssertEqual(Transaction.gasPriceWei(fromGwei: try XCTUnwrap(transaction.editableGasPriceGwei)), largeGasPrice)

        transaction.gasPrice = BigUInt(1_234_567_890).hexString
        XCTAssertEqual(transaction.gasPriceGwei, "1")
        XCTAssertEqual(transaction.editableGasPriceGwei, "1.23456789")
    }

    func testTransactionEditsApplyOnlyChangedFieldsToLatestTransaction() {
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = BigUInt(100).hexString
        transaction.nonce = String.hex(1)
        let edits = Transaction.Edits(gasPrice: BigUInt(200))

        transaction.nonce = String.hex(7)
        transaction.gas = "5208"
        transaction.interpretation = "latest interpretation"
        let oldID = transaction.id

        XCTAssertTrue(transaction.apply(edits))
        XCTAssertEqual(transaction.gasPriceValue, BigUInt(200))
        XCTAssertEqual(transaction.nonce, String.hex(7))
        XCTAssertEqual(transaction.gas, "5208")
        XCTAssertEqual(transaction.interpretation, "latest interpretation")
        XCTAssertNotEqual(transaction.id, oldID)

        let appliedID = transaction.id
        XCTAssertFalse(transaction.apply(Transaction.Edits(gasPrice: BigUInt(200))))
        XCTAssertEqual(transaction.id, appliedID)
    }

    func testNonceOnlyEditPreservesLatestGasPrice() {
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = BigUInt(999).hexString

        XCTAssertTrue(transaction.apply(Transaction.Edits(nonce: 3)))
        XCTAssertEqual(transaction.gasPriceValue, BigUInt(999))
        XCTAssertEqual(transaction.nonce, String.hex(3))
    }

    func testApprovalValidationAcceptsUIntOverflowThroughUInt256AndPreservesNonMainnetZero() throws {
        let mainnet = makeNetwork(chainID: EthereumNetwork.ethMainnetChainId)
        let otherNetwork = makeNetwork(chainID: 10)
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.nonce = String.hex(0)
        transaction.gas = String.hex(21_000)

        let largeGasPrice = try XCTUnwrap(BigUInt(decimalString: "18446744073709551616"))
        transaction.gasPrice = largeGasPrice.hexString
        XCTAssertNil(transaction.gasPriceWei)
        XCTAssertTrue(transaction.isReadyForApproval(on: mainnet))

        let maximumGasPrice = try XCTUnwrap(BigUInt(hexString: String(repeating: "f", count: 64)))
        transaction.gasPrice = maximumGasPrice.hexString
        XCTAssertTrue(transaction.isReadyForApproval(on: mainnet))

        let uint256Overflow = try XCTUnwrap(BigUInt(hexString: "1" + String(repeating: "0", count: 64)))
        transaction.gasPrice = uint256Overflow.hexString
        XCTAssertFalse(Transaction.isValidGasPrice(uint256Overflow, on: mainnet))
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
        XCTAssertFalse(transaction.isReadyForApproval(on: otherNetwork))

        transaction.gasPrice = BigUInt(0).hexString
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
        XCTAssertTrue(transaction.isReadyForApproval(on: otherNetwork))

        transaction.gasPrice = "invalid"
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
        XCTAssertFalse(transaction.isReadyForApproval(on: otherNetwork))

        transaction.gasPrice = BigUInt(1).hexString
        transaction.gas = nil
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
    }

    func testNativeBalanceRequestPolicySkipsTempoNetworks() {
        var requestedChainIDs = [Int]()

        for chainID in [4_217, 31_318, 42_429, 42_431, EthereumNetwork.ethMainnetChainId, 999_999] {
            let network = makeNetwork(chainID: chainID)
            Ethereum.performNativeBalanceRequest(for: network) {
                requestedChainIDs.append(chainID)
            }
        }

        XCTAssertEqual(requestedChainIDs, [EthereumNetwork.ethMainnetChainId, 999_999])
    }

    func testPreparedTransactionsRemainReadyOnTempoNetworks() {
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.nonce = String.hex(0)
        transaction.gas = String.hex(21_000)
        transaction.gasPrice = BigUInt(1).hexString

        for chainID in [4_217, 31_318, 42_429, 42_431] {
            let tempo = makeNetwork(chainID: chainID)
            XCTAssertTrue(transaction.isReadyForApproval(on: tempo))
        }
    }

    func testEthereumRPCEmitsFeeHistoryRequestAndDecodesObjectResult() throws {
        let session = makeRPCSession()
        let requestReceived = expectation(description: "request received")
        let completionReceived = expectation(description: "completion received")
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: rpcURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: rpcURL) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.bodyData(from: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
            XCTAssertEqual(object["id"] as? Int, 1)
            XCTAssertEqual(object["method"] as? String, "eth_feeHistory")
            let params = try XCTUnwrap(object["params"] as? [Any])
            XCTAssertEqual(params[0] as? String, "0xa")
            XCTAssertEqual(params[1] as? String, "latest")
            XCTAssertEqual((params[2] as? [NSNumber])?.map(\.doubleValue), [10, 25, 50, 75])
            requestReceived.fulfill()

            let response = try Self.httpResponse(for: request, statusCode: 200)
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "baseFeePerGas": ["0x1", "0x64"],
                    "reward": [["0x1", "0x2", "0x3", "0x4"]]
                ]
            ])
            return (response, data)
        }

        EthereumRPC(urlSession: session).fetchFeeHistory(
            rpcUrl: rpcURL,
            blockCount: 10,
            rewardPercentiles: [10, 25, 50, 75]
        ) { result in
            switch result {
            case .success(let history):
                XCTAssertEqual(
                    history,
                    EthereumFeeHistory(
                        baseFeePerGas: ["0x1", "0x64"],
                        reward: [["0x1", "0x2", "0x3", "0x4"]]
                    )
                )
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [requestReceived, completionReceived], timeout: 1)
    }

    func testMalformedRewardDecodingRetainsValidNextBaseFee() throws {
        let malformedRewardRPCURL = rpcURL
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: malformedRewardRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: malformedRewardRPCURL) { request in
            _ = requestCount.increment()
            let response = try Self.httpResponse(for: request, statusCode: 200)
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": [
                    "baseFeePerGas": ["0x1", "0x64"],
                    "reward": [["0x1", 2, "0x3", "0x4"]]
                ]
            ])
            return (response, data)
        }

        let estimate = fetchEstimate(using: GasService(rpc: EthereumRPC(urlSession: session)))

        XCTAssertEqual(requestCount.value, 1)
        XCTAssertNil(estimate.info)
        XCTAssertEqual(estimate.nextBaseFee, 100)
    }

    func testEthereumRPCRetriesStructuredTransientHTTPFailuresThenSucceeds() throws {
        try assertStructuredTransientHTTPFailureRetries(statusCode: 429)
        try assertStructuredTransientHTTPFailureRetries(statusCode: 503)
    }

    func testEthereumRPCDoesNotRetryPermanentClientHTTPFailure() throws {
        let permanentFailureRPCURL = rpcURL + "/permanent-http"
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(description: "completion received")
        let unexpectedRetry = expectation(description: "did not retry permanent HTTP failure")
        unexpectedRetry.isInverted = true
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: permanentFailureRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: permanentFailureRPCURL) { request in
            if requestCount.increment() > 1 {
                unexpectedRetry.fulfill()
            }
            let response = try Self.httpResponse(for: request, statusCode: 400)
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "error": ["code": -32_000, "message": "Permanent client error"]
            ])
            return (response, data)
        }

        EthereumRPC(urlSession: session).fetchGasPrice(rpcUrl: permanentFailureRPCURL) { result in
            if case .success(let gasPrice) = result {
                XCTFail("Unexpected gas price: \(gasPrice)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived, unexpectedRetry], timeout: 1)
        XCTAssertEqual(requestCount.value, 1)
    }

    func testEthereumRPCDoesNotRetryTransientHTTPFailureWhenSendingTransaction() {
        let sendRPCURL = rpcURL + "/send-transaction"
        assertSendDoesNotRetry(rpcURL: sendRPCURL) { request in
            (try Self.httpResponse(for: request, statusCode: 503), Data())
        }
    }

    func testEthereumRPCDoesNotRetryTransportFailureWhenSendingTransaction() {
        assertSendDoesNotRetry(rpcURL: rpcURL + "/send-transport-error") { _ in
            throw StubError.expected
        }
    }

    func testEthereumRPCDoesNotRetryMalformedResponseWhenSendingTransaction() {
        assertSendDoesNotRetry(rpcURL: rpcURL + "/send-malformed-response") { request in
            (try Self.httpResponse(for: request, statusCode: 200), Data("{".utf8))
        }
    }

    func testEthereumRPCPreservesRPCErrorFromNonSuccessHTTPResponse() throws {
        let errorRPCURL = rpcURL + "/rpc-error"
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(description: "completion received")
        let unexpectedRetry = expectation(description: "did not retry a valid RPC error")
        unexpectedRetry.isInverted = true
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: errorRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: errorRPCURL) { request in
            if requestCount.increment() > 1 {
                unexpectedRetry.fulfill()
            }
            let response = try Self.httpResponse(for: request, statusCode: 500)
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": ["code": -32_601, "message": "Method not found"]
            ])
            return (response, data)
        }

        EthereumRPC(urlSession: session).fetchGasPrice(rpcUrl: errorRPCURL) { result in
            switch result {
            case .success(let gasPrice):
                XCTFail("Unexpected gas price: \(gasPrice)")
            case .failure(let error):
                guard let rpcError = error as? EthereumRPCError else {
                    XCTFail("Unexpected error: \(error)")
                    completionReceived.fulfill()
                    return
                }
                guard case let .serverError(code, message) = rpcError else {
                    XCTFail("Unexpected RPC error: \(rpcError)")
                    completionReceived.fulfill()
                    return
                }
                XCTAssertEqual(code, -32_601)
                XCTAssertEqual(message, "Method not found")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived, unexpectedRetry], timeout: 1)
        XCTAssertEqual(requestCount.value, 1)
    }

    private func fetchEstimate(
        using service: GasService,
        description: String = "gas estimate",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GasService.Estimate {
        let completed = expectation(description: description)
        completed.assertForOverFulfill = true
        var receivedEstimate = GasService.Estimate(info: nil, nextBaseFee: nil)

        service.fetchEstimate(rpcUrl: rpcURL) { estimate in
            XCTAssertTrue(Thread.isMainThread, file: file, line: line)
            receivedEstimate = estimate
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
        return receivedEstimate
    }

    private func assertStructuredTransientHTTPFailureRetries(
        statusCode: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let transientRPCURL = rpcURL + "/transient-\(statusCode)"
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(description: "completed after retrying HTTP \(statusCode)")
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: transientRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: transientRPCURL) { request in
            let attempt = requestCount.increment()
            let response = try Self.httpResponse(for: request, statusCode: attempt == 1 ? statusCode : 200)
            let data: Data
            if attempt == 1 {
                data = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "error": ["code": -32_000, "message": "Temporarily unavailable"]
                ])
            } else {
                data = try JSONSerialization.data(withJSONObject: [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "result": "0x64"
                ])
            }
            return (response, data)
        }

        EthereumRPC(urlSession: session).fetchGasPrice(rpcUrl: transientRPCURL) { result in
            switch result {
            case .success(let gasPrice):
                XCTAssertEqual(gasPrice, "0x64", file: file, line: line)
            case .failure(let error):
                XCTFail("Unexpected error after retry: \(error)", file: file, line: line)
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 2, file: file, line: line)
    }

    private func assertSendDoesNotRetry(
        rpcURL: String,
        response: @escaping GasServiceURLProtocol.RequestHandler,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(description: "completion received")
        let unexpectedRetry = expectation(description: "did not retry transaction submission")
        unexpectedRetry.isInverted = true
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: rpcURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: rpcURL) { request in
            if requestCount.increment() > 1 {
                unexpectedRetry.fulfill()
            }
            return try response(request)
        }

        EthereumRPC(urlSession: session).sendRawTransaction(
            rpcUrl: rpcURL,
            signedTxData: "0x01"
        ) { result in
            if case .success(let transactionHash) = result {
                XCTFail("Unexpected transaction hash: \(transactionHash)", file: file, line: line)
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived, unexpectedRetry], timeout: 1)
        XCTAssertEqual(requestCount.value, 1, file: file, line: line)
    }

    private func makeRPCSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GasServiceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeNetwork(chainID: Int) -> EthereumNetwork {
        EthereumNetwork(
            chainId: chainID,
            name: "Test",
            symbol: "ETH",
            nodeURLString: rpcURL,
            isTestnet: false,
            mightShowPrice: false,
            explorer: nil
        )
    }

    private static func httpResponse(
        for request: URLRequest,
        statusCode: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> HTTPURLResponse {
        let url = try XCTUnwrap(request.url, file: file, line: line)
        return try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ),
            file: file,
            line: line
        )
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? StubError.expected
            }
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private enum StubError: Error {
    case expected
}

private final class FakeEthereumRPCClient: EthereumFeeHistoryRPCClient {

    struct FeeHistoryCall {
        let rpcURL: String
        let blockCount: UInt
        let rewardPercentiles: [Double]
    }

    private let feeHistoryResult: Result<EthereumFeeHistory, Error>
    private let feeHistoryCompletionCount: Int

    private(set) var feeHistoryCalls = [FeeHistoryCall]()

    init(
        feeHistoryResult: Result<EthereumFeeHistory, Error>,
        feeHistoryCompletionCount: Int = 1
    ) {
        self.feeHistoryResult = feeHistoryResult
        self.feeHistoryCompletionCount = feeHistoryCompletionCount
    }

    func fetchFeeHistory(
        rpcUrl: String,
        blockCount: UInt,
        rewardPercentiles: [Double],
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        feeHistoryCalls.append(FeeHistoryCall(
            rpcURL: rpcUrl,
            blockCount: blockCount,
            rewardPercentiles: rewardPercentiles
        ))
        for _ in 0..<feeHistoryCompletionCount {
            completion(feeHistoryResult)
        }
    }

}

private final class GasServiceURLProtocol: URLProtocol {

    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let requestHandlersLock = NSLock()
    private static var requestHandlers = [String: RequestHandler]()

    static func setRequestHandler(for url: String, handler: @escaping RequestHandler) {
        requestHandlersLock.lock()
        requestHandlers[url] = handler
        requestHandlersLock.unlock()
    }

    static func removeRequestHandler(for url: String) {
        requestHandlersLock.lock()
        requestHandlers.removeValue(forKey: url)
        requestHandlersLock.unlock()
    }

    private static func requestHandler(for request: URLRequest) -> RequestHandler? {
        guard let url = request.url?.absoluteString else { return nil }
        requestHandlersLock.lock()
        defer { requestHandlersLock.unlock() }
        return requestHandlers[url]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler(for: request) else {
            client?.urlProtocol(self, didFailWithError: StubError.expected)
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedCounter {

    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedValue += 1
        return storedValue
    }
}

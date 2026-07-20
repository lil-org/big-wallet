// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

final class GasServiceTests: XCTestCase {

    private let rpcURL = "https://rpc.example"
    private let alchemyRPCURL = "https://eth-mainnet.g.alchemy.com/v2"
    private let fetchedInfo = GasService.Info(standard: 200, slow: 150, fast: 250, rapid: 300)

    private var alchemyEndpoint: EthereumRPCEndpoint {
        return .catalog(
            URL(string: alchemyRPCURL)!,
            alchemyNetwork: "eth-mainnet"
        )
    }

    private func endpoint(_ value: String) -> EthereumRPCEndpoint {
        return .unauthenticated(URL(string: value)!)
    }

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
        XCTAssertEqual(rpc.feeHistoryCalls.first?.allowsAlchemyAuthorization, false)
        XCTAssertEqual(estimate.nextBaseFee, 100)
        XCTAssertEqual(estimate.info, GasService.Info(standard: 112, slow: 103, fast: 122, rapid: 132))
        XCTAssertEqual(estimate.info?.sliderValues, [103, 112, 122, 132])
    }

    func testFetchEstimatePropagatesTrustedAlchemyAuthorization() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0x1", "0x64"],
            reward: [["0x1", "0x2", "0x3", "0x4"]]
        )
        let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

        _ = fetchEstimate(
            using: GasService(rpc: rpc),
            endpoint: alchemyEndpoint
        )

        XCTAssertEqual(rpc.feeHistoryCalls.first?.allowsAlchemyAuthorization, true)
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

        GasService(rpc: rpc).fetchEstimate(endpoint: endpoint(rpcURL)) { estimate in
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

    func testTransactionPreparationStateRequiresCurrentTerminalSuccess() {
        let firstTransactionID = UUID()
        let secondTransactionID = UUID()
        var state = TransactionPreparationState()

        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(
            state.canApprove(
                transactionID: firstTransactionID,
                transactionIsReady: true
            )
        )

        let firstAttempt = state.beginPreparation(
            for: firstTransactionID
        )
        XCTAssertEqual(state.phase, .preparing)
        XCTAssertFalse(
            state.canApprove(
                transactionID: firstTransactionID,
                transactionIsReady: true
            )
        )

        state.beginEditing(secondTransactionID)
        XCTAssertEqual(state.phase, .editing)
        XCTAssertFalse(
            state.markReady(
                attemptID: firstAttempt,
                transactionID: firstTransactionID
            )
        )

        let secondAttempt = state.beginPreparation(
            for: secondTransactionID
        )
        XCTAssertTrue(
            state.markReady(
                attemptID: secondAttempt,
                transactionID: secondTransactionID
            )
        )
        XCTAssertTrue(
            state.canApprove(
                transactionID: secondTransactionID,
                transactionIsReady: true
            )
        )
        XCTAssertFalse(
            state.canApprove(
                transactionID: secondTransactionID,
                transactionIsReady: false
            )
        )

        state.finish()
        XCTAssertEqual(state.phase, .finished)
        XCTAssertFalse(
            state.canApprove(
                transactionID: secondTransactionID,
                transactionIsReady: true
            )
        )
    }

    func testTransactionPreparationRestartGateCoalescesAndPreservesPendingCheck() {
        var gate = TransactionPreparationRestartGate()

        XCTAssertFalse(gate.isPending)
        XCTAssertTrue(gate.recordMutation())
        XCTAssertTrue(gate.isPending)
        for _ in 0..<20 {
            XCTAssertFalse(gate.recordMutation())
        }
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.consume())
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.consume())

        XCTAssertTrue(gate.recordMutation())
        XCTAssertTrue(gate.consume())
    }

    func testEthereumPreparationReportsNonceFailure() {
        let rpc = EthereumPreparationRPCStub(
            nonceResult: .failure(StubError.expected)
        )

        assertSinglePreparationFailure(
            using: rpc,
            transaction: Transaction(
                from: "0x0",
                to: "",
                value: nil,
                data: "0x"
            ),
            expectedFailure: .nonceUnavailable
        )

        XCTAssertEqual(rpc.nonceCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testEthereumPreparationReportsGasPriceFailure() {
        let rpc = EthereumPreparationRPCStub(
            gasPriceResult: .failure(StubError.expected)
        )

        assertSinglePreparationFailure(
            using: rpc,
            transaction: Transaction(
                from: "0x0",
                to: "",
                value: nil,
                data: "0x"
            ),
            expectedFailure: .gasPriceUnavailable
        )

        XCTAssertEqual(rpc.nonceCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testEthereumPreparationReportsFirstGasEstimateFailure() {
        let rpc = EthereumPreparationRPCStub(
            estimateGasResults: [.failure(StubError.expected)]
        )
        var transaction = Transaction(
            from: "0x0",
            to: "",
            value: nil,
            data: "0x"
        )
        transaction.nonce = "0x1"
        transaction.gasPrice = "0x64"

        assertSinglePreparationFailure(
            using: rpc,
            transaction: transaction,
            expectedFailure: .gasEstimationFailed
        )

        XCTAssertEqual(rpc.nonceCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
        XCTAssertEqual(rpc.estimateGasCallCount, 1)
    }

    func testEthereumPreparationReportsSecondGasEstimateFailure() {
        let rpc = EthereumPreparationRPCStub(
            estimateGasResults: [
                .success("0x5208"),
                .failure(StubError.expected)
            ]
        )
        var transaction = Transaction(
            from: "0x0",
            to: "",
            value: nil,
            data: "0x"
        )
        transaction.nonce = "0x1"
        transaction.gasPrice = "0x64"

        assertSinglePreparationFailure(
            using: rpc,
            transaction: transaction,
            expectedFailure: .gasEstimationFailed
        )

        XCTAssertEqual(rpc.nonceCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
        XCTAssertEqual(rpc.estimateGasCallCount, 2)
    }

    func testEthereumPreparationReportsConcurrentFailuresOnlyOnce() {
        let rpc = EthereumPreparationRPCStub(
            nonceResult: .failure(StubError.expected),
            gasPriceResult: .failure(StubError.expected)
        )

        assertSinglePreparationFailure(
            using: rpc,
            transaction: Transaction(
                from: "0x0",
                to: "",
                value: nil,
                data: "0x"
            ),
            expectedFailure: .nonceUnavailable
        )

        XCTAssertEqual(rpc.nonceCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testEthereumPreparationKeepsPublishingSuccessfulUpdates() {
        let rpc = EthereumPreparationRPCStub()
        let publishedUpdate = expectation(description: "published preparation update")
        publishedUpdate.expectedFulfillmentCount = 3
        let terminalSuccess = expectation(
            description: "preparation reached terminal success"
        )
        let additionalTerminalResult = expectation(
            description: "preparation did not terminate more than once"
        )
        additionalTerminalResult.isInverted = true
        var latestTransaction: Transaction?
        var terminalResultCount = 0

        Ethereum(rpc: rpc).prepareTransaction(
            Transaction(
                from: "0x0",
                to: "",
                value: nil,
                data: "0x"
            ),
            forceGasCheck: false,
            network: makeNetwork(chainID: EthereumNetwork.ethMainnetChainId),
            onUpdate: { transaction in
                XCTAssertTrue(Thread.isMainThread)
                latestTransaction = transaction
                publishedUpdate.fulfill()
            },
            completion: { result in
                XCTAssertTrue(Thread.isMainThread)
                terminalResultCount += 1
                if terminalResultCount > 1 {
                    additionalTerminalResult.fulfill()
                }
                guard case .success(let transaction) = result else {
                    XCTFail("Expected terminal preparation success")
                    return
                }
                latestTransaction = transaction
                terminalSuccess.fulfill()
            }
        )

        wait(
            for: [
                publishedUpdate,
                terminalSuccess,
                additionalTerminalResult,
            ],
            timeout: 0.2
        )
        XCTAssertEqual(terminalResultCount, 1)
        XCTAssertEqual(latestTransaction?.nonce, "0x1")
        XCTAssertEqual(latestTransaction?.gasPrice, "0x64")
        XCTAssertEqual(latestTransaction?.gas, "0x5208")
        XCTAssertEqual(rpc.nonceCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 2)
    }

    func testEthereumPreparationWaitsForNonceWhenGasFinishesFirst() {
        let rpc = EthereumPreparationRPCStub(nonceDelay: 0.03)
        let terminalSuccess = expectation(
            description: "preparation waited for both branches"
        )
        var updates = [Transaction]()

        Ethereum(rpc: rpc).prepareTransaction(
            Transaction(
                from: "0x0",
                to: "",
                value: nil,
                data: "0x"
            ),
            forceGasCheck: false,
            network: makeNetwork(
                chainID: EthereumNetwork.ethMainnetChainId
            ),
            onUpdate: { transaction in
                updates.append(transaction)
            },
            completion: { result in
                guard case .success(let prepared) = result else {
                    XCTFail("Expected terminal preparation success")
                    return
                }
                XCTAssertEqual(prepared.nonce, "0x1")
                XCTAssertEqual(prepared.gasPrice, "0x64")
                XCTAssertEqual(prepared.gas, "0x5208")
                terminalSuccess.fulfill()
            }
        )

        wait(for: [terminalSuccess], timeout: 0.2)
        XCTAssertEqual(updates.count, 3)
        XCTAssertNil(updates.first?.nonce)
        XCTAssertEqual(updates.first?.gasPrice, "0x64")
        XCTAssertEqual(updates.dropFirst().first?.gas, "0x5208")
        XCTAssertEqual(updates.last?.nonce, "0x1")
    }

    func testEthereumPreparationIgnoresDuplicateRPCCallbacks() {
        let rpc = EthereumPreparationRPCStub(
            nonceCompletionCount: 2,
            gasPriceCompletionCount: 2
        )
        let firstTerminalResult = expectation(
            description: "preparation terminated"
        )
        let additionalTerminalResult = expectation(
            description: "preparation terminated exactly once"
        )
        additionalTerminalResult.isInverted = true
        var terminalResultCount = 0

        Ethereum(rpc: rpc).prepareTransaction(
            Transaction(
                from: "0x0",
                to: "",
                value: nil,
                data: "0x"
            ),
            forceGasCheck: false,
            network: makeNetwork(
                chainID: EthereumNetwork.ethMainnetChainId
            ),
            onUpdate: { _ in },
            completion: { result in
                terminalResultCount += 1
                guard terminalResultCount == 1 else {
                    additionalTerminalResult.fulfill()
                    return
                }
                guard case .success = result else {
                    XCTFail("Expected terminal preparation success")
                    return
                }
                firstTerminalResult.fulfill()
            }
        )

        wait(
            for: [firstTerminalResult, additionalTerminalResult],
            timeout: 0.2
        )
        XCTAssertEqual(terminalResultCount, 1)
        XCTAssertEqual(rpc.nonceCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 2)
    }

    func testCancellingEthereumPreparationPreventsSecondGasEstimate() {
        let firstEstimateStarted = expectation(
            description: "first gas estimate started"
        )
        let unexpectedUpdate = expectation(
            description: "cancelled preparation emitted no update"
        )
        unexpectedUpdate.isInverted = true
        let unexpectedCompletion = expectation(
            description: "cancelled preparation did not complete"
        )
        unexpectedCompletion.isInverted = true
        let rpc = EthereumPreparationRPCStub(
            defersEstimateGasCompletions: true
        )
        rpc.onEstimateGasCall = {
            firstEstimateStarted.fulfill()
        }
        var transaction = Transaction(
            from: "0x0",
            to: "",
            value: nil,
            data: "0x"
        )
        transaction.nonce = "0x1"
        transaction.gasPrice = "0x64"

        let cancellation = Ethereum(rpc: rpc).prepareTransaction(
            transaction,
            forceGasCheck: true,
            network: makeNetwork(
                chainID: EthereumNetwork.ethMainnetChainId
            ),
            onUpdate: { _ in
                unexpectedUpdate.fulfill()
            },
            completion: { _ in
                unexpectedCompletion.fulfill()
            }
        )

        wait(for: [firstEstimateStarted], timeout: 2)
        cancellation.cancel()
        rpc.completeNextEstimateGas()

        wait(
            for: [unexpectedUpdate, unexpectedCompletion],
            timeout: 0.5
        )
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(rpc.estimateGasCallCount, 1)
    }

    func testEthereumRPCCancellationStopsActiveTaskWithoutRetry() {
        let requestStarted = expectation(description: "RPC request started")
        let requestStopped = expectation(description: "RPC request stopped")
        let unexpectedCompletion = expectation(
            description: "cancelled RPC did not complete"
        )
        unexpectedCompletion.isInverted = true
        let session = makeHangingRPCSession(
            onStart: {
                requestStarted.fulfill()
            },
            onStop: {
                requestStopped.fulfill()
            }
        )
        let cancellation = EthereumRequestCancellation()
        defer {
            session.invalidateAndCancel()
            HangingGasServiceURLProtocol.reset()
        }

        EthereumRPC(urlSession: session).fetchGasPrice(
            endpoint: endpoint(rpcURL),
            cancellation: cancellation
        ) { _ in
            unexpectedCompletion.fulfill()
        }

        wait(for: [requestStarted], timeout: 2)
        cancellation.cancel()

        wait(
            for: [requestStopped, unexpectedCompletion],
            timeout: 0.7
        )
        XCTAssertEqual(HangingGasServiceURLProtocol.requestCount, 1)
    }

    func testEthereumRPCCancellationWaitsForActiveCompletion() {
        let callbackStarted = expectation(
            description: "RPC completion started"
        )
        let callbackFinished = expectation(
            description: "RPC completion finished"
        )
        let allowCompletion = DispatchSemaphore(value: 0)
        let cancellationReturned = DispatchSemaphore(value: 0)
        let session = makeRPCSession()
        let cancellation = EthereumRequestCancellation()
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: rpcURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: rpcURL) { request in
            (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"0x64"}"#.utf8
                )
            )
        }

        EthereumRPC(urlSession: session).fetchGasPrice(
            endpoint: endpoint(rpcURL),
            cancellation: cancellation
        ) { result in
            guard case .success("0x64") = result else {
                XCTFail("Expected gas-price success")
                return
            }
            callbackStarted.fulfill()
            XCTAssertEqual(
                allowCompletion.wait(timeout: .now() + 2),
                .success
            )
            callbackFinished.fulfill()
        }

        wait(for: [callbackStarted], timeout: 2)
        DispatchQueue.global(qos: .userInitiated).async {
            cancellation.cancel()
            cancellationReturned.signal()
        }

        XCTAssertEqual(
            cancellationReturned.wait(timeout: .now() + 0.1),
            .timedOut
        )
        allowCompletion.signal()
        wait(for: [callbackFinished], timeout: 2)
        XCTAssertEqual(
            cancellationReturned.wait(timeout: .now() + 2),
            .success
        )
    }

    func testEthereumPreparationCompletesReadyTransactionAsynchronouslyWithoutRPC() {
        let rpc = EthereumPreparationRPCStub()
        let terminalSuccess = expectation(
            description: "ready transaction completed"
        )
        let unexpectedUpdate = expectation(
            description: "ready transaction emitted no partial update"
        )
        unexpectedUpdate.isInverted = true
        var transaction = Transaction(
            from: "0x0",
            to: "",
            value: nil,
            data: "0x"
        )
        transaction.nonce = "0x1"
        transaction.gasPrice = "0x64"
        transaction.gas = "0x5208"
        var didReturnFromPrepare = false

        Ethereum(rpc: rpc).prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: makeNetwork(
                chainID: EthereumNetwork.ethMainnetChainId
            ),
            onUpdate: { _ in
                unexpectedUpdate.fulfill()
            },
            completion: { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertTrue(didReturnFromPrepare)
                guard case .success(let prepared) = result else {
                    XCTFail("Expected terminal preparation success")
                    return
                }
                XCTAssertEqual(prepared.id, transaction.id)
                terminalSuccess.fulfill()
            }
        )
        didReturnFromPrepare = true

        wait(
            for: [terminalSuccess, unexpectedUpdate],
            timeout: 0.2
        )
        XCTAssertEqual(rpc.nonceCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testEthereumPreparationDoesNotWaitForInspectionAndPublishesLateResult() {
        let rpc = EthereumPreparationRPCStub()
        let terminalSuccess = expectation(
            description: "preparation completed without inspection"
        )
        let additionalTerminalResult = expectation(
            description: "inspection did not redeliver terminal result"
        )
        additionalTerminalResult.isInverted = true
        let lateInspectionUpdate = expectation(
            description: "late inspection remained a partial update"
        )
        var inspectionCompletion: ((String) -> Void)?
        var terminalResultCount = 0
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x12345678"
        )
        transaction.nonce = "0x1"
        transaction.gasPrice = "0x64"
        transaction.gas = "0x5208"
        let ethereum = Ethereum(
            rpc: rpc,
            interpretTransaction: { _, _, completion in
                inspectionCompletion = completion
            }
        )

        ethereum.prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: makeNetwork(
                chainID: EthereumNetwork.ethMainnetChainId
            ),
            onUpdate: { updated in
                if updated.interpretation == "late interpretation" {
                    lateInspectionUpdate.fulfill()
                }
            },
            completion: { result in
                terminalResultCount += 1
                guard terminalResultCount == 1 else {
                    additionalTerminalResult.fulfill()
                    return
                }
                guard case .success = result else {
                    XCTFail("Expected terminal preparation success")
                    return
                }
                terminalSuccess.fulfill()
            }
        )

        wait(for: [terminalSuccess], timeout: 0.2)
        XCTAssertNotNil(inspectionCompletion)
        inspectionCompletion?("late interpretation")
        wait(
            for: [lateInspectionUpdate, additionalTerminalResult],
            timeout: 0.2
        )
        XCTAssertEqual(terminalResultCount, 1)
        XCTAssertEqual(rpc.nonceCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testEthereumForcedPreparationRechecksPrefilledGasBeforeSuccess() {
        let rpc = EthereumPreparationRPCStub()
        let terminalSuccess = expectation(
            description: "forced preparation completed"
        )
        var transaction = Transaction(
            from: "0x0",
            to: "",
            value: nil,
            data: "0x"
        )
        transaction.nonce = "0x1"
        transaction.gasPrice = "0x64"
        transaction.gas = "0x1"

        Ethereum(rpc: rpc).prepareTransaction(
            transaction,
            forceGasCheck: true,
            network: makeNetwork(
                chainID: EthereumNetwork.ethMainnetChainId
            ),
            onUpdate: { _ in },
            completion: { result in
                guard case .success(let prepared) = result else {
                    XCTFail("Expected terminal preparation success")
                    return
                }
                XCTAssertEqual(prepared.gas, "0x5208")
                terminalSuccess.fulfill()
            }
        )

        wait(for: [terminalSuccess], timeout: 0.2)
        XCTAssertEqual(rpc.nonceCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
        XCTAssertEqual(rpc.estimateGasCallCount, 2)
    }

    func testEthereumPreparationRejectsInvalidFinalTransaction() {
        let rpc = EthereumPreparationRPCStub(
            nonceResult: .success("not-hex")
        )

        assertSinglePreparationFailure(
            using: rpc,
            transaction: Transaction(
                from: "0x0",
                to: "",
                value: nil,
                data: "0x"
            ),
            expectedFailure: .invalidTransaction
        )
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
            endpoint: endpoint(rpcURL),
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

        EthereumRPC(urlSession: session).fetchGasPrice(
            endpoint: endpoint(permanentFailureRPCURL)
        ) { result in
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

    func testEthereumRPCRetriesTransientAuthorizationAcquisitionFailure()
        throws {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "gas price fetched after authorization recovery"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [
                    .failure(StubError.expected),
                    .success("fresh-token"),
                ]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer fresh-token"
            )
            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"0x64"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).fetchGasPrice(
            endpoint: alchemyEndpoint
        ) { result in
            switch result {
            case .success(let gasPrice):
                XCTAssertEqual(gasPrice, "0x64")
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 2)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
    }

    func testEthereumRPCBoundsRepeatedAuthorizationAcquisitionFailures()
        throws {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "bounded authorization failure returned"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: Array(
                    repeating: Result<String?, Error>.failure(
                        StubError.expected
                    ),
                    count: 5
                )
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            _ = requestCount.increment()
            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"0x64"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).fetchGasPrice(
            endpoint: alchemyEndpoint
        ) { result in
            if case .success(let gasPrice) = result {
                XCTFail("Unexpected gas price: \(gasPrice)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 3)
        XCTAssertEqual(requestCount.value, 0)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 5)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
    }

    func testEthereumRPCRetriesReadAfterReplacementAuthorizationFailure()
        throws {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "gas price fetched after replacement recovery"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [
                    .success("rejected-token"),
                    .success("fresh-token"),
                ],
                replacements: [.failure(StubError.expected)]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            let attempt = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                attempt == 1
                    ? "Bearer rejected-token"
                    : "Bearer fresh-token"
            )
            if attempt == 1 {
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(#"{"error":"unauthorized"}"#.utf8)
                )
            }
            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"0x64"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).fetchGasPrice(
            endpoint: alchemyEndpoint
        ) { result in
            switch result {
            case .success(let gasPrice):
                XCTAssertEqual(gasPrice, "0x64")
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 2)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
    }

    func testEthereumRPCSecond401IsTerminalAfterThrownReplacementFailure()
        throws {
        try assertSecond401IsTerminalAfterReplacementRecoveryFailure(
            .failure(StubError.expected)
        )
    }

    func testEthereumRPCSecond401IsTerminalAfterMissingReplacement()
        throws {
        try assertSecond401IsTerminalAfterReplacementRecoveryFailure(
            .success(nil)
        )
    }

    func testEthereumRPCInitialAuthorizationFailureDoesNotConsume401Recovery()
        throws {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "gas price fetched after both recovery stages"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [
                    .failure(StubError.expected),
                    .success("rejected-token"),
                ],
                replacements: [.success("replacement-token")]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            let attempt = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                attempt == 1
                    ? "Bearer rejected-token"
                    : "Bearer replacement-token"
            )
            if attempt == 1 {
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(#"{"error":"unauthorized"}"#.utf8)
                )
            }
            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"0x64"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).fetchGasPrice(
            endpoint: alchemyEndpoint
        ) { result in
            switch result {
            case .success(let gasPrice):
                XCTAssertEqual(gasPrice, "0x64")
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 3)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 2)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testEthereumRPCDoesNotSubmitWhenRawSendAuthorizationFails() {
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "authorization failure returned"
        )
        let unexpectedRequest = expectation(
            description: "raw transaction was not submitted"
        )
        unexpectedRequest.isInverted = true
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [.failure(StubError.expected)]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            unexpectedRequest.fulfill()
            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(#"{"jsonrpc":"2.0","id":1,"result":"0xtransaction"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).sendRawTransaction(
            endpoint: alchemyEndpoint,
            signedTxData: "0x01"
        ) { result in
            if case .success(let hash) = result {
                XCTFail("Unexpected transaction hash: \(hash)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived, unexpectedRequest], timeout: 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
    }

    func testEthereumRPCReplaysRawSendOnceWithReplacementAuthorizationAfter401()
        throws {
        let requestCount = LockedCounter()
        let requestBodies = LockedDataRecorder()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "raw transaction submitted after authorization recovery"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [.success("rejected-token")],
                replacements: [.success("replacement-token")]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            let attempt = requestCount.increment()
            requestBodies.append(try Self.bodyData(from: request))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                attempt == 1
                    ? "Bearer rejected-token"
                    : "Bearer replacement-token"
            )
            if attempt == 1 {
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(#"{"error":"unauthorized"}"#.utf8)
                )
            }
            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"0xtransaction"}"#.utf8
                )
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).sendRawTransaction(
            endpoint: alchemyEndpoint,
            signedTxData: "0x01"
        ) { result in
            switch result {
            case .success(let hash):
                XCTAssertEqual(hash, "0xtransaction")
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(requestBodies.values.count, 2)
        XCTAssertEqual(requestBodies.values[0], requestBodies.values[1])
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testEthereumRPCReplaysRawSendWhen401AlsoHasTransferError()
        throws {
        let requestCount = LockedCounter()
        let requestBodies = LockedDataRecorder()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "HTTP 401 took precedence over transfer error"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [.success("rejected-token")],
                replacements: [.success("replacement-token")]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setResponseErrorHandler(
            for: alchemyRPCURL
        ) { response in
            response.statusCode == 401
                ? URLError(.networkConnectionLost)
                : nil
        }
        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            let attempt = requestCount.increment()
            requestBodies.append(try Self.bodyData(from: request))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                attempt == 1
                    ? "Bearer rejected-token"
                    : "Bearer replacement-token"
            )
            if attempt == 1 {
                return (
                    try Self.httpResponse(for: request, statusCode: 401),
                    Data(#"{"error":"unauthorized"}"#.utf8)
                )
            }
            return (
                try Self.httpResponse(for: request, statusCode: 200),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"0xtransaction"}"#.utf8
                )
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).sendRawTransaction(
            endpoint: alchemyEndpoint,
            signedTxData: "0x01"
        ) { result in
            switch result {
            case .success(let hash):
                XCTAssertEqual(hash, "0xtransaction")
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(requestBodies.values.count, 2)
        XCTAssertEqual(requestBodies.values[0], requestBodies.values[1])
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testEthereumRPCInvalidatesSecondRejectedRawSendAuthorizationAfterPersistent401()
        throws {
        let requestCount = LockedCounter()
        let requestBodies = LockedDataRecorder()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "persistent authorization failure returned"
        )
        completionReceived.assertForOverFulfill = true
        let authorizationProvider = EthereumAuthorizationProviderStub(
            token: "rejected-token",
            replacementToken: "replacement-token"
        )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            let attempt = requestCount.increment()
            requestBodies.append(try Self.bodyData(from: request))
            XCTAssertLessThanOrEqual(attempt, 2)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                attempt == 1
                    ? "Bearer rejected-token"
                    : "Bearer replacement-token"
            )
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(#"{"error":"unauthorized"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).sendRawTransaction(
            endpoint: alchemyEndpoint,
            signedTxData: "0x01"
        ) { result in
            switch result {
            case .success(let hash):
                XCTFail("Unexpected transaction hash: \(hash)")
            case .failure(let error):
                guard case .unknown = error as? EthereumRPCError else {
                    XCTFail("Unexpected failure: \(error)")
                    completionReceived.fulfill()
                    return
                }
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(requestBodies.values.count, 2)
        XCTAssertEqual(requestBodies.values[0], requestBodies.values[1])
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["replacement-token"]
        )
        XCTAssertEqual(
            authorizationProvider.invalidationURLs.map(\.absoluteString),
            [alchemyRPCURL]
        )
    }

    func testEthereumRPCDoesNotReplayRawSendWhenReplacementAuthorizationFails()
        throws {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "replacement authorization failure returned"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [.success("rejected-token")],
                replacements: [.failure(StubError.expected)]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            _ = try Self.bodyData(from: request)
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(#"{"error":"unauthorized"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).sendRawTransaction(
            endpoint: alchemyEndpoint,
            signedTxData: "0x01"
        ) { result in
            if case .success(let hash) = result {
                XCTFail("Unexpected transaction hash: \(hash)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 1)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testEthereumRPCDoesNotRefreshAuthorizationAfter403() throws {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(description: "forbidden response returned")
        completionReceived.assertForOverFulfill = true
        let authorizationProvider = EthereumAuthorizationProviderStub(
            token: "current-token",
            replacementToken: "unused-token"
        )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            _ = requestCount.increment()
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer current-token"
            )
            return (
                try Self.httpResponse(for: request, statusCode: 403),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"error":{"code":403,"message":"forbidden"}}"#.utf8
                )
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).sendRawTransaction(
            endpoint: alchemyEndpoint,
            signedTxData: "0x01"
        ) { result in
            if case .success(let hash) = result {
                XCTFail("Unexpected transaction hash: \(hash)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
    }

    func testEthereumRPCNeverAttachesAuthorizationToCustomOrKeyedURLs() throws {
        let urls = [
            "https://rpc.example/custom",
            alchemyRPCURL,
            "https://eth-mainnet.g.alchemy.com/v2/embedded-key",
        ]
        let session = makeRPCSession()
        let authorizationProvider = EthereumAuthorizationProviderStub(token: "alchemy-only-token")
        defer {
            for url in urls {
                GasServiceURLProtocol.removeRequestHandler(for: url)
            }
            session.invalidateAndCancel()
        }

        for url in urls {
            let completionReceived = expectation(description: "request completed for \(url)")
            GasServiceURLProtocol.setRequestHandler(for: url) { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (
                    try Self.httpResponse(for: request, statusCode: 200),
                    Data(#"{"jsonrpc":"2.0","id":1,"result":"0x64"}"#.utf8)
                )
            }

            EthereumRPC(
                urlSession: session,
                authorizationProvider: authorizationProvider
            ).fetchGasPrice(endpoint: endpoint(url)) { result in
                if case .failure(let error) = result {
                    XCTFail("Unexpected failure: \(error)")
                }
                completionReceived.fulfill()
            }
            wait(for: [completionReceived], timeout: 2)
        }

        XCTAssertEqual(authorizationProvider.authorizationCallCount, 0)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 0)
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

        EthereumRPC(urlSession: session).fetchGasPrice(
            endpoint: endpoint(errorRPCURL)
        ) { result in
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
        endpoint: EthereumRPCEndpoint? = nil,
        description: String = "gas estimate",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GasService.Estimate {
        let completed = expectation(description: description)
        completed.assertForOverFulfill = true
        var receivedEstimate = GasService.Estimate(info: nil, nextBaseFee: nil)

        service.fetchEstimate(
            endpoint: endpoint ?? self.endpoint(rpcURL)
        ) { estimate in
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

        EthereumRPC(urlSession: session).fetchGasPrice(
            endpoint: endpoint(transientRPCURL)
        ) { result in
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
            endpoint: endpoint(rpcURL),
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

    private func assertSecond401IsTerminalAfterReplacementRecoveryFailure(
        _ firstReplacement: Result<String?, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let requestCount = LockedCounter()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "second unauthorized response returned"
        )
        completionReceived.assertForOverFulfill = true
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [
                    .success("rejected-token"),
                    .success("newer-token"),
                ],
                replacements: [
                    firstReplacement,
                    .success("unexpected-third-token"),
                ]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            let attempt = requestCount.increment()
            let expectedAuthorization: String
            switch attempt {
            case 1:
                expectedAuthorization = "Bearer rejected-token"
            case 2:
                expectedAuthorization = "Bearer newer-token"
            default:
                expectedAuthorization = "Bearer unexpected-third-token"
            }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                expectedAuthorization,
                file: file,
                line: line
            )
            guard attempt <= 2 else {
                return (
                    try Self.httpResponse(for: request, statusCode: 200),
                    Data(
                        #"{"jsonrpc":"2.0","id":1,"result":"0x64"}"#.utf8
                    )
                )
            }
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(#"{"error":"unauthorized"}"#.utf8)
            )
        }

        EthereumRPC(
            urlSession: session,
            authorizationProvider: authorizationProvider
        ).fetchGasPrice(
            endpoint: alchemyEndpoint
        ) { result in
            switch result {
            case .success(let gasPrice):
                XCTFail(
                    "Unexpected gas price: \(gasPrice)",
                    file: file,
                    line: line
                )
            case .failure(let error):
                guard case .unknown = error as? EthereumRPCError else {
                    XCTFail(
                        "Unexpected failure: \(error)",
                        file: file,
                        line: line
                    )
                    completionReceived.fulfill()
                    return
                }
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 3)
        XCTAssertEqual(requestCount.value, 2, file: file, line: line)
        XCTAssertEqual(
            authorizationProvider.authorizationCallCount,
            2,
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.replacementCallCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.invalidationCallCount,
            1,
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["newer-token"],
            file: file,
            line: line
        )
        XCTAssertEqual(
            authorizationProvider.invalidationURLs.map(\.absoluteString),
            [alchemyRPCURL],
            file: file,
            line: line
        )
    }

    private func makeRPCSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GasServiceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeHangingRPCSession(
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) -> URLSession {
        HangingGasServiceURLProtocol.configure(
            onStart: onStart,
            onStop: onStop
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingGasServiceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeNetwork(chainID: Int) -> EthereumNetwork {
        EthereumNetwork(
            chainId: chainID,
            name: "Test",
            symbol: "ETH",
            rpcEndpoint: endpoint(rpcURL),
            isTestnet: false,
            mightShowPrice: false,
            explorer: nil
        )
    }

    private func assertSinglePreparationFailure(
        using rpc: EthereumPreparationRPCStub,
        transaction: Transaction,
        expectedFailure: TransactionPreparationFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let firstFailure = expectation(description: "preparation failed")
        let additionalFailure = expectation(
            description: "preparation did not fail more than once"
        )
        additionalFailure.isInverted = true
        var failureCount = 0

        Ethereum(rpc: rpc).prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: makeNetwork(chainID: EthereumNetwork.ethMainnetChainId),
            onUpdate: { _ in },
            completion: { result in
                guard case .failure(let failure) = result else {
                    XCTFail(
                        "Unexpected preparation success",
                        file: file,
                        line: line
                    )
                    return
                }
                XCTAssertTrue(
                    Thread.isMainThread,
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    failure,
                    expectedFailure,
                    file: file,
                    line: line
                )
                failureCount += 1
                if failureCount == 1 {
                    firstFailure.fulfill()
                } else {
                    additionalFailure.fulfill()
                }
            }
        )

        wait(for: [firstFailure, additionalFailure], timeout: 0.2)
        XCTAssertEqual(failureCount, 1, file: file, line: line)
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
        let endpoint: EthereumRPCEndpoint
        let blockCount: UInt
        let rewardPercentiles: [Double]

        var rpcURL: String { return endpoint.url.absoluteString }
        var allowsAlchemyAuthorization: Bool {
            return endpoint.allowsAlchemyAuthorization
        }
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
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        rewardPercentiles: [Double],
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        feeHistoryCalls.append(FeeHistoryCall(
            endpoint: endpoint,
            blockCount: blockCount,
            rewardPercentiles: rewardPercentiles
        ))
        for _ in 0..<feeHistoryCompletionCount {
            completion(feeHistoryResult)
        }
    }

}

private final class EthereumPreparationRPCStub: EthereumRPCClient {

    private let nonceResult: Result<String, Swift.Error>
    private let gasPriceResult: Result<String, Swift.Error>
    private var estimateGasResults: [Result<String, Swift.Error>]
    private let nonceDelay: TimeInterval
    private let gasPriceDelay: TimeInterval
    private let nonceCompletionCount: Int
    private let gasPriceCompletionCount: Int
    private let defersEstimateGasCompletions: Bool
    private var pendingEstimateGasCompletions = [() -> Void]()

    private(set) var nonceCallCount = 0
    private(set) var gasPriceCallCount = 0
    private(set) var estimateGasCallCount = 0
    var onEstimateGasCall: (() -> Void)?

    init(
        nonceResult: Result<String, Swift.Error> = .success("0x1"),
        gasPriceResult: Result<String, Swift.Error> = .success("0x64"),
        estimateGasResults: [Result<String, Swift.Error>] = [
            .success("0x5208"),
            .success("0x5208")
        ],
        nonceDelay: TimeInterval = 0,
        gasPriceDelay: TimeInterval = 0,
        nonceCompletionCount: Int = 1,
        gasPriceCompletionCount: Int = 1,
        defersEstimateGasCompletions: Bool = false
    ) {
        self.nonceResult = nonceResult
        self.gasPriceResult = gasPriceResult
        self.estimateGasResults = estimateGasResults
        self.nonceDelay = nonceDelay
        self.gasPriceDelay = gasPriceDelay
        self.nonceCompletionCount = nonceCompletionCount
        self.gasPriceCompletionCount = gasPriceCompletionCount
        self.defersEstimateGasCompletions =
            defersEstimateGasCompletions
    }

    func fetchGasPrice(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        gasPriceCallCount += 1
        deliver(
            gasPriceResult,
            count: gasPriceCompletionCount,
            after: gasPriceDelay,
            completion: completion
        )
    }

    func getBalance(
        endpoint: EthereumRPCEndpoint,
        for address: String,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        completion(.failure(StubError.expected))
    }

    func fetchNonce(
        endpoint: EthereumRPCEndpoint,
        for address: String,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        nonceCallCount += 1
        deliver(
            nonceResult,
            count: nonceCompletionCount,
            after: nonceDelay,
            completion: completion
        )
    }

    func estimateGas(
        endpoint: EthereumRPCEndpoint,
        transaction: Transaction,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        estimateGasCallCount += 1
        onEstimateGasCall?()
        guard !estimateGasResults.isEmpty else {
            completion(.failure(StubError.expected))
            return
        }
        let result = estimateGasResults.removeFirst()
        if defersEstimateGasCompletions {
            pendingEstimateGasCompletions.append {
                completion(result)
            }
        } else {
            completion(result)
        }
    }

    func sendRawTransaction(
        endpoint: EthereumRPCEndpoint,
        signedTxData: String,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        completion(.failure(StubError.expected))
    }

    func completeNextEstimateGas() {
        guard !pendingEstimateGasCompletions.isEmpty else { return }
        pendingEstimateGasCompletions.removeFirst()()
    }

    private func deliver(
        _ result: Result<String, Swift.Error>,
        count: Int,
        after delay: TimeInterval,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        let deliverResult = {
            for _ in 0..<count {
                completion(result)
            }
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: deliverResult
            )
        } else {
            deliverResult()
        }
    }
}

private final class EthereumAuthorizationProviderStub:
    Big_Wallet.AlchemyAuthorizationProviding,
    @unchecked Sendable {

    private let lock = NSLock()
    private let token: String?
    private let replacementToken: String?
    private var storedAuthorizationCallCount = 0
    private var storedReplacementCallCount = 0
    private var storedInvalidatedTokens = [String]()
    private var storedInvalidationURLs = [URL]()

    init(token: String? = nil, replacementToken: String? = nil) {
        self.token = token
        self.replacementToken = replacementToken
    }

    var authorizationCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedAuthorizationCallCount
    }

    var replacementCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReplacementCallCount
    }

    var invalidationCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidatedTokens.count
    }

    var invalidatedTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidatedTokens
    }

    var invalidationURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidationURLs
    }

    func authorization(for url: URL) async throws -> Big_Wallet.AlchemyAuthorization? {
        let token = recordAuthorizationCall(for: url)
        return token.map { Big_Wallet.AlchemyAuthorization(token: $0) }
    }

    func replacementAuthorization(
        afterUnauthorized rejected: Big_Wallet.AlchemyAuthorization,
        for url: URL
    ) async throws -> Big_Wallet.AlchemyAuthorization? {
        let token = recordReplacementCall(for: url)
        return token.map { Big_Wallet.AlchemyAuthorization(token: $0) }
    }

    func invalidateAuthorization(
        afterUnauthorized rejected: Big_Wallet.AlchemyAuthorization,
        for url: URL
    ) async {
        recordInvalidation(token: rejected.token, url: url)
    }

    private func recordAuthorizationCall(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        storedAuthorizationCallCount += 1
        return Big_Wallet.AlchemyJWTProvider.isAlchemyRPCURL(url)
            ? token
            : nil
    }

    private func recordReplacementCall(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        storedReplacementCallCount += 1
        return Big_Wallet.AlchemyJWTProvider.isAlchemyRPCURL(url)
            ? replacementToken
            : nil
    }

    private func recordInvalidation(token: String, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storedInvalidatedTokens.append(token)
        storedInvalidationURLs.append(url)
    }

}

private final class SequencedEthereumAuthorizationProviderStub:
    Big_Wallet.AlchemyAuthorizationProviding,
    @unchecked Sendable {

    private let lock = NSLock()
    private var authorizationResults: [Result<String?, Error>]
    private var replacementResults: [Result<String?, Error>]
    private var storedAuthorizationCallCount = 0
    private var storedReplacementCallCount = 0
    private var storedInvalidatedTokens = [String]()
    private var storedInvalidationURLs = [URL]()

    init(
        authorizations: [Result<String?, Error>],
        replacements: [Result<String?, Error>] = []
    ) {
        self.authorizationResults = authorizations
        self.replacementResults = replacements
    }

    var authorizationCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedAuthorizationCallCount
    }

    var replacementCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReplacementCallCount
    }

    var invalidationCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidatedTokens.count
    }

    var invalidatedTokens: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidatedTokens
    }

    var invalidationURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedInvalidationURLs
    }

    func authorization(
        for url: URL
    ) async throws -> Big_Wallet.AlchemyAuthorization? {
        let result = nextAuthorizationResult()
        return try result.get().map {
            Big_Wallet.AlchemyAuthorization(token: $0)
        }
    }

    func replacementAuthorization(
        afterUnauthorized rejected: Big_Wallet.AlchemyAuthorization,
        for url: URL
    ) async throws -> Big_Wallet.AlchemyAuthorization? {
        let result = nextReplacementResult()
        return try result.get().map {
            Big_Wallet.AlchemyAuthorization(token: $0)
        }
    }

    func invalidateAuthorization(
        afterUnauthorized rejected: Big_Wallet.AlchemyAuthorization,
        for url: URL
    ) async {
        recordInvalidation(token: rejected.token, url: url)
    }

    private func recordInvalidation(token: String, url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storedInvalidatedTokens.append(token)
        storedInvalidationURLs.append(url)
    }

    private func nextAuthorizationResult() -> Result<String?, Error> {
        lock.lock()
        defer { lock.unlock() }
        storedAuthorizationCallCount += 1
        return authorizationResults.isEmpty
            ? .success(nil)
            : authorizationResults.removeFirst()
    }

    private func nextReplacementResult() -> Result<String?, Error> {
        lock.lock()
        defer { lock.unlock() }
        storedReplacementCallCount += 1
        return replacementResults.isEmpty
            ? .success(nil)
            : replacementResults.removeFirst()
    }

}

private final class GasServiceURLProtocol: URLProtocol {

    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)
    typealias ResponseErrorHandler = (HTTPURLResponse) -> Error?

    private static let requestHandlersLock = NSLock()
    private static var requestHandlers = [String: RequestHandler]()
    private static var responseErrorHandlers =
        [String: ResponseErrorHandler]()

    static func setRequestHandler(for url: String, handler: @escaping RequestHandler) {
        requestHandlersLock.lock()
        requestHandlers[url] = handler
        requestHandlersLock.unlock()
    }

    static func removeRequestHandler(for url: String) {
        requestHandlersLock.lock()
        requestHandlers.removeValue(forKey: url)
        responseErrorHandlers.removeValue(forKey: url)
        requestHandlersLock.unlock()
    }

    static func setResponseErrorHandler(
        for url: String,
        handler: @escaping ResponseErrorHandler
    ) {
        requestHandlersLock.lock()
        responseErrorHandlers[url] = handler
        requestHandlersLock.unlock()
    }

    private static func requestHandler(for request: URLRequest) -> RequestHandler? {
        guard let url = request.url?.absoluteString else { return nil }
        requestHandlersLock.lock()
        defer { requestHandlersLock.unlock() }
        return requestHandlers[url]
    }

    private static func responseError(
        for request: URLRequest,
        response: HTTPURLResponse
    ) -> Error? {
        guard let url = request.url?.absoluteString else { return nil }
        requestHandlersLock.lock()
        defer { requestHandlersLock.unlock() }
        return responseErrorHandlers[url]?(response)
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
            if let error = Self.responseError(
                for: request,
                response: response
            ) {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class HangingGasServiceURLProtocol: URLProtocol {

    private static let lock = NSLock()
    private static var onStart: (() -> Void)?
    private static var onStop: (() -> Void)?
    private static var storedRequestCount = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    static func configure(
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        lock.lock()
        self.onStart = onStart
        self.onStop = onStop
        storedRequestCount = 0
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        onStart = nil
        onStop = nil
        storedRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequestCount += 1
        let onStart = Self.onStart
        Self.lock.unlock()
        onStart?()
    }

    override func stopLoading() {
        Self.lock.lock()
        let onStop = Self.onStop
        Self.lock.unlock()
        onStop?()
    }

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

private final class LockedDataRecorder {

    private let lock = NSLock()
    private var storedValues = [Data]()

    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        storedValues.append(value)
    }
}

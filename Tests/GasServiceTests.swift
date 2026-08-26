// ∅ 2026 lil org

import XCTest
@testable import Big_Wallet

final class GasServiceTests: XCTestCase {

    private let rpcURL = "https://rpc.example"
    private let alchemyRPCURL = "https://eth-mainnet.g.alchemy.com/v2"
    private let fetchedInfo = GasService.Info(
        recommendedPriorityFee: 200,
        highPriorityFee: 300
    )

    private var alchemyEndpoint: EthereumRPCEndpoint {
        return .catalog(
            URL(string: alchemyRPCURL)!,
            alchemyNetwork: "eth-mainnet"
        )
    }

    private func endpoint(_ value: String) -> EthereumRPCEndpoint {
        return .unauthenticated(URL(string: value)!)
    }

    private func fullBaseFees(
        current: String,
        next: String
    ) -> [String] {
        Array(repeating: current, count: 10) + [next]
    }

    private func fullRewards(_ row: [String]) -> [[String]] {
        Array(repeating: row, count: 10)
    }

    private func curveValues(_ info: GasService.Info?) -> [BigUInt]? {
        guard let info else { return nil }
        return [
            info.minimumSliderPriorityFee,
            info.recommendedPriorityFee,
            info.highPriorityFee,
            info.maximumSliderPriorityFee,
        ]
    }

    func testFetchEstimateRequestsExpectedHistoryAndUsesUpperMedianWithNextBaseFee() {
        let first = ["0xa", "0x1e"]
        let second = ["0xd", "0x21"]
        let third = ["0xb", "0x1f"]
        let fourth = ["0xc", "0x20"]
        let history = EthereumFeeHistory(
            baseFeePerGas:
                Array(repeating: "0xffff", count: 9)
                    + ["0x3", "0x64"],
            reward: [
                first,
                second,
                third,
                fourth,
                first,
                second,
                third,
                fourth,
                first,
                second,
            ]
        )
        let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertEqual(rpc.feeHistoryCalls.count, 1)
        XCTAssertEqual(rpc.feeHistoryCalls.first?.rpcURL, rpcURL)
        XCTAssertEqual(rpc.feeHistoryCalls.first?.blockCount, 10)
        XCTAssertEqual(rpc.feeHistoryCalls.first?.newestBlock, "0x1")
        XCTAssertEqual(rpc.feeHistoryCalls.first?.rewardPercentiles, [50, 95])
        XCTAssertEqual(rpc.feeHistoryCalls.first?.allowsAlchemyAuthorization, false)
        XCTAssertEqual(estimate.nextBaseFee, 100)
        XCTAssertEqual(estimate.currentBaseFee, 3)
        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertEqual(
            estimate.info,
            GasService.Info(
                recommendedPriorityFee: 12,
                highPriorityFee: 32
            )
        )
        XCTAssertEqual(curveValues(estimate.info), [6, 12, 32, 64])
    }

    func testFetchEstimatePropagatesTrustedAlchemyAuthorization() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0x1", "0x64"],
            reward: [["0x1", "0x2"]]
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
            baseFeePerGas: fullBaseFees(
                current: "0x3",
                next: "0x64"
            ),
            reward: [
                ["0x1", "0x2"],
                ["0x1", "not-hex"],
                ["0x5", "0x6"],
                ["0x1", "0x2"],
                ["0x1", "0x2"],
                ["0x1", "0x2"],
                ["0x1", "0x2"],
                ["0x1", "0x2"],
                ["0x1", "0x2"],
                ["0x1", "0x2"],
            ]
        )
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(history),
            maxPriorityFeeResult: .success("0x0")
        )

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertEqual(curveValues(estimate.info), [1, 1, 1, 2])
        XCTAssertEqual(estimate.nextBaseFee, 100)
    }

    func testFeeHistoryAcceptsEqualPercentilesWithoutFallback() {
        let history = EthereumFeeHistory(
            baseFeePerGas: fullBaseFees(
                current: "0x1",
                next: "0x65"
            ),
            reward: fullRewards(["0x64", "0x64"])
        )
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(history),
            maxPriorityFeeResult: .success("0x0")
        )

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertEqual(curveValues(estimate.info), [50, 100, 100, 200])
        XCTAssertEqual(estimate.nextBaseFee, 101)
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 0)

        guard let info = estimate.info else {
            return XCTFail("Expected an editable equal-percentile curve")
        }
        let fixtures: [(Double, BigUInt)] = [
            (0, 50),
            (50, 75),
            (100, 100),
            (150, 150),
            (200, 200),
        ]
        for (position, expectedFee) in fixtures {
            XCTAssertEqual(
                Transaction.priorityFee(
                    atSpeed: position,
                    inRelationTo: info
                ),
                expectedFee
            )
        }
    }

    func testGnosisIncidentZeroRewardsProduceOneWeiTipAnd613WeiCap() {
        let history = EthereumFeeHistory(
            baseFeePerGas: fullBaseFees(
                current: "0x132",
                next: "0x132"
            ),
            reward: fullRewards(["0x0", "0x0"])
        )
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(history),
            maxPriorityFeeResult: .success("0x0")
        )

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertEqual(estimate.nextBaseFee, 306)
        XCTAssertEqual(estimate.info?.recommendedPriorityFee, 1)
        XCTAssertEqual(
            estimate.recommendedEIP1559Fee,
            .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: 613)
        )
    }

    func testInvalidFeeRewardsRetainBaseAndUsePositiveFallback() {
        let histories: [(String, EthereumFeeHistory)] = [
            (
                "malformed row",
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x1",
                        next: "0x64"
                    ),
                    reward: [["0x1"]]
                        + Array(
                            fullRewards(["0x1", "0x2"])
                                .dropLast()
                        )
                )
            ),
            (
                "descending row",
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x1",
                        next: "0x64"
                    ),
                    reward: [["0x3", "0x2"]]
                        + Array(
                            fullRewards(["0x1", "0x2"])
                                .dropLast()
                        )
                )
            ),
            (
                "invalid hex",
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x1",
                        next: "0x64"
                    ),
                    reward: [["0x1", "invalid"]]
                        + Array(
                            fullRewards(["0x1", "0x2"])
                                .dropLast()
                        )
                )
            ),
            (
                "missing rewards",
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x1",
                        next: "0x64"
                    ),
                    reward: nil
                )
            ),
        ]

        for (name, history) in histories {
            let rpc = FakeEthereumRPCClient(
                feeHistoryResult: .success(history),
                maxPriorityFeeResult: .success("0x0")
            )

            let estimate = fetchEstimate(using: GasService(rpc: rpc), description: name)

            XCTAssertEqual(
                curveValues(estimate.info),
                [1, 1, 1, 2],
                name
            )
            XCTAssertEqual(
                estimate.nextBaseFee,
                BigUInt(hexString: history.baseFeePerGas.last ?? ""),
                name
            )
            XCTAssertEqual(rpc.feeHistoryCalls.count, 1, name)
            XCTAssertEqual(rpc.maxPriorityFeeCallCount, 1, name)
        }
    }

    func testPriorityDiscoveryFailureDoesNotInventOneWeiSuggestion() {
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x64",
                        next: "0x6e"
                    ),
                    reward: nil
                )
            )
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "priority discovery failure"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertEqual(estimate.currentBaseFee, 100)
        XCTAssertEqual(estimate.nextBaseFee, 110)
        XCTAssertNil(estimate.info)
        XCTAssertNil(estimate.gasPrice)
        XCTAssertNil(estimate.recommendedEIP1559Fee)
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
    }

    func testValidGasPriceAtOrBelowBaseProducesRealOneWeiFallback() {
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: ["0x64", "0x6e"],
                    reward: nil
                )
            ),
            gasPriceResult: .success("0x64")
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "gas-price priority fallback"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertEqual(estimate.gasPrice, 100)
        XCTAssertEqual(curveValues(estimate.info), [1, 1, 1, 2])
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
    }

    func testGasPriceFallbackSubtractsCurrentBaseWhenNextBaseRises() {
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: ["0x64", "0x6e"],
                    reward: nil
                )
            ),
            gasPriceResult: .success("0x66")
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "rising-base gas-price fallback"
        )

        XCTAssertEqual(estimate.currentBaseFee, 100)
        XCTAssertEqual(estimate.nextBaseFee, 110)
        XCTAssertEqual(curveValues(estimate.info), [1, 2, 2, 4])
        XCTAssertEqual(
            estimate.recommendedEIP1559Fee,
            .eip1559(maxPriorityFeePerGas: 2, maxFeePerGas: 222)
        )
    }

    func testGasPriceFallbackSubtractsCurrentBaseWhenNextBaseFalls() {
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: ["0x64", "0x32"],
                    reward: nil
                )
            ),
            gasPriceResult: .success("0x66")
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "falling-base gas-price fallback"
        )

        XCTAssertEqual(estimate.currentBaseFee, 100)
        XCTAssertEqual(estimate.nextBaseFee, 50)
        XCTAssertEqual(curveValues(estimate.info), [1, 2, 2, 4])
        XCTAssertEqual(
            estimate.recommendedEIP1559Fee,
            .eip1559(maxPriorityFeePerGas: 2, maxFeePerGas: 102)
        )
    }

    func testUInt256MaximumAdoptedSuggestionIsCappedToAbsurdityFloor() {
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let floor = BigUInt(1_000_000_000_000)
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: ["0x0", "0x0"],
                    reward: nil
                )
            ),
            maxPriorityFeeResult: .success(
                maximum.toHexString(withPrefix: true)
            ),
            gasPriceResult: .success(
                maximum.toHexString(withPrefix: true)
            )
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "overflowing priority suggestion"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertNil(estimate.gasPrice)
        XCTAssertEqual(estimate.info?.recommendedPriorityFee, floor)
        XCTAssertEqual(
            estimate.recommendedEIP1559Fee,
            .eip1559(
                maxPriorityFeePerGas: floor,
                maxFeePerGas: floor
            )
        )
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
    }

    func testAdoptedPriorityFeeSuggestionIsCapped() {
        let gwei = BigUInt(1_000_000_000)
        let absurdTip = BigUInt(2_000_000) * gwei

        func estimate(
            currentBaseFee: BigUInt,
            maxPriorityFeeResult: Result<String, Error>,
            gasPriceResult: Result<String, Error> =
                .failure(StubError.expected),
            description: String
        ) -> GasService.Estimate {
            let baseFeeHex = currentBaseFee.toHexString(withPrefix: true)
            let rpc = FakeEthereumRPCClient(
                feeHistoryResult: .success(
                    EthereumFeeHistory(
                        baseFeePerGas: fullBaseFees(
                            current: baseFeeHex,
                            next: baseFeeHex
                        ),
                        reward: nil
                    )
                ),
                maxPriorityFeeResult: maxPriorityFeeResult,
                gasPriceResult: gasPriceResult
            )
            return fetchEstimate(
                using: GasService(rpc: rpc),
                description: description
            )
        }

        let flooredEstimate = estimate(
            currentBaseFee: BigUInt(100),
            maxPriorityFeeResult: .success(
                absurdTip.toHexString(withPrefix: true)
            ),
            description: "floored absurd suggestion"
        )
        XCTAssertEqual(
            flooredEstimate.info?.recommendedPriorityFee,
            BigUInt(1_000) * gwei
        )
        XCTAssertEqual(
            curveValues(flooredEstimate.info),
            [
                BigUInt(500) * gwei,
                BigUInt(1_000) * gwei,
                BigUInt(1_000) * gwei,
                BigUInt(2_000) * gwei,
            ]
        )

        let largeBaseEstimate = estimate(
            currentBaseFee: BigUInt(100) * gwei,
            maxPriorityFeeResult: .success(
                absurdTip.toHexString(withPrefix: true)
            ),
            description: "base-relative cap"
        )
        XCTAssertEqual(
            largeBaseEstimate.info?.recommendedPriorityFee,
            BigUInt(1_600) * gwei
        )

        let modestEstimate = estimate(
            currentBaseFee: BigUInt(100),
            maxPriorityFeeResult: .success("0x2"),
            description: "modest suggestion"
        )
        XCTAssertEqual(curveValues(modestEstimate.info), [1, 2, 2, 4])

        let fallbackGasPrice = absurdTip + BigUInt(100)
        let fallbackEstimate = estimate(
            currentBaseFee: BigUInt(100),
            maxPriorityFeeResult: .failure(StubError.expected),
            gasPriceResult: .success(
                fallbackGasPrice.toHexString(withPrefix: true)
            ),
            description: "capped gas-price fallback"
        )
        XCTAssertEqual(
            fallbackEstimate.info?.recommendedPriorityFee,
            BigUInt(1_000) * gwei
        )
        XCTAssertEqual(fallbackEstimate.gasPrice, fallbackGasPrice)

        let polygonEstimate = estimate(
            currentBaseFee: BigUInt(30) * gwei,
            maxPriorityFeeResult: .success(
                (BigUInt(500) * gwei).toHexString(withPrefix: true)
            ),
            description: "polygon-shaped suggestion"
        )
        XCTAssertEqual(
            polygonEstimate.info?.recommendedPriorityFee,
            BigUInt(500) * gwei
        )
    }

    func testShortFeeHistoryUsesAvailableBlocksAndRewardRows() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0x63", "0x64", "0x6e"],
            reward: [
                ["0x1", "0x4"],
                ["0x2", "0x5"],
            ]
        )
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(history),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x64")
                )
            )
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "short fee history"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertEqual(estimate.currentBaseFee, 100)
        XCTAssertEqual(estimate.nextBaseFee, 110)
        XCTAssertEqual(curveValues(estimate.info), [1, 2, 5, 10])
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
    }

    func testGenesisFeeHistoryFallsBackFromMissingRewards() {
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: ["0x0", "0x1"],
                    reward: nil
                )
            ),
            maxPriorityFeeResult: .success("0x0")
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "genesis fee history"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertEqual(estimate.currentBaseFee, 0)
        XCTAssertEqual(estimate.nextBaseFee, 1)
        XCTAssertEqual(estimate.info?.recommendedPriorityFee, 1)
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
    }

    func testFeeHistoryRejectsTooFewOrTooManyBaseFees() {
        let fixtures = [
            EthereumFeeHistory(
                baseFeePerGas: ["0x1"],
                reward: nil
            ),
            EthereumFeeHistory(
                baseFeePerGas: Array(repeating: "0x1", count: 12),
                reward: Array(
                    repeating: ["0x1", "0x2"],
                    count: 11
                )
            ),
        ]

        for (index, history) in fixtures.enumerated() {
            let rpc = FakeEthereumRPCClient(
                feeHistoryResult: .success(history),
                latestBlockResult: .success(
                    EthereumLatestBlock(
                        number: "0x1",
                        baseFeeField: .encoded("0x1")
                    )
                )
            )
            let estimate = fetchEstimate(
                using: GasService(rpc: rpc),
                description: "invalid fee count \(index)"
            )

            XCTAssertEqual(estimate.support, .unknown)
            XCTAssertNil(estimate.info)
            XCTAssertEqual(rpc.maxPriorityFeeCallCount, 0)
        }
    }

    func testShortFeeHistoryStillRequiresLatestBlockAnchor() {
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: ["0x63", "0x64", "0x6e"],
                    reward: [
                        ["0x1", "0x4"],
                        ["0x2", "0x5"],
                    ]
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x65")
                )
            )
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "short history anchor mismatch"
        )

        XCTAssertEqual(estimate.support, .unknown)
        XCTAssertEqual(estimate.currentBaseFee, 101)
        XCTAssertNil(estimate.info)
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 0)
    }

    func testInvalidNextBaseFeeRemainsUnknownAndUsesLatestBlockFallback() {
        let history = EthereumFeeHistory(
            baseFeePerGas: ["0x1", "invalid"],
            reward: [["0x1", "0x2"]]
        )
        let rpc = FakeEthereumRPCClient(feeHistoryResult: .success(history))

        let estimate = fetchEstimate(using: GasService(rpc: rpc))

        XCTAssertEqual(
            estimate,
            GasService.Estimate(
                info: nil,
                nextBaseFee: 1,
                currentBaseFee: 1,
                support: .unknown
            )
        )
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

    func testRelativeCurveUsesHalfAndDoubleReference() {
        XCTAssertEqual(
            curveValues(GasService.Info.relative(to: 100)),
            [50, 100, 100, 200]
        )
        XCTAssertEqual(
            curveValues(GasService.Info.relative(to: 101)),
            [50, 101, 101, 202]
        )
    }

    func testRelativeCurveHandlesTinyReferences() {
        XCTAssertEqual(curveValues(GasService.Info.relative(to: 1)), [1, 1, 1, 2])
        XCTAssertEqual(curveValues(GasService.Info.relative(to: 2)), [1, 2, 2, 4])
    }

    func testRelativeCurveRejectsZeroAndSaturatesAtUInt256Maximum() {
        XCTAssertNil(GasService.Info.relative(to: 0))
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let expectedMinimum = maximum.quotientAndRemainder(
            dividingBy: 2
        ).quotient
        XCTAssertEqual(
            curveValues(GasService.Info.relative(to: maximum)),
            [expectedMinimum, maximum, maximum, maximum]
        )
        XCTAssertNil(GasService.Info.relative(to: maximum + BigUInt(1)))
    }

    func testSpeedPriorityFeeReportsKnownZeroForLegacyTransaction() {
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .legacy(gasPrice: 100),
            currentBaseFeePerGas: 100
        )

        XCTAssertEqual(
            GasSpeedConfiguration().speedPriorityFeePerGas(
                for: transaction
            ),
            0
        )
    }

    func testGasSpeedConfigurationKeepsRPCInfoWhenItArrivesFirst() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertFalse(configuration.installTransactionFallback(feePerGas: 100))
        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertFalse(configuration.didUserSetFee)
    }

    func testGasSpeedConfigurationReplacesTransactionFallbackBeforeInteraction() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        XCTAssertEqual(curveValues(configuration.info), [50, 100, 100, 200])
        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertEqual(configuration.info, fetchedInfo)
    }

    func testGasSpeedConfigurationFreezesCurveWithoutCommittingGasPrice() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        configuration.markGasSliderInteraction()

        XCTAssertFalse(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertFalse(configuration.installTransactionFallback(feePerGas: 200))
        XCTAssertEqual(curveValues(configuration.info), [50, 100, 100, 200])
        XCTAssertFalse(configuration.didUserSetFee)
    }

    func testGasSpeedConfigurationDoesNotClampPriorityFallbackToBaseFee() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        XCTAssertFalse(configuration.applyFetchedEstimate(.init(info: nil, nextBaseFee: 90)))
        XCTAssertEqual(curveValues(configuration.info), [50, 100, 100, 200])
        XCTAssertFalse(configuration.didUserSetFee)
    }

    func testNilFetchedCurveClearsLiveCurveWithoutFallbackResurrection() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 100)
            )
        )
        XCTAssertTrue(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
        XCTAssertNil(configuration.info)
        XCTAssertFalse(
            configuration.installTransactionFallback(feePerGas: 200)
        )
        XCTAssertNil(configuration.info)

        XCTAssertTrue(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 120)
            )
        )
        XCTAssertEqual(configuration.info, fetchedInfo)
    }

    func testNilFetchedCurvePreservesIntentionalRelativeFallback() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(
            configuration.installTransactionFallback(feePerGas: 100)
        )
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
        XCTAssertEqual(
            curveValues(configuration.info),
            [50, 100, 100, 200]
        )
        XCTAssertFalse(
            configuration.installTransactionFallback(feePerGas: 200)
        )
        XCTAssertEqual(
            curveValues(configuration.info),
            [50, 100, 100, 200]
        )
    }

    func testFrozenNilFetchedCurvePreservesRelativeFallbackOnRelease() {
        var configuration = GasSpeedConfiguration()
        XCTAssertTrue(
            configuration.installTransactionFallback(feePerGas: 100)
        )
        guard let relativeInfo = configuration.info else {
            return XCTFail("Expected the relative fallback curve")
        }
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 100,
                maxFeePerGas: 300
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        transaction.setFeeForSpeed(
            value: 0,
            inRelationTo: relativeInfo
        )
        configuration.recordSelectedSliderPosition(0, for: transaction)
        XCTAssertEqual(configuration.sliderPosition(for: transaction), 0)
        configuration.markGasSliderInteraction()

        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
        XCTAssertEqual(
            curveValues(configuration.info),
            [50, 100, 100, 200]
        )

        XCTAssertTrue(
            configuration.endGasSliderInteraction(didChangeFee: false)
        )
        XCTAssertEqual(
            curveValues(configuration.info),
            [50, 100, 100, 200]
        )
        XCTAssertFalse(
            configuration.installTransactionFallback(feePerGas: 200)
        )
    }

    func testFrozenNilFetchedCurveClearsLiveCurveOnInteractionEnd() {
        var configuration = GasSpeedConfiguration()
        XCTAssertTrue(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 100)
            )
        )
        configuration.markGasSliderInteraction()

        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
        XCTAssertEqual(configuration.info, fetchedInfo)

        XCTAssertTrue(
            configuration.endGasSliderInteraction(didChangeFee: false)
        )
        XCTAssertNil(configuration.info)
        XCTAssertFalse(
            configuration.installTransactionFallback(feePerGas: 200)
        )
    }

    func testManualGasCommitRecentersRelativeFallback() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        configuration.commitManualFee(.legacy(gasPrice: 140))

        XCTAssertEqual(curveValues(configuration.info), [70, 140, 140, 280])
        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertTrue(configuration.didUserSetFee)
    }

    func testManualLegacyCommitUsesEffectivePriorityForFallbackCurve()
        throws {
        var configuration = GasSpeedConfiguration()
        XCTAssertTrue(
            configuration.installTransactionFallback(feePerGas: 100)
        )

        configuration.commitManualFee(
            .legacy(gasPrice: 140),
            baseFeePerGas: 100
        )

        let info = try XCTUnwrap(configuration.info)
        XCTAssertEqual(curveValues(info), [20, 40, 40, 80])
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .legacy(gasPrice: 140),
            feeSource: .manual,
            currentBaseFeePerGas: 100
        )
        transaction.setFeeForSpeed(
            value: 100,
            inRelationTo: info
        )
        XCTAssertEqual(
            transaction.preparedFee,
            .legacy(gasPrice: 140)
        )
    }

    func testManualLegacyCommitRejectsNonpositiveEffectivePriority() {
        for gasPrice in [BigUInt(100), BigUInt(99)] {
            var configuration = GasSpeedConfiguration()
            XCTAssertTrue(
                configuration.installTransactionFallback(feePerGas: 100)
            )

            configuration.commitManualFee(
                .legacy(gasPrice: gasPrice),
                baseFeePerGas: 100
            )

            XCTAssertNil(configuration.info)
            XCTAssertTrue(configuration.didUserSetFee)
        }
    }

    func testManualFeeCommitUnfreezesAndAppliesPendingLiveCurve() {
        var configuration = GasSpeedConfiguration()
        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        configuration.markGasSliderInteraction()
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 100)
            )
        )

        configuration.commitManualFee(.legacy(gasPrice: 140))

        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertTrue(configuration.didUserSetFee)
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 100)
            )
        )
    }

    func testManualGasCommitPreservesLiveCurve() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        configuration.commitManualFee(.legacy(gasPrice: 1_000))

        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertTrue(configuration.didUserSetFee)
    }

    func testSuggestedFeeCommitClearsOverrideAndAdoptsPendingLiveCurve() {
        var configuration = GasSpeedConfiguration()
        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        configuration.markGasSliderInteraction()
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 100)
            )
        )
        configuration.markGasSliderFeeChange()

        XCTAssertTrue(configuration.commitSuggestedFee())
        XCTAssertFalse(configuration.didUserSetFee)
    }

    func testUnrepresentableManualGasCommitClearsRelativeFallback() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        configuration.commitManualFee(nil)

        XCTAssertNil(configuration.info)
        XCTAssertTrue(configuration.didUserSetFee)
    }

    func testUnrepresentableManualGasCommitPreservesLiveCurve() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        configuration.commitManualFee(nil)

        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertTrue(configuration.didUserSetFee)
    }

    func testNonceOnlyEditLeavesFallbackEligibleForLiveReplacement() {
        var configuration = GasSpeedConfiguration()

        XCTAssertTrue(configuration.installTransactionFallback(feePerGas: 100))
        XCTAssertTrue(configuration.applyFetchedEstimate(.init(info: fetchedInfo, nextBaseFee: 100)))
        XCTAssertEqual(configuration.info, fetchedInfo)
        XCTAssertFalse(configuration.didUserSetFee)
    }

    func testGasSpeedConfigurationRejectsInvalidTransactionGasPrices() {
        var configuration = GasSpeedConfiguration()

        XCTAssertFalse(configuration.installTransactionFallback(feePerGas: 0))
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        XCTAssertFalse(
            configuration.installTransactionFallback(
                feePerGas: maximum + BigUInt(1)
            )
        )
        XCTAssertNil(configuration.info)
    }

    func testGasSpeedConfigurationRepeatedStartsRetainLatestPendingCurve() {
        let firstInfo = GasService.Info(
            recommendedPriorityFee: 20,
            highPriorityFee: 40
        )
        let latestInfo = GasService.Info(
            recommendedPriorityFee: 200,
            highPriorityFee: 400
        )
        var configuration = GasSpeedConfiguration()

        configuration.markGasSliderInteraction()
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: firstInfo, nextBaseFee: 100)
            )
        )
        configuration.markGasSliderInteraction()
        XCTAssertTrue(
            configuration.endGasSliderInteraction(didChangeFee: false)
        )
        XCTAssertEqual(configuration.info, firstInfo)

        configuration.markGasSliderInteraction()
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: latestInfo, nextBaseFee: 120)
            )
        )
        configuration.markGasSliderInteraction()
        XCTAssertTrue(
            configuration.endGasSliderInteraction(didChangeFee: false)
        )
        XCTAssertEqual(configuration.info, latestInfo)
    }

    func testVerifiedUnavailableCanReceiveAndRetainManualFallback() {
        var configuration = GasSpeedConfiguration()

        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 100)
            )
        )
        configuration.commitManualFee(.legacy(gasPrice: 140))
        XCTAssertEqual(
            curveValues(configuration.info),
            [70, 140, 140, 280]
        )
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
        XCTAssertEqual(
            curveValues(configuration.info),
            [70, 140, 140, 280]
        )
        XCTAssertFalse(
            configuration.installTransactionFallback(feePerGas: 200)
        )
    }

    func testGasSpeedConfigurationUnchangedOperationsReturnFalse() {
        var configuration = GasSpeedConfiguration()

        XCTAssertFalse(
            configuration.endGasSliderInteraction(didChangeFee: false)
        )
        XCTAssertFalse(configuration.commitSuggestedFee())
        XCTAssertTrue(
            configuration.installTransactionFallback(feePerGas: 100)
        )
        XCTAssertFalse(
            configuration.installTransactionFallback(feePerGas: 100)
        )
        XCTAssertTrue(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 100)
            )
        )
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: fetchedInfo, nextBaseFee: 100)
            )
        )
        configuration.markGasSliderInteraction()
        XCTAssertFalse(
            configuration.endGasSliderInteraction(didChangeFee: false)
        )
        XCTAssertFalse(configuration.commitSuggestedFee())
        XCTAssertTrue(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
        XCTAssertFalse(
            configuration.applyFetchedEstimate(
                .init(info: nil, nextBaseFee: 110)
            )
        )
    }

    func testAutomaticRecommendationMapsToCenterPosition() {
        let info = GasService.Info(
            recommendedPriorityFee: 1,
            highPriorityFee: 1
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 306)
        )
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 306
        )

        XCTAssertEqual(
            configuration.sliderPosition(for: transaction),
            100,
            accuracy: 0.000_001
        )
    }

    func testSelectedContinuousSliderPositionsArePreserved() {
        let info = GasService.Info(
            recommendedPriorityFee: 200,
            highPriorityFee: 400
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 100)
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 200,
                maxFeePerGas: 400
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        let positions = [0.0, 25, 50, 75, 100, 125, 150, 175, 200]

        for position in positions {
            transaction.setFeeForSpeed(
                value: position,
                inRelationTo: info
            )
            configuration.recordSelectedSliderPosition(
                position,
                for: transaction
            )
            XCTAssertEqual(
                configuration.sliderPosition(for: transaction),
                position,
                accuracy: 0.000_001
            )
        }
    }

    func testRefreshedCurveInvalidatesSelectionAndRederivesPosition() {
        let originalInfo = GasService.Info(
            recommendedPriorityFee: 200,
            highPriorityFee: 400
        )
        let refreshedInfo = GasService.Info(
            recommendedPriorityFee: 300,
            highPriorityFee: 400
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: originalInfo, nextBaseFee: 100)
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 200,
                maxFeePerGas: 400
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        transaction.setFeeForSpeed(value: 50, inRelationTo: originalInfo)
        configuration.recordSelectedSliderPosition(50, for: transaction)

        XCTAssertTrue(
            configuration.applyFetchedEstimate(
                .init(info: refreshedInfo, nextBaseFee: 100)
            )
        )
        XCTAssertEqual(
            configuration.sliderPosition(for: transaction),
            0,
            accuracy: 0.000_001
        )
    }

    func testManualAndDappRecommendedFeesMapToCenterPosition() {
        let info = GasService.Info(
            recommendedPriorityFee: 200,
            highPriorityFee: 400
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 100)
        )

        for source in [TransactionFeeSource.manual, .dapp] {
            let transaction = Transaction(
                from: "0x0",
                to: "0x1",
                value: nil,
                data: "0x",
                preparedFee: .eip1559(
                    maxPriorityFeePerGas: 200,
                    maxFeePerGas: 400
                ),
                feeSource: source,
                currentBaseFeePerGas: 100
            )
            XCTAssertEqual(
                configuration.sliderPosition(for: transaction),
                100,
                accuracy: 0.000_001
            )
        }
    }

    func testMixedProvenanceAutomaticPriorityMapsToCenterPosition() {
        let info = GasService.Info(
            recommendedPriorityFee: 1,
            highPriorityFee: 1
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 306)
        )
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: 613
            ),
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            ),
            feeProvenance: TransactionFeeProvenance(
                maxPriorityFeePerGas: .automatic,
                maxFeePerGas: .dapp
            ),
            currentBaseFeePerGas: 306
        )

        XCTAssertEqual(transaction.feeSource, .dapp)
        XCTAssertEqual(transaction.speedPriorityFeeSource, .automatic)
        XCTAssertEqual(
            configuration.sliderPosition(for: transaction),
            100,
            accuracy: 0.000_001
        )
    }

    func testMixedProvenanceSliderPriorityKeepsSelectedDuplicatePosition() {
        let info = GasService.Info(
            recommendedPriorityFee: 1,
            highPriorityFee: 1
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 306)
        )
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            ),
            feeProvenance: TransactionFeeProvenance(
                maxPriorityFeePerGas: .slider,
                maxFeePerGas: .dapp
            ),
            currentBaseFeePerGas: 306
        )
        configuration.recordSelectedSliderPosition(20, for: transaction)

        XCTAssertEqual(transaction.feeSource, .dapp)
        XCTAssertEqual(transaction.speedPriorityFeeSource, .slider)
        XCTAssertEqual(
            configuration.sliderPosition(for: transaction),
            20,
            accuracy: 0.000_001
        )
    }

    func testSelectedSliderPositionPersistsAcrossIntegerWeiDuplicates() {
        let info = GasService.Info(
            recommendedPriorityFee: 1,
            highPriorityFee: 1
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 306)
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 306
        )
        transaction.setFeeForSpeed(value: 20, inRelationTo: info)
        configuration.recordSelectedSliderPosition(20, for: transaction)

        XCTAssertEqual(
            transaction.currentFeeInRelationTo(info: info),
            100
        )
        XCTAssertEqual(
            configuration.sliderPosition(for: transaction),
            20,
            accuracy: 0.000_001
        )
        configuration.synchronizeSelectedSliderPosition(with: transaction)
        XCTAssertEqual(
            configuration.sliderPosition(for: transaction),
            20,
            accuracy: 0.000_001
        )
    }

    func testAuthoritativePreparedFeeInvalidatesStaleSliderSelection() {
        let info = GasService.Info(
            recommendedPriorityFee: 200,
            highPriorityFee: 300
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 100)
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 200,
                maxFeePerGas: 400
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        transaction.setFeeForSpeed(value: 50, inRelationTo: info)
        configuration.recordSelectedSliderPosition(50, for: transaction)

        let authoritative = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 200,
                maxFeePerGas: 400
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        configuration.synchronizeSelectedSliderPosition(
            with: authoritative
        )

        XCTAssertEqual(
            configuration.sliderPosition(for: authoritative),
            100,
            accuracy: 0.000_001
        )
    }

    func testManualCommitClearsDuplicateWeiSliderSelection() {
        let info = GasService.Info(
            recommendedPriorityFee: 1,
            highPriorityFee: 1
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 306)
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 306
        )
        transaction.setFeeForSpeed(value: 20, inRelationTo: info)
        configuration.recordSelectedSliderPosition(20, for: transaction)
        configuration.commitManualFee(transaction.preparedFee)

        XCTAssertEqual(
            configuration.sliderPosition(for: transaction),
            100
        )
    }

    func testFallbackRecommendationIsAtSliderCenter() throws {
        let info = try XCTUnwrap(GasService.Info.relative(to: 100))
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = String.hex(100)

        XCTAssertEqual(
            transaction.currentFeeInRelationTo(info: info),
            100,
            accuracy: 0.000_001
        )
    }

    func testFallbackCurveRemainsEditableAcrossBothHalves() throws {
        let info = try XCTUnwrap(GasService.Info.relative(to: 100))
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = String.hex(100)
        let fixtures: [(Double, BigUInt)] = [
            (0, 50),
            (50, 75),
            (100, 100),
            (150, 150),
            (200, 200),
        ]

        for (position, expectedFee) in fixtures {
            transaction.setFeeForSpeed(value: position, inRelationTo: info)
            XCTAssertEqual(transaction.gasPriceValue, expectedFee)
        }
    }

    func testGasSliderInterpolationSaturatesAtUInt256Maximum() throws {
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let info = GasService.Info(
            recommendedPriorityFee: maximum - BigUInt(2),
            highPriorityFee: maximum
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: String.hex(1),
            value: nil,
            data: "0x"
        )

        transaction.setFeeForSpeed(value: 0, inRelationTo: info)
        XCTAssertEqual(
            transaction.gasPriceValue,
            (maximum - BigUInt(2)).quotientAndRemainder(
                dividingBy: 2
            ).quotient
        )

        transaction.setFeeForSpeed(value: 100, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceValue, maximum - BigUInt(2))

        transaction.setFeeForSpeed(
            value: Double(100).nextDown,
            inRelationTo: info
        )
        let valueBelowRecommendation = try XCTUnwrap(transaction.gasPriceValue)
        XCTAssertLessThanOrEqual(
            valueBelowRecommendation,
            maximum - BigUInt(2)
        )

        transaction.setFeeForSpeed(value: 200, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceValue, maximum)
    }

    func testGasSliderInterpolationPreservesNormalFlooringAndRejectsInvalidValues() {
        let info = GasService.Info(
            recommendedPriorityFee: 200,
            highPriorityFee: 400
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: String.hex(1),
            value: nil,
            data: "0x"
        )

        transaction.setFeeForSpeed(value: 50, inRelationTo: info)
        XCTAssertEqual(transaction.gasPriceValue, BigUInt(150))

        let validGasPrice = transaction.gasPrice
        for invalidValue in [Double.nan, Double.infinity, -Double.infinity, -1, 201] {
            transaction.setFeeForSpeed(
                value: invalidValue,
                inRelationTo: info
            )
            XCTAssertEqual(transaction.gasPrice, validGasPrice)
        }
    }

    func testSliderPositionClampsFeesOutsideCurve() {
        let info = GasService.Info(
            recommendedPriorityFee: 100,
            highPriorityFee: 200
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: String.hex(49),
            value: nil,
            data: "0x"
        )

        XCTAssertEqual(transaction.currentFeeInRelationTo(info: info), 0)

        transaction.gasPrice = String.hex(401)
        XCTAssertEqual(transaction.currentFeeInRelationTo(info: info), 200)
    }

    func testSliderPositionRoundTripsNondivisibleFeesInBothHalves() {
        let info = GasService.Info(
            recommendedPriorityFee: 11,
            highPriorityFee: 13
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: String.hex(6),
            value: nil,
            data: "0x"
        )

        let lowerPosition = transaction.currentFeeInRelationTo(info: info)
        XCTAssertGreaterThan(lowerPosition, 0)
        XCTAssertLessThan(lowerPosition, 100)
        XCTAssertEqual(
            Transaction.priorityFee(
                atSpeed: lowerPosition,
                inRelationTo: info
            ),
            6
        )

        transaction.gasPrice = String.hex(12)
        let upperPosition = transaction.currentFeeInRelationTo(info: info)
        XCTAssertGreaterThan(upperPosition, 100)
        XCTAssertLessThan(upperPosition, 200)
        XCTAssertEqual(
            Transaction.priorityFee(
                atSpeed: upperPosition,
                inRelationTo: info
            ),
            12
        )
    }

    func testSaturatedSliderEndpointLeavesEIP1559FeeAndPositionUnchanged() {
        let maximum = Transaction.maximumUInt256
        let info = GasService.Info(
            recommendedPriorityFee: maximum - BigUInt(2),
            highPriorityFee: maximum
        )
        var configuration = GasSpeedConfiguration()
        _ = configuration.applyFetchedEstimate(
            .init(info: info, nextBaseFee: 1)
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 3
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 1
        )
        let originalFee = transaction.preparedFee

        transaction.setFeeForSpeed(value: 200, inRelationTo: info)
        configuration.recordSelectedSliderPosition(200, for: transaction)

        XCTAssertEqual(transaction.preparedFee, originalFee)
        XCTAssertEqual(transaction.feeSource, .automatic)
        XCTAssertEqual(configuration.sliderPosition(for: transaction), 0)
    }

    func testType2SpeedSliderMapsPriorityAndDerivesFreshFeeCap() {
        let info = GasService.Info(
            recommendedPriorityFee: 20,
            highPriorityFee: 80
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 20,
                maxFeePerGas: 220
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )

        transaction.setFeeForSpeed(value: 0, inRelationTo: info)
        XCTAssertEqual(
            transaction.preparedFee,
            .eip1559(maxPriorityFeePerGas: 10, maxFeePerGas: 210)
        )
        transaction.setFeeForSpeed(value: 50, inRelationTo: info)
        XCTAssertEqual(
            transaction.preparedFee,
            .eip1559(maxPriorityFeePerGas: 15, maxFeePerGas: 215)
        )
        XCTAssertEqual(
            transaction.currentFeeInRelationTo(info: info),
            50,
            accuracy: 0.000_001
        )
        transaction.setFeeForSpeed(value: 100, inRelationTo: info)
        XCTAssertEqual(
            transaction.preparedFee,
            .eip1559(maxPriorityFeePerGas: 20, maxFeePerGas: 220)
        )
        transaction.setFeeForSpeed(value: 150, inRelationTo: info)
        XCTAssertEqual(
            transaction.preparedFee,
            .eip1559(maxPriorityFeePerGas: 90, maxFeePerGas: 290)
        )
        XCTAssertEqual(
            transaction.currentFeeInRelationTo(info: info),
            150,
            accuracy: 0.000_001
        )
        transaction.setFeeForSpeed(value: 200, inRelationTo: info)
        XCTAssertEqual(
            transaction.preparedFee,
            .eip1559(maxPriorityFeePerGas: 160, maxFeePerGas: 360)
        )
        XCTAssertEqual(
            transaction.currentFeeInRelationTo(info: info),
            200,
            accuracy: 0.000_001
        )
        XCTAssertEqual(transaction.feeSource, .slider)
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
        XCTAssertEqual(transaction.gasPriceValue, largeGasPrice)
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

    func testEIP1559IncidentFeeUsesPositivePriorityAndDoubleBaseHeadroom() throws {
        let fee = try XCTUnwrap(
            PreparedTransactionFee.recommendedEIP1559(
                baseFeePerGas: BigUInt(306),
                maxPriorityFeePerGas: BigUInt(1)
            )
        )

        XCTAssertEqual(
            fee,
            .eip1559(
                maxPriorityFeePerGas: BigUInt(1),
                maxFeePerGas: BigUInt(613)
            )
        )
        XCTAssertEqual(
            fee.effectivePriorityFeePerGas(baseFeePerGas: BigUInt(306)),
            BigUInt(1)
        )
        XCTAssertTrue(fee.hasSufficientEffectivePriorityFee(baseFeePerGas: BigUInt(306)))
    }

    func testEIP1559FeeValidationRejectsInvertedCapAndUInt256Overflow() throws {
        let maximum = try XCTUnwrap(
            BigUInt(hexString: String(repeating: "f", count: 64))
        )
        let overflow = try XCTUnwrap(
            BigUInt(hexString: "1" + String(repeating: "0", count: 64))
        )

        XCTAssertTrue(
            PreparedTransactionFee.eip1559(
                maxPriorityFeePerGas: BigUInt(),
                maxFeePerGas: BigUInt(1)
            ).isStructurallyValid,
            "A zero tip with a covering cap is structurally valid"
        )
        XCTAssertFalse(
            PreparedTransactionFee.eip1559(
                maxPriorityFeePerGas: BigUInt(2),
                maxFeePerGas: BigUInt(1)
            ).isStructurallyValid
        )
        XCTAssertFalse(
            PreparedTransactionFee.eip1559(
                maxPriorityFeePerGas: BigUInt(1),
                maxFeePerGas: overflow
            ).isStructurallyValid
        )
        XCTAssertNil(
            PreparedTransactionFee.recommendedEIP1559(
                baseFeePerGas: maximum,
                maxPriorityFeePerGas: BigUInt(1)
            )
        )
        XCTAssertTrue(
            TransactionFeeIntent.legacy(
                gasPrice: BigUInt()
            ).isStructurallyValid
        )
        XCTAssertTrue(
            TransactionFeeIntent.eip1559(
                maxPriorityFeePerGas: 0,
                maxFeePerGas: 1
            ).isStructurallyValid
        )
        XCTAssertFalse(
            TransactionFeeIntent.eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: 1
            ).isStructurallyValid
        )
    }

    func testEIP1559EffectiveTipRespectsMaxFeeCap() {
        let fee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: BigUInt(20),
            maxFeePerGas: BigUInt(110)
        )

        XCTAssertEqual(
            fee.effectivePriorityFeePerGas(baseFeePerGas: BigUInt(100)),
            BigUInt(10)
        )
        XCTAssertEqual(
            fee.effectiveGasPrice(baseFeePerGas: BigUInt(100)),
            BigUInt(110)
        )
        XCTAssertNil(fee.effectivePriorityFeePerGas(baseFeePerGas: BigUInt(111)))
    }

    func testEIP1559PreparedFeeEditsAreAtomicAndRecordManualSource() {
        let originalFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: BigUInt(2),
            maxFeePerGas: BigUInt(202)
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            nonce: "0x1",
            gas: "0x5208",
            value: nil,
            data: "0x",
            feeIntent: .automatic,
            preparedFee: originalFee,
            feeSource: .automatic,
            currentBaseFeePerGas: BigUInt(100)
        )
        let originalID = transaction.id

        XCTAssertFalse(
            transaction.apply(
                Transaction.Edits(
                    preparedFee: .eip1559(
                        maxPriorityFeePerGas: BigUInt(5),
                        maxFeePerGas: BigUInt(4)
                    )
                )
            )
        )
        XCTAssertEqual(transaction.preparedFee, originalFee)
        XCTAssertEqual(transaction.id, originalID)

        let editedFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: BigUInt(3),
            maxFeePerGas: BigUInt(203)
        )
        XCTAssertTrue(transaction.apply(Transaction.Edits(preparedFee: editedFee)))
        XCTAssertEqual(transaction.preparedFee, editedFee)
        XCTAssertNil(transaction.gasPrice)
        XCTAssertEqual(transaction.feeSource, .manual)
        XCTAssertNotEqual(transaction.id, originalID)
    }

    func testEIP1559EditPreservesUnchangedFieldProvenance() {
        let originalFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 2,
            maxFeePerGas: 202
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: nil
            ),
            preparedFee: originalFee,
            feeProvenance: TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .automatic
            )
        )

        XCTAssertTrue(
            transaction.apply(
                Transaction.Edits(
                    preparedFee: .eip1559(
                        maxPriorityFeePerGas: 2,
                        maxFeePerGas: 250
                    ),
                    source: .manual
                )
            )
        )
        XCTAssertEqual(transaction.feeProvenance.maxPriorityFeePerGas, .dapp)
        XCTAssertEqual(transaction.feeProvenance.maxFeePerGas, .manual)
    }

    func testSuggestedFeeResetCanRestoreExactMixedProvenance() {
        let suggestedFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 2,
            maxFeePerGas: 202
        )
        let suggestedProvenance = TransactionFeeProvenance(
            maxPriorityFeePerGas: .dapp,
            maxFeePerGas: .automatic
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: suggestedFee,
            feeSource: .manual
        )

        XCTAssertTrue(
            transaction.apply(
                Transaction.Edits(
                    preparedFee: suggestedFee,
                    source: .automatic,
                    replacementFeeProvenance: suggestedProvenance
                )
            )
        )
        XCTAssertEqual(transaction.feeProvenance, suggestedProvenance)
    }

    func testPartialDappFeeProvenancePreservesRequestedAndAutomaticFields() {
        let preparedFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: BigUInt(2),
            maxFeePerGas: BigUInt(202)
        )
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: BigUInt(2),
                maxFeePerGas: nil
            ),
            preparedFee: preparedFee,
            feeSource: .dapp
        )

        XCTAssertEqual(transaction.feeProvenance.maxPriorityFeePerGas, .dapp)
        XCTAssertEqual(transaction.feeProvenance.maxFeePerGas, .automatic)
        XCTAssertTrue(transaction.feeProvenance.containsUserControlledValue)
        XCTAssertEqual(transaction.feeSource, .dapp)
    }

    func testAutomaticPreparedFeeInitializerPreservesSliderSource() {
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: 202
            ),
            feeSource: .slider
        )

        XCTAssertEqual(transaction.feeSource, .slider)
        XCTAssertEqual(transaction.feeProvenance.maxPriorityFeePerGas, .slider)
        XCTAssertEqual(transaction.feeProvenance.maxFeePerGas, .slider)
    }

    func testAccessListValidationPreservesStorageKeyOrderAndLeadingZeros() throws {
        let address = "0x" + String(repeating: "11", count: 20)
        let firstKey = "0x" + String(repeating: "00", count: 31) + "01"
        let secondKey = "0x" + String(repeating: "ff", count: 32)
        let entry = try XCTUnwrap(
            EthereumAccessListEntry(
                address: address,
                storageKeys: [firstKey, secondKey]
            )
        )

        XCTAssertEqual(entry.addressHexString, address)
        XCTAssertEqual(entry.storageKeyHexStrings, [firstKey, secondKey])
        XCTAssertNil(
            EthereumAccessListEntry(
                address: "0x" + String(repeating: "11", count: 19),
                storageKeys: []
            )
        )
        XCTAssertNil(
            EthereumAccessListEntry(
                address: address,
                storageKeys: ["0x01"]
            )
        )
        XCTAssertNil(
            EthereumAccessListEntry(
                address: "0X" + String(repeating: "11", count: 20),
                storageKeys: []
            )
        )
        XCTAssertNil(
            EthereumAccessListEntry(
                address: address,
                storageKeys: [String(repeating: "00", count: 32)]
            )
        )
    }

    func testLegacyFeeProductsFailClosedOnUInt256Overflow() {
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: "0x2",
            gas: maximum.toHexString(withPrefix: true),
            value: nil,
            data: "0x"
        )

        XCTAssertNil(transaction.estimatedFeeValue)
        XCTAssertNil(transaction.maximumFeeValue)
        transaction.gasPrice = "0x1"
        XCTAssertEqual(transaction.maximumFeeValue, maximum)
    }

    func testEditorMaximumFeeProductUsesUInt256BoundaryForBothFeeModels() {
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))

        XCTAssertTrue(
            EditTransactionView.maximumNetworkFeeFitsUInt256(
                gasLimit: nil,
                fee: .legacy(gasPrice: maximum)
            )
        )
        for fee in [
            PreparedTransactionFee.legacy(gasPrice: 1),
            .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: 1),
        ] {
            XCTAssertTrue(
                EditTransactionView.maximumNetworkFeeFitsUInt256(
                    gasLimit: maximum,
                    fee: fee
                )
            )
        }
        for fee in [
            PreparedTransactionFee.legacy(gasPrice: 2),
            .eip1559(maxPriorityFeePerGas: 1, maxFeePerGas: 2),
        ] {
            XCTAssertFalse(
                EditTransactionView.maximumNetworkFeeFitsUInt256(
                    gasLimit: maximum,
                    fee: fee
                )
            )
        }
    }

    func testEIP1559ReadinessRequiresCapAtLeastKnownBaseFee() {
        let mainnet = makeNetwork(chainID: EthereumNetwork.ethMainnetChainId)
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            nonce: "0x0",
            gas: String.hex(21_000),
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: BigUInt(2),
                maxFeePerGas: BigUInt(202)
            ),
            feeSource: .automatic
        )

        XCTAssertTrue(transaction.isReadyForApproval(on: mainnet))
        XCTAssertNil(transaction.estimatedFeeValue)
        XCTAssertEqual(transaction.maximumFeeValue, BigUInt(4_242_000))

        transaction.currentBaseFeePerGas = BigUInt(100)
        XCTAssertTrue(transaction.isReadyForApproval(on: mainnet))
        XCTAssertEqual(transaction.estimatedFeeValue, BigUInt(2_142_000))
        XCTAssertEqual(transaction.maximumFeeValue, BigUInt(4_242_000))

        transaction.currentBaseFeePerGas = BigUInt(202)
        XCTAssertTrue(transaction.isReadyForApproval(on: mainnet))
        transaction.currentBaseFeePerGas = BigUInt(203)
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
    }

    func testEIP1559FeeSummaryDisplaysOnlyMaximumFee() throws {
        let chain = makeNetwork(
            chainID: EthereumNetwork.ethMainnetChainId,
            mightShowPrice: true
        )
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gas: String.hex(21_000),
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: BigUInt(1_000_000_000),
                maxFeePerGas: BigUInt(10_000_000_000)
            ),
            currentBaseFeePerGas: BigUInt(1_000_000_000)
        )

        XCTAssertNotEqual(
            transaction.estimatedFeeValue,
            transaction.maximumFeeValue
        )
        let maximumFee = try XCTUnwrap(transaction.maximumFeeValue)
        let lines = transaction.feeSummaryLines(chain: chain, price: 200)
        let expectedPrefix =
            "\(Strings.fee): \(maximumFee.eth(shortest: true)) \(chain.symbol)"

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix(expectedPrefix))
        XCTAssertTrue(lines[0].contains("≈ $"))
    }

    func testEIP1559FeeSummaryDisplaysSingleCalculatingFee() {
        let chain = makeNetwork(chainID: EthereumNetwork.ethMainnetChainId)
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gas: String.hex(21_000),
            value: nil,
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: nil
            )
        )

        XCTAssertEqual(
            transaction.feeSummaryLines(chain: chain, price: nil),
            ["\(Strings.fee): \(Strings.calculating.withEllipsis)"]
        )
    }

    func testLegacyFeeSummaryRemainsUnchanged() {
        let chain = makeNetwork(chainID: EthereumNetwork.ethMainnetChainId)
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: "0x3b9aca00",
            gas: String.hex(21_000),
            value: nil,
            data: "0x"
        )

        XCTAssertEqual(
            transaction.feeSummaryLines(chain: chain, price: nil),
            [
                transaction.feeWithSymbol(chain: chain, price: nil),
                transaction.gasPriceWithLabel(chain: chain),
            ]
        )
    }

    func testLegacyGasPriceCompatibilityMirrorsPreparedFee() {
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: "0x64",
            value: nil,
            data: "0x"
        )

        XCTAssertEqual(transaction.gasPrice, "0x64")
        XCTAssertEqual(transaction.preparedFee, .legacy(gasPrice: BigUInt(100)))
        XCTAssertEqual(transaction.feeIntent, .legacy(gasPrice: BigUInt(100)))

        transaction.preparedFee = .eip1559(
            maxPriorityFeePerGas: BigUInt(1),
            maxFeePerGas: BigUInt(201)
        )
        XCTAssertNil(transaction.gasPrice)

        transaction.gasPrice = "0x65"
        XCTAssertEqual(transaction.preparedFee, .legacy(gasPrice: BigUInt(101)))
        XCTAssertEqual(transaction.gasPrice, "0x65")
    }

    func testCompatibilityFeeSettersTransitionProvenanceAtomically() {
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: "0x64",
            value: nil,
            data: "0x",
            feeSource: .dapp
        )

        transaction.preparedFee = .eip1559(
            maxPriorityFeePerGas: 1,
            maxFeePerGas: 201
        )
        XCTAssertEqual(
            transaction.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .dapp
            )
        )
        XCTAssertEqual(transaction.feeSource, .dapp)

        transaction.gasPrice = "0x65"
        XCTAssertEqual(
            transaction.feeProvenance,
            TransactionFeeProvenance(gasPrice: .dapp)
        )
        XCTAssertEqual(transaction.feeSource, .dapp)
    }

    func testCompatibilityPreparedFeeSetterPreservesMixedProvenance() {
        let provenance = TransactionFeeProvenance(
            gasPrice: .slider,
            maxPriorityFeePerGas: .dapp,
            maxFeePerGas: .automatic
        )
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 201
            ),
            feeProvenance: provenance
        )

        transaction.preparedFee = .eip1559(
            maxPriorityFeePerGas: 2,
            maxFeePerGas: 202
        )

        XCTAssertEqual(
            transaction.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .automatic
            )
        )
    }

    func testCompatibilitySetterCompletesPartialFeeAsAutomatic() {
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            value: nil,
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: nil
            ),
            feeSource: .dapp
        )
        XCTAssertNil(transaction.preparedFee)
        XCTAssertEqual(
            transaction.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp
            )
        )

        transaction.preparedFee = .eip1559(
            maxPriorityFeePerGas: 2,
            maxFeePerGas: 202
        )

        XCTAssertEqual(
            transaction.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .automatic
            )
        )
    }

    func testFeeStatePreservesExactLegacyEncodingAndInvalidRawValue() {
        var exact = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: "0xAB",
            value: nil,
            data: "0x",
            preparedFee: .legacy(gasPrice: 171)
        )

        XCTAssertEqual(exact.preparedFee, .legacy(gasPrice: 171))
        XCTAssertEqual(exact.gasPrice, "0xAB")

        exact.preparedFee = .legacy(gasPrice: 172)
        XCTAssertEqual(
            exact.gasPrice,
            BigUInt(172).toHexString(withPrefix: true)
        )

        let paddedZero = "0x00"
        exact.gasPrice = paddedZero
        XCTAssertEqual(exact.preparedFee, .legacy(gasPrice: 0))
        XCTAssertEqual(exact.gasPrice, paddedZero)
        XCTAssertEqual(
            exact.feeProvenance,
            TransactionFeeProvenance(gasPrice: .dapp)
        )

        let initializedZero = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: paddedZero,
            value: nil,
            data: "0x"
        )
        XCTAssertEqual(initializedZero.preparedFee, .legacy(gasPrice: 0))
        XCTAssertEqual(initializedZero.gasPrice, paddedZero)
        XCTAssertEqual(
            initializedZero.feeIntent,
            .legacy(gasPrice: 0)
        )

        let invalidRaw = "0xzz"
        exact.gasPrice = invalidRaw
        XCTAssertNil(exact.preparedFee)
        XCTAssertEqual(exact.gasPrice, invalidRaw)
        XCTAssertEqual(
            exact.feeProvenance,
            TransactionFeeProvenance()
        )

        let initializedInvalid = Transaction(
            from: "0x0",
            to: "0x1",
            gasPrice: invalidRaw,
            value: nil,
            data: "0x"
        )
        XCTAssertNil(initializedInvalid.preparedFee)
        XCTAssertEqual(initializedInvalid.gasPrice, invalidRaw)
        XCTAssertEqual(
            initializedInvalid.feeIntent,
            .legacy(gasPrice: nil)
        )
    }

    func testFeeStateInitializerPrecedenceKeepsInvalidPreparedState() {
        let invalidFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 2,
            maxFeePerGas: 1
        )
        let provenance = TransactionFeeProvenance(
            maxPriorityFeePerGas: .dapp,
            maxFeePerGas: .automatic
        )
        let transaction = Transaction(
            from: "0x0",
            to: "0x1",
            nonce: "0x0",
            gasPrice: "0x64",
            gas: "0x5208",
            value: nil,
            data: "0x",
            feeIntent: .automatic,
            preparedFee: invalidFee,
            feeProvenance: provenance,
            currentBaseFeePerGas: 1
        )

        XCTAssertEqual(transaction.preparedFee, invalidFee)
        XCTAssertNil(transaction.gasPrice)
        XCTAssertEqual(transaction.feeIntent, .automatic)
        XCTAssertEqual(transaction.feeProvenance, provenance)
        XCTAssertFalse(invalidFee.isStructurallyValid)
        XCTAssertFalse(
            transaction.isReadyForApproval(
                on: makeNetwork(chainID: 10)
            )
        )
    }

    func testFeeAndMixedProvenanceReplacementIsAtomic() {
        var transaction = Transaction(
            from: "0x0",
            to: "0x1",
            nonce: "0x1",
            value: nil,
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: 202
            ),
            feeSource: .automatic
        )
        let replacementFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 3,
            maxFeePerGas: 303
        )
        let mixedProvenance = TransactionFeeProvenance(
            maxPriorityFeePerGas: .dapp,
            maxFeePerGas: .automatic
        )

        XCTAssertTrue(
            transaction.apply(
                Transaction.Edits(
                    preparedFee: replacementFee,
                    replacementFeeProvenance: mixedProvenance
                )
            )
        )
        XCTAssertEqual(transaction.preparedFee, replacementFee)
        XCTAssertEqual(transaction.feeProvenance, mixedProvenance)
        XCTAssertNil(transaction.gasPrice)

        let committedID = transaction.id
        XCTAssertFalse(
            transaction.apply(
                Transaction.Edits(
                    preparedFee: .eip1559(
                        maxPriorityFeePerGas: 4,
                        maxFeePerGas: 3
                    ),
                    replacementFeeProvenance:
                        TransactionFeeProvenance(
                            maxPriorityFeePerGas: .manual,
                            maxFeePerGas: .manual
                        ),
                    nonce: 7
                )
            )
        )
        XCTAssertEqual(transaction.preparedFee, replacementFee)
        XCTAssertEqual(transaction.feeProvenance, mixedProvenance)
        XCTAssertEqual(transaction.nonce, "0x1")
        XCTAssertEqual(transaction.id, committedID)
    }

    func testFeeGweiParserEnforcesUInt256WithoutChangingLegacyExactParser() throws {
        let overflowGwei = "1" + String(repeating: "0", count: 80)

        XCTAssertNil(Transaction.feeWei(fromGwei: overflowGwei))
        XCTAssertNotNil(Transaction.gasPriceWei(fromGwei: overflowGwei))
        XCTAssertEqual(
            Transaction.feeWei(fromGwei: ".000000001"),
            BigUInt(1)
        )
        XCTAssertEqual(
            Transaction.editableGwei(fromWei: BigUInt(1_234_567_890)),
            "1.23456789"
        )
    }

    func testNonceOnlyEditPreservesLatestGasPrice() {
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.gasPrice = BigUInt(999).hexString

        XCTAssertTrue(transaction.apply(Transaction.Edits(nonce: 3)))
        XCTAssertEqual(transaction.gasPriceValue, BigUInt(999))
        XCTAssertEqual(transaction.nonce, String.hex(3))
    }

    func testApprovalValidationAllowsLegacyZeroOffMainnetAndAllowsZeroPriority() throws {
        let mainnet = makeNetwork(chainID: EthereumNetwork.ethMainnetChainId)
        let otherNetwork = makeNetwork(chainID: 10)
        var transaction = Transaction(from: "0x0", to: "0x1", value: nil, data: "0x")
        transaction.nonce = String.hex(0)
        transaction.gas = String.hex(21_000)

        let largeGasPrice = try XCTUnwrap(BigUInt(decimalString: "18446744073709551616"))
        transaction.gasPrice = largeGasPrice.hexString
        XCTAssertEqual(transaction.gasPriceValue, largeGasPrice)
        XCTAssertTrue(transaction.isReadyForApproval(on: mainnet))

        let maximumGasPrice = try XCTUnwrap(BigUInt(hexString: String(repeating: "f", count: 64)))
        transaction.gasPrice = maximumGasPrice.hexString
        XCTAssertFalse(
            transaction.isReadyForApproval(on: mainnet),
            "The maximum fee product must fit uint256"
        )

        let uint256Overflow = try XCTUnwrap(BigUInt(hexString: "1" + String(repeating: "0", count: 64)))
        transaction.gasPrice = uint256Overflow.hexString
        XCTAssertFalse(Transaction.isValidGasPrice(uint256Overflow, on: mainnet))
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
        XCTAssertFalse(transaction.isReadyForApproval(on: otherNetwork))

        transaction.gasPrice = BigUInt(0).hexString
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
        XCTAssertTrue(transaction.isReadyForApproval(on: otherNetwork))

        transaction.preparedFee = .eip1559(
            maxPriorityFeePerGas: 0,
            maxFeePerGas: 1
        )
        transaction.currentBaseFeePerGas = 0
        transaction.nextBaseFeePerGas = 0
        XCTAssertTrue(
            transaction.isReadyForApproval(on: otherNetwork),
            "A zero tip whose cap covers the base fee is approvable"
        )
        XCTAssertTrue(transaction.isReadyForApproval(on: mainnet))

        transaction.gasPrice = "invalid"
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))
        XCTAssertFalse(transaction.isReadyForApproval(on: otherNetwork))

        transaction.gasPrice = BigUInt(1).hexString
        transaction.gas = nil
        XCTAssertFalse(transaction.isReadyForApproval(on: mainnet))

        transaction.gas = "0x1" + String(repeating: "0", count: 64)
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
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
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
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 2)
    }

    func testEthereumPreparationRejectsZeroOrOversizedGasEstimates() {
        for invalidGas in [
            "0x0",
            "0x00",
            "0x" + String(repeating: "f", count: 65),
        ] {
            let rpc = EthereumPreparationRPCStub(
                estimateGasResults: [.success(invalidGas)]
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
            XCTAssertEqual(rpc.estimateGasCallCount, 1)
        }

        let secondEstimateZeroRPC = EthereumPreparationRPCStub(
            estimateGasResults: [
                .success("0x5208"),
                .success("0x0"),
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
            using: secondEstimateZeroRPC,
            transaction: transaction,
            expectedFailure: .gasEstimationFailed
        )
        XCTAssertEqual(secondEstimateZeroRPC.estimateGasCallCount, 2)
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
                    XCTFail("Expected terminal preparation success, got \(result)")
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
                    XCTFail("Expected terminal preparation success, got \(result)")
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

    func testEthereumPreparationRefreshesFeeForOtherwiseReadyTransaction() {
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
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
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
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
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
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 2)
    }

    func testEthereumPreparationRejectsMalformedNonceResponse() {
        let rpc = EthereumPreparationRPCStub(
            nonceResult: .success(
                "0x" + String(repeating: "f", count: 65)
            )
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
    }

    func testLatestBlockBaseFeeDecodingPreservesExplicitFieldStates()
        throws {
        let fixtures: [
            (json: String, expected: EthereumLatestBlock.BaseFeeField)
        ] = [
            (
                #"{"number":"0x1"}"#,
                .missing
            ),
            (
                #"{"number":"0x1","baseFeePerGas":null}"#,
                .null
            ),
            (
                #"{"number":"0x1","baseFeePerGas":"0x64"}"#,
                .encoded("0x64")
            ),
            (
                #"{"number":"0x1","baseFeePerGas":"not-a-quantity"}"#,
                .encoded("not-a-quantity")
            ),
        ]

        for fixture in fixtures {
            let block = try JSONDecoder().decode(
                EthereumLatestBlock.self,
                from: Data(fixture.json.utf8)
            )
            XCTAssertEqual(block.number, "0x1")
            XCTAssertEqual(block.baseFeeField, fixture.expected)
        }

        let malformedBlock = try JSONDecoder().decode(
            EthereumLatestBlock.self,
            from: Data(fixtures[3].json.utf8)
        )
        let rpc = FakeEthereumRPCClient(
            feeHistoryResult: .failure(StubError.expected),
            latestBlockResult: .success(malformedBlock)
        )
        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            description: "malformed decoded block base fee"
        )

        XCTAssertEqual(estimate.support, .unknown)
        XCTAssertNil(estimate.currentBaseFee)
        XCTAssertTrue(rpc.feeHistoryCalls.isEmpty)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
    }

    func testLatestBlockBaseFeeDecodingRejectsNonStringValue() {
        let data = Data(
            #"{"number":"0x1","baseFeePerGas":100}"#.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                EthereumLatestBlock.self,
                from: data
            )
        )
    }

    func testEthereumRPCEmitsAnchoredFeeHistoryRequestAndDecodesObjectResult() throws {
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
            XCTAssertEqual(params[1] as? String, "0xabc")
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
            newestBlock: "0xabc",
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

    func testType2EstimateGasObjectIncludesDynamicFieldsAndAccessListOnly()
        throws {
        let address = "0x" + String(repeating: "11", count: 20)
        let storageKey = "0x" + String(repeating: "00", count: 31) + "01"
        let entry = try XCTUnwrap(
            EthereumAccessListEntry(
                address: address,
                storageKeys: [storageKey]
            )
        )
        let transaction = Transaction(
            from: "0xfrom",
            to: "",
            gas: "0x5208",
            value: "0x1",
            data: "0x1234",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: 202
            ),
            accessList: [entry]
        )

        let object = EthereumRPC.estimateGasTransactionObject(
            for: transaction
        )

        XCTAssertEqual(object["type"] as? String, "0x2")
        XCTAssertEqual(object["maxPriorityFeePerGas"] as? String, "0x2")
        XCTAssertEqual(object["maxFeePerGas"] as? String, "0xca")
        XCTAssertNil(object["gasPrice"])
        XCTAssertNil(object["to"], "Contract creation must omit `to`")
        let accessList = try XCTUnwrap(
            object["accessList"] as? [[String: Any]]
        )
        XCTAssertEqual(accessList.count, 1)
        XCTAssertEqual(accessList[0]["address"] as? String, address)
        XCTAssertEqual(
            accessList[0]["storageKeys"] as? [String],
            [storageKey]
        )
    }

    func testLegacyEstimateGasObjectEmitsCanonicalFeeEncoding() {
        let transaction = Transaction(
            from: "0xfrom",
            to: "0xto",
            gasPrice: "0xAB",
            gas: "0x5208",
            value: "0x1",
            data: "0x"
        )

        let object = EthereumRPC.estimateGasTransactionObject(
            for: transaction
        )

        XCTAssertEqual(
            transaction.preparedFee,
            .legacy(gasPrice: 171)
        )
        XCTAssertEqual(
            transaction.gasPrice,
            "0xAB",
            "The stored raw encoding is preserved on the transaction"
        )
        XCTAssertEqual(
            object["gasPrice"] as? String,
            "0xab",
            "The RPC object always carries the canonical encoding"
        )
    }

    func testEthereumSendSubmitsOneType2PayloadAndPreservesRPCError()
        throws {
        let rpcError = EthereumRPCError.serverError(
            -32_000,
            "FeeTooLow: EffectivePriorityFeePerGas too low 0 < 1, BaseFee: 306"
        )
        let rpc = EthereumCoreRPCStub(
            sendResult: .failure(rpcError)
        )
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            ),
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            ),
            feeSource: .dapp,
            currentBaseFeePerGas: 306,
            nextBaseFeePerGas: 306
        )
        let completed = expectation(description: "type-2 send completed")
        var receivedFailure: EthereumSendFailure?

        Ethereum(rpc: rpc).send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(
                chainID: 100,
                rpcURL: rpcURL + "/type-2-send"
            )
        ) { result in
            switch result {
            case .success(let transactionHash):
                XCTFail("Unexpected transaction hash: \(transactionHash)")
            case .failure(let failure):
                receivedFailure = failure
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(receivedFailure, .rpc(rpcError))
        XCTAssertEqual(rpc.sentRawTransactions.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(rpc.sentRawTransactions.first).hasPrefix("0x02")
        )
    }

    func testEthereumSendSignsCanonicalNonemptyAccessListFixedVector()
        throws {
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: try XCTUnwrap(
                    WalletCrypto.hexData(
                        "608dcb1742bb3fb7aec002074e3420e4fab7d00cced79ccdac53ed5b27138151"
                    )
                )
            )
        )
        let accessList = [
            try XCTUnwrap(
                EthereumAccessListEntry(
                    address:
                        "0x0000000000000000000000000000000000000101",
                    storageKeys: [
                        "0x" + String(repeating: "0", count: 64),
                        "0x" + String(repeating: "0", count: 60) + "60a7",
                    ]
                )
            ),
            try XCTUnwrap(
                EthereumAccessListEntry(
                    address:
                        "0x1111111111111111111111111111111111111111",
                    storageKeys: []
                )
            ),
        ]
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x3535353535353535353535353535353535353535",
            nonce: "0x6",
            gas: "0x186a0",
            value: "0x1",
            data: "0xdeadbeef",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: try XCTUnwrap(
                    BigUInt(hexString: "59682f00")
                ),
                maxFeePerGas: try XCTUnwrap(
                    BigUInt(hexString: "09502f9000")
                )
            ),
            feeSource: .dapp,
            accessList: accessList,
            currentBaseFeePerGas: 1,
            nextBaseFeePerGas: 1
        )
        let rpc = EthereumCoreRPCStub()
        let completed = expectation(
            description: "canonical access-list transaction sent"
        )

        Ethereum(rpc: rpc).send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 8_453)
        ) { result in
            XCTAssertEqual(
                try? result.get(),
                "0xtransaction"
            )
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(
            rpc.sentRawTransactions,
            [
                "0x02f8e5822105068459682f008509502f9000830186a09435353535353535353535353535353535353535350184deadbeeff872f859940000000000000000000000000000000000000101f842a00000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000060a7d6941111111111111111111111111111111111111111c080a014dd6d80870ac4a49e57ae811431fb78be23f11b96846631f823204cf892f6c9a026e1a1ce4bf3cc048eb39089271fc8e1bab0eb75e16630737e8f3fc827f4b1dd"
            ]
        )
    }

    func testDirectSendRejectsUnsafeType2FeeBeforeSigning() throws {
        let rpc = EthereumCoreRPCStub()
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 305
            ),
            feeSource: .dapp,
            currentBaseFeePerGas: 306,
            nextBaseFeePerGas: 306
        )
        let completed = expectation(description: "unsafe fee rejected")

        Ethereum(rpc: rpc).send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 100)
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("Unsafe type-2 fee unexpectedly sent")
                completed.fulfill()
                return
            }
            XCTAssertEqual(failure, .invalidTransaction)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertTrue(rpc.sentRawTransactions.isEmpty)
    }

    func testZeroEffectiveTipDappFeeSends() throws {
        let rpc = EthereumCoreRPCStub()
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 306
            ),
            feeSource: .dapp,
            currentBaseFeePerGas: 306,
            nextBaseFeePerGas: 306
        )
        let completed = expectation(
            description: "zero effective tip sent"
        )

        Ethereum(rpc: rpc).send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 100)
        ) { result in
            XCTAssertEqual(try? result.get(), "0xtransaction")
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(rpc.sentRawTransactions.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(rpc.sentRawTransactions.first).hasPrefix("0x02")
        )
    }

    func testDirectSendRejectsLegacyFeeWithAccessList() throws {
        let rpc = EthereumCoreRPCStub()
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let accessListEntry = try XCTUnwrap(
            EthereumAccessListEntry(
                address: Data(repeating: 0, count: 20),
                storageKeys: []
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .legacy(gasPrice: 1),
            feeSource: .dapp,
            accessList: [accessListEntry]
        )
        let completed = expectation(
            description: "legacy access list rejected"
        )

        Ethereum(rpc: rpc).send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 100)
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("Legacy transaction silently dropped its access list")
                completed.fulfill()
                return
            }
            XCTAssertEqual(failure, .invalidTransaction)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertTrue(rpc.sentRawTransactions.isEmpty)
    }

    func testDirectSendUsesOnlyAuthoritativeCatalogFeeMarketCapability()
        throws {
        let rpc = EthereumCoreRPCStub()
        let ethereum = Ethereum(rpc: rpc)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let url = try XCTUnwrap(URL(string: rpcURL + "/hinted-send"))
        let checkedAt = ISO8601DateFormatter().string(from: Date())

        func network(
            support: EthereumFeeMarketSupport
        ) -> EthereumNetwork {
            EthereumNetwork(
                chainId: 100,
                name: "Hinted",
                symbol: "XDAI",
                rpcEndpoint: .catalog(
                    url,
                    alchemyNetwork: nil,
                    feeMarketHint: EthereumFeeMarketHint(
                        support: support,
                        checkedAt: checkedAt,
                        observedEndpoint: url.absoluteString
                    )
                ),
                isTestnet: false,
                mightShowPrice: false,
                explorer: nil
            )
        }

        let legacyTransaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0",
            gas: "5208",
            value: "0",
            data: "0x",
            preparedFee: .legacy(gasPrice: 1),
            feeSource: .dapp
        )
        let type2Transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 1
            ),
            feeSource: .dapp,
            currentBaseFeePerGas: 0,
            nextBaseFeePerGas: 0
        )
        let legacyCompleted = expectation(
            description: "legacy rejected on EIP-1559 catalog"
        )
        let type2Completed = expectation(
            description: "type-2 ignores dated legacy observation"
        )

        ethereum.send(
            transaction: legacyTransaction,
            privateKey: privateKey,
            network: network(support: .eip1559)
        ) { result in
            if case .failure(let failure) = result {
                XCTAssertEqual(failure, .invalidTransaction)
            } else {
                XCTFail("Legacy fee without a base snapshot was sent")
            }
            legacyCompleted.fulfill()
        }
        ethereum.send(
            transaction: type2Transaction,
            privateKey: privateKey,
            network: network(support: .legacy)
        ) { result in
            XCTAssertEqual(try? result.get(), "0xtransaction")
            type2Completed.fulfill()
        }

        wait(for: [legacyCompleted, type2Completed], timeout: 2)
        XCTAssertEqual(rpc.sentRawTransactions.count, 1)
        XCTAssertTrue(
            rpc.sentRawTransactions.first?.hasPrefix("0x02") == true
        )
    }

    func testSendRejectsUInt256MaximumFeeProductBeforeSigning() throws {
        let rpc = EthereumCoreRPCStub()
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x2",
            value: "0x0",
            data: "0x",
            preparedFee: .legacy(gasPrice: maximum),
            feeSource: .dapp
        )
        let completed = expectation(description: "overflow rejected")

        Ethereum(rpc: rpc).send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 1)
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("Overflowing fee product unexpectedly sent")
                completed.fulfill()
                return
            }
            XCTAssertEqual(failure, .invalidTransaction)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertTrue(rpc.sentRawTransactions.isEmpty)
    }

    func testDirectSendRejectsZeroLegacyGasOnlyOnMainnet() throws {
        let rpc = EthereumCoreRPCStub()
        let ethereum = Ethereum(rpc: rpc)
        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gasPrice: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x"
        )
        let mainnetCompleted = expectation(
            description: "mainnet zero fee rejected"
        )
        let otherNetworkCompleted = expectation(
            description: "other network zero fee sent"
        )

        ethereum.send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(
                chainID: EthereumNetwork.ethMainnetChainId
            )
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("Mainnet zero gas price unexpectedly sent")
                mainnetCompleted.fulfill()
                return
            }
            XCTAssertEqual(failure, .invalidTransaction)
            mainnetCompleted.fulfill()
        }
        ethereum.send(
            transaction: transaction,
            privateKey: privateKey,
            network: makeNetwork(chainID: 10)
        ) { result in
            guard case .success(let hash) = result else {
                XCTFail("Non-mainnet zero gas price was rejected")
                otherNetworkCompleted.fulfill()
                return
            }
            XCTAssertEqual(hash, "0xtransaction")
            otherNetworkCompleted.fulfill()
        }

        wait(
            for: [mainnetCompleted, otherNetworkCompleted],
            timeout: 2
        )
        XCTAssertEqual(rpc.sentRawTransactions.count, 1)
    }

    func testPreparationFillsOnlyMissingType2FieldsAndPreservesProvenance() {
        let rpc = makeEIP1559RPCStub(chainID: 9_001)
        let ethereum = Ethereum(rpc: rpc)
        let network = makeNetwork(
            chainID: 9_001,
            rpcURL: rpcURL + "/partial-type-2"
        )
        let fixtures: [(
            intent: TransactionFeeIntent,
            expectedFee: PreparedTransactionFee,
            expectedProvenance: TransactionFeeProvenance
        )] = [
            (
                .eip1559(
                    maxPriorityFeePerGas: 7,
                    maxFeePerGas: nil
                ),
                .eip1559(
                    maxPriorityFeePerGas: 7,
                    maxFeePerGas: 227
                ),
                TransactionFeeProvenance(
                    maxPriorityFeePerGas: .dapp,
                    maxFeePerGas: .automatic
                )
            ),
            (
                .eip1559(
                    maxPriorityFeePerGas: nil,
                    maxFeePerGas: 300
                ),
                .eip1559(
                    maxPriorityFeePerGas: 2,
                    maxFeePerGas: 300
                ),
                TransactionFeeProvenance(
                    maxPriorityFeePerGas: .automatic,
                    maxFeePerGas: .dapp
                )
            ),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let transaction = Transaction(
                from: "0x0000000000000000000000000000000000000001",
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0",
                gas: "0x5208",
                value: "0x0",
                data: "0x",
                feeIntent: fixture.intent,
                feeSource: .dapp
            )
            let prepared = prepare(
                transaction,
                using: ethereum,
                network: network,
                description: "partial type-2 preparation \(index)"
            )

            XCTAssertEqual(prepared?.feeIntent, fixture.intent)
            XCTAssertEqual(prepared?.preparedFee, fixture.expectedFee)
            XCTAssertEqual(
                prepared?.feeProvenance,
                fixture.expectedProvenance
            )
        }
    }

    func testPreparationRefreshesOnlyWalletOwnedFieldAfterPartialManualEdit() {
        let rpc = makeEIP1559RPCStub(chainID: 9_002)
        let ethereum = Ethereum(rpc: rpc)
        let network = makeNetwork(
            chainID: 9_002,
            rpcURL: rpcURL + "/partial-manual-type-2"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: nil
            ),
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 9,
                maxFeePerGas: 205
            ),
            feeProvenance: TransactionFeeProvenance(
                maxPriorityFeePerGas: .manual,
                maxFeePerGas: .automatic
            )
        )

        let prepared = prepare(
            transaction,
            using: ethereum,
            network: network,
            description: "partial manual type-2 preparation"
        )

        XCTAssertEqual(
            prepared?.preparedFee,
            .eip1559(
                maxPriorityFeePerGas: 9,
                maxFeePerGas: 229
            )
        )
        XCTAssertEqual(
            prepared?.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .manual,
                maxFeePerGas: .automatic
            )
        )
    }

    func testExplicitLegacyWithoutGasPriceDerivesHeadroomedBasePlusRecommendedPriority() {
        let rpc = makeEIP1559RPCStub(chainID: 9_002)
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: nil),
            feeSource: .dapp
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: rpc),
            network: makeNetwork(
                chainID: 9_002,
                rpcURL: rpcURL + "/explicit-legacy"
            ),
            description: "explicit legacy preparation"
        )

        XCTAssertEqual(prepared?.feeIntent, .legacy(gasPrice: nil))
        XCTAssertEqual(
            prepared?.preparedFee,
            .legacy(gasPrice: 125)
        )
        XCTAssertEqual(prepared?.feeProvenance.gasPrice, .automatic)
    }

    func testUserLegacyGasPriceEqualToBaseFeeIsAccepted() {
        let chainID = 9_021
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/legacy-at-base"
        )

        func transaction(gasPrice: String?) -> Transaction {
            Transaction(
                from: "0x0000000000000000000000000000000000000001",
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0",
                gasPrice: gasPrice,
                gas: "0x5208",
                value: "0x0",
                data: "0x",
                feeIntent: .legacy(
                    gasPrice: gasPrice.flatMap {
                        EthereumQuantity.parseUInt256($0)
                    }
                ),
                feeSource: .dapp
            )
        }

        let atBase = prepare(
            transaction(gasPrice: "0x6e"),
            using: Ethereum(rpc: makeEIP1559RPCStub(chainID: chainID)),
            network: network,
            description: "dapp legacy gas price at base"
        )
        XCTAssertEqual(atBase?.preparedFee, .legacy(gasPrice: 110))
        XCTAssertEqual(atBase?.feeProvenance.gasPrice, .dapp)
        XCTAssertEqual(atBase?.isReadyForApproval(on: network), true)

        let derived = prepare(
            transaction(gasPrice: nil),
            using: Ethereum(rpc: makeEIP1559RPCStub(chainID: chainID)),
            network: network,
            description: "wallet-managed legacy derivation"
        )
        XCTAssertEqual(derived?.preparedFee, .legacy(gasPrice: 125))
        XCTAssertEqual(derived?.feeProvenance.gasPrice, .automatic)

        let completed = expectation(description: "below-base rejected")
        Ethereum(
            rpc: makeEIP1559RPCStub(chainID: chainID),
            interpretTransaction: { _, _, _ in }
        ).prepareTransaction(
            transaction(gasPrice: "0x6d"),
            forceGasCheck: false,
            network: network,
            onUpdate: { _ in }
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("A below-base dapp gas price unexpectedly prepared")
                completed.fulfill()
                return
            }
            XCTAssertEqual(failure, .unsafeFees)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testAutomaticLegacyPreparationSupportsGasFreeNetworks() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x232b"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x0")
        )
        let network = makeNetwork(
            chainID: 9_003,
            rpcURL: rpcURL + "/gas-free-legacy"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x"
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network,
            description: "gas-free legacy preparation"
        )

        XCTAssertEqual(prepared?.preparedFee, .legacy(gasPrice: 0))
        XCTAssertEqual(prepared?.feeProvenance.gasPrice, .automatic)
        XCTAssertEqual(prepared?.isReadyForApproval(on: network), true)
    }

    func testAutomaticLegacyPreparationRefreshesExistingWalletFee() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x232f"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x46")
        )
        let network = makeNetwork(
            chainID: 9_007,
            rpcURL: rpcURL + "/refresh-automatic-legacy"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .legacy(gasPrice: 10),
            feeSource: .automatic
        )
        let completed = expectation(description: "legacy fee refreshed")
        var prepared: Transaction?
        var estimate: GasService.Estimate?

        Ethereum(rpc: rpc).prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: network,
            onUpdate: { _ in },
            onFeeEstimate: { estimate = $0 }
        ) { result in
            if case .success(let transaction) = result {
                prepared = transaction
            } else {
                XCTFail("Expected fresh automatic legacy fee")
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(prepared?.preparedFee, .legacy(gasPrice: 70))
        XCTAssertEqual(prepared?.feeProvenance.gasPrice, .automatic)
        XCTAssertEqual(
            estimate?.suggestedFee(for: .automatic),
            .legacy(gasPrice: 70)
        )
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
    }

    func testAutomaticLegacyPreparationDoesNotReuseFeeAfterGasPriceFailure() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x2330"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .failure(StubError.expected)
        )
        let network = makeNetwork(
            chainID: 9_008,
            rpcURL: rpcURL + "/failed-automatic-legacy-refresh"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .legacy(gasPrice: 10),
            feeSource: .automatic
        )
        let completed = expectation(
            description: "stale automatic legacy fee rejected"
        )

        Ethereum(rpc: rpc).prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: network,
            onUpdate: { _ in }
        ) { result in
            if case .failure(let failure) = result {
                XCTAssertEqual(failure, .gasPriceUnavailable)
            } else {
                XCTFail("Expected gas-price discovery failure")
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
    }

    func testUserLegacyFeeRemainsAuthoritativeWithFreshSuggestion() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x2331"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x46")
        )
        let network = makeNetwork(
            chainID: 9_009,
            rpcURL: rpcURL + "/manual-legacy-suggestion"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: 10),
            preparedFee: .legacy(gasPrice: 10),
            feeSource: .manual
        )
        let completed = expectation(description: "manual legacy fee prepared")
        var prepared: Transaction?
        var preparationEstimate: GasService.Estimate?

        let ethereum = Ethereum(rpc: rpc)
        ethereum.prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: network,
            onUpdate: { _ in },
            onFeeEstimate: { preparationEstimate = $0 }
        ) { result in
            if case .success(let transaction) = result {
                prepared = transaction
            } else {
                XCTFail("Expected manual legacy fee to remain valid")
            }
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(prepared?.preparedFee, .legacy(gasPrice: 10))
        XCTAssertEqual(prepared?.feeProvenance.gasPrice, .manual)
        XCTAssertEqual(
            preparationEstimate?.suggestedFee(
                for: .legacy(gasPrice: 10)
            ),
            .legacy(gasPrice: 70)
        )

        guard let prepared else {
            XCTFail("Missing prepared transaction")
            return
        }
        switch preflight(prepared, using: ethereum, network: network) {
        case .safe(let preflightTransaction, let estimate):
            XCTAssertEqual(
                preflightTransaction.preparedFee,
                .legacy(gasPrice: 10)
            )
            XCTAssertEqual(
                estimate.suggestedFee(for: prepared.feeIntent),
                .legacy(gasPrice: 70)
            )
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("A suggestion must not replace a valid manual legacy fee")
        }
        XCTAssertEqual(rpc.gasPriceCallCount, 2)
    }

    func testSuppliedType2CapAtUInt256MaximumDoesNotRequireDerivedCap()
        throws {
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let currentBase = maximum - BigUInt(2)
        let nextBase = maximum - BigUInt(1)
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x232d"),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: currentBase.toHexString(withPrefix: true),
                        next: nextBase.toHexString(withPrefix: true)
                    ),
                    reward: nil
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded(
                        currentBase.toHexString(withPrefix: true)
                    )
                )
            ),
            maxPriorityFeeResult: .success("0x1")
        )
        let ethereum = Ethereum(rpc: rpc)
        let network = makeNetwork(
            chainID: 9_005,
            rpcURL: rpcURL + "/uint256-type-2-cap"
        )
        let fixtures: [TransactionFeeIntent] = [
            .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: maximum
            ),
            .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: maximum
            ),
        ]

        for (index, intent) in fixtures.enumerated() {
            let transaction = Transaction(
                from: "0x0000000000000000000000000000000000000001",
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0",
                gas: "0x1",
                value: "0x0",
                data: "0x",
                feeIntent: intent,
                feeSource: .dapp
            )
            let prepared = prepare(
                transaction,
                using: ethereum,
                network: network,
                description: "uint256 type-2 cap \(index)"
            )

            XCTAssertEqual(
                prepared?.preparedFee,
                .eip1559(
                    maxPriorityFeePerGas: 1,
                    maxFeePerGas: maximum
                )
            )
            XCTAssertEqual(prepared?.currentBaseFeePerGas, currentBase)
            XCTAssertEqual(prepared?.nextBaseFeePerGas, nextBase)
            XCTAssertEqual(
                prepared?.feeProvenance.maxFeePerGas,
                .dapp
            )
        }
    }

    func testAutomaticGnosisPreparationRepairsZeroPrioritySuggestion() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x64"),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x132",
                        next: "0x132"
                    ),
                    reward: fullRewards(
                        ["0x0", "0x0"]
                    )
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x132")
                )
            ),
            maxPriorityFeeResult: .success("0x0"),
            gasPriceResult: .success("0x132")
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: rpc),
            network: makeNetwork(
                chainID: 100,
                rpcURL: rpcURL + "/gnosis-incident"
            ),
            description: "automatic Gnosis incident regression"
        )

        XCTAssertEqual(
            prepared?.preparedFee,
            .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 613
            )
        )
        XCTAssertEqual(prepared?.feeSource, .automatic)
        XCTAssertEqual(prepared?.currentBaseFeePerGas, 306)
        XCTAssertEqual(prepared?.nextBaseFeePerGas, 306)
    }

    func testAutomaticPreparationFailsWhenEveryPrioritySourceFails() {
        let chainID = 9_010
        let rpc = makeEIP1559RPCStubWithoutFeeSuggestion(chainID: chainID)
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/missing-priority-suggestion"
        )
        let completed = expectation(
            description: "automatic priority remains unavailable"
        )
        var receivedEstimate: GasService.Estimate?

        Ethereum(rpc: rpc).prepareTransaction(
            Transaction(
                from: "0x0000000000000000000000000000000000000001",
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0",
                gas: "0x5208",
                value: "0x0",
                data: "0x",
                feeIntent: .automatic
            ),
            forceGasCheck: false,
            network: network,
            onUpdate: { _ in },
            onFeeEstimate: { receivedEstimate = $0 }
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("Missing priority sources unexpectedly prepared")
                completed.fulfill()
                return
            }
            XCTAssertEqual(failure, .gasPriceUnavailable)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(receivedEstimate?.support, .eip1559)
        XCTAssertEqual(receivedEstimate?.currentBaseFee, 100)
        XCTAssertEqual(receivedEstimate?.nextBaseFee, 110)
        XCTAssertNil(receivedEstimate?.info)
        XCTAssertNil(receivedEstimate?.recommendedEIP1559Fee)
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 1)
        XCTAssertEqual(rpc.gasPriceCallCount, 1)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testSuppliedPriorityCanDeriveCapWithoutSuggestedCurve() {
        let chainID = 9_011
        let rpc = makeEIP1559RPCStubWithoutFeeSuggestion(chainID: chainID)
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 7,
                maxFeePerGas: nil
            ),
            feeSource: .dapp
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: rpc),
            network: makeNetwork(
                chainID: chainID,
                rpcURL: rpcURL + "/supplied-priority-without-curve"
            ),
            description: "supplied priority without curve"
        )

        XCTAssertEqual(
            prepared?.preparedFee,
            .eip1559(
                maxPriorityFeePerGas: 7,
                maxFeePerGas: 227
            )
        )
        XCTAssertEqual(
            prepared?.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .automatic
            )
        )
    }

    func testLowSuppliedCapIsUnsafeWhenPrioritySuggestionIsUnavailable() {
        let chainID = 9_012
        let rpc = makeEIP1559RPCStubWithoutFeeSuggestion(chainID: chainID)
        let completed = expectation(description: "low cap remains editable")
        var latestUpdate: Transaction?

        Ethereum(
            rpc: rpc,
            interpretTransaction: { _, _, _ in }
        ).prepareTransaction(
            Transaction(
                from: "0x0000000000000000000000000000000000000001",
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0",
                gas: "0x5208",
                value: "0x0",
                data: "0x",
                feeIntent: .eip1559(
                    maxPriorityFeePerGas: nil,
                    maxFeePerGas: 110
                ),
                feeSource: .dapp
            ),
            forceGasCheck: false,
            network: makeNetwork(
                chainID: chainID,
                rpcURL: rpcURL + "/low-cap-without-curve"
            ),
            onUpdate: { latestUpdate = $0 }
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("Low supplied cap unexpectedly prepared")
                completed.fulfill()
                return
            }
            XCTAssertEqual(failure, .unsafeFees)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertNil(latestUpdate?.maxPriorityFeePerGasValue)
        XCTAssertEqual(latestUpdate?.maxFeePerGasValue, 110)
        XCTAssertEqual(latestUpdate?.currentBaseFeePerGas, 100)
        XCTAssertEqual(latestUpdate?.nextBaseFeePerGas, 110)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testDappZeroTipType2FeePreparesWithFreshSnapshot() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x64"),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x132",
                        next: "0x132"
                    ),
                    reward: fullRewards(
                        ["0x0", "0x0"]
                    )
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x132")
                )
            ),
            maxPriorityFeeResult: .success("0x0")
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 0,
                maxFeePerGas: 613
            ),
            feeSource: .dapp
        )
        let completed = expectation(description: "zero-tip fee prepared")
        var prepared: Transaction?
        var receivedEstimate: GasService.Estimate?

        Ethereum(
            rpc: rpc,
            interpretTransaction: { _, _, _ in }
        ).prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: makeNetwork(
                chainID: 100,
                rpcURL: rpcURL + "/zero-tip-dapp-type-2"
            ),
            onUpdate: { _ in },
            onFeeEstimate: { receivedEstimate = $0 },
            completion: { result in
                guard case .success(let transaction) = result else {
                    XCTFail("A covered zero-tip dapp fee must prepare")
                    completed.fulfill()
                    return
                }
                prepared = transaction
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(
            prepared?.preparedFee,
            .eip1559(
                maxPriorityFeePerGas: 0,
                maxFeePerGas: 613
            )
        )
        XCTAssertEqual(
            prepared?.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .dapp
            )
        )
        XCTAssertEqual(prepared?.currentBaseFeePerGas, 306)
        XCTAssertEqual(prepared?.nextBaseFeePerGas, 306)
        XCTAssertEqual(receivedEstimate?.endpointChainID, 100)
        XCTAssertEqual(receivedEstimate?.nextBaseFee, 306)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testDappZeroTipWithoutCapStillRequiresFeeEdit() {
        let chainID = 9_013
        let rpc = makeEIP1559RPCStub(chainID: chainID)
        let completed = expectation(description: "lone zero tip stays editable")
        var latestUpdate: Transaction?

        Ethereum(
            rpc: rpc,
            interpretTransaction: { _, _, _ in }
        ).prepareTransaction(
            Transaction(
                from: "0x0000000000000000000000000000000000000001",
                to: "0x0000000000000000000000000000000000000002",
                nonce: "0x0",
                gas: "0x5208",
                value: "0x0",
                data: "0x",
                feeIntent: .eip1559(
                    maxPriorityFeePerGas: 0,
                    maxFeePerGas: nil
                ),
                feeSource: .dapp
            ),
            forceGasCheck: false,
            network: makeNetwork(
                chainID: chainID,
                rpcURL: rpcURL + "/lone-zero-tip"
            ),
            onUpdate: { latestUpdate = $0 }
        ) { result in
            guard case .failure(let failure) = result else {
                XCTFail("A lone zero tip unexpectedly prepared")
                completed.fulfill()
                return
            }
            XCTAssertEqual(failure, .unsafeFees)
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        XCTAssertNil(latestUpdate?.preparedFee)
        XCTAssertEqual(latestUpdate?.currentBaseFeePerGas, 100)
        XCTAssertEqual(latestUpdate?.nextBaseFeePerGas, 110)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testPreparationPublishesFeeProvenanceOnlyChange() {
        let rpc = makeEIP1559RPCStub(chainID: 9_006)
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: 222
            ),
            feeProvenance: TransactionFeeProvenance(),
            currentBaseFeePerGas: 100,
            nextBaseFeePerGas: 110
        )
        let completed = expectation(description: "provenance prepared")
        var updates = [Transaction]()

        Ethereum(
            rpc: rpc,
            interpretTransaction: { _, _, _ in }
        ).prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: makeNetwork(
                chainID: 9_006,
                rpcURL: rpcURL + "/provenance-only"
            ),
            onUpdate: { updates.append($0) },
            completion: { result in
                guard case .success(let prepared) = result else {
                    XCTFail("Expected successful preparation")
                    completed.fulfill()
                    return
                }
                XCTAssertEqual(
                    prepared.feeProvenance,
                    TransactionFeeProvenance(
                        maxPriorityFeePerGas: .automatic,
                        maxFeePerGas: .automatic
                    )
                )
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(
            updates.first?.feeProvenance.maxPriorityFeePerGas,
            .automatic
        )
    }

    func testPreparationPreservesSliderPriorityWithManualFeeCap() {
        let rpc = makeEIP1559RPCStub(chainID: 9_009)
        let originalFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 7,
            maxFeePerGas: 227
        )
        let provenance = TransactionFeeProvenance(
            maxPriorityFeePerGas: .slider,
            maxFeePerGas: .manual
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: originalFee,
            feeProvenance: provenance,
            currentBaseFeePerGas: 100,
            nextBaseFeePerGas: 110
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: rpc),
            network: makeNetwork(
                chainID: 9_009,
                rpcURL: rpcURL + "/mixed-slider-manual-preparation"
            ),
            description: "mixed provenance preparation"
        )

        XCTAssertEqual(prepared?.preparedFee, originalFee)
        XCTAssertEqual(prepared?.feeProvenance, provenance)
        XCTAssertEqual(prepared?.speedPriorityFeeSource, .slider)
        XCTAssertEqual(prepared?.feeSource, .manual)
    }

    func testPreparationRejectsEndpointChainMismatchForLegacyFee() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x2"),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x64")
        )
        let transaction = Transaction(
            from: "0x1",
            to: "",
            nonce: "0x0",
            gasPrice: "0x64",
            gas: "0x5208",
            value: "0x0",
            data: "0x"
        )
        let completed = expectation(description: "wrong chain rejected")
        var receivedEstimate: GasService.Estimate?

        Ethereum(rpc: rpc).prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: makeNetwork(
                chainID: 1,
                rpcURL: rpcURL + "/wrong-chain-preparation"
            ),
            onUpdate: { _ in },
            onFeeEstimate: { receivedEstimate = $0 },
            completion: { result in
                guard case .failure(let failure) = result else {
                    XCTFail("Wrong-chain endpoint unexpectedly prepared")
                    completed.fulfill()
                    return
                }
                XCTAssertEqual(failure, .gasPriceUnavailable)
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 2)
        XCTAssertNil(receivedEstimate)
        XCTAssertEqual(rpc.chainIDCallCount, 1)
        XCTAssertEqual(rpc.latestBlockCallCount, 0)
        XCTAssertEqual(rpc.feeHistoryCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
        XCTAssertEqual(rpc.estimateGasCallCount, 0)
    }

    func testPreflightReturnsSafeUpdatesWalletFeesAndBlocksManualFees() {
        let rpc = makeEIP1559RPCStub(chainID: 9_003)
        let ethereum = Ethereum(rpc: rpc)
        let network = makeNetwork(
            chainID: 9_003,
            rpcURL: rpcURL + "/preflight"
        )
        let safeFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 7,
            maxFeePerGas: 227
        )
        let safe = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 7,
                maxFeePerGas: 227
            ),
            preparedFee: safeFee,
            feeSource: .dapp,
            currentBaseFeePerGas: 100
        )
        switch preflight(safe, using: ethereum, network: network) {
        case .safe(let transaction, let estimate):
            XCTAssertEqual(transaction.preparedFee, safeFee)
            XCTAssertEqual(transaction.feeSource, .dapp)
            XCTAssertEqual(transaction.currentBaseFeePerGas, 100)
            XCTAssertEqual(transaction.nextBaseFeePerGas, 110)
            XCTAssertEqual(estimate.endpointChainID, 9_003)
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("Expected safe dapp fee")
        }

        let staleWalletFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 1,
            maxFeePerGas: 101
        )
        let automatic = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: staleWalletFee,
            feeSource: .automatic,
            currentBaseFeePerGas: 50
        )
        switch preflight(automatic, using: ethereum, network: network) {
        case .walletManagedUpdated(let transaction, let estimate):
            XCTAssertEqual(transaction.id, automatic.id)
            XCTAssertEqual(
                transaction.preparedFee,
                .eip1559(
                    maxPriorityFeePerGas: 2,
                    maxFeePerGas: 222
                )
            )
            XCTAssertEqual(transaction.feeSource, .automatic)
            XCTAssertEqual(transaction.currentBaseFeePerGas, 100)
            XCTAssertEqual(transaction.nextBaseFeePerGas, 110)
            XCTAssertEqual(estimate.endpointChainID, 9_003)
        case .safe, .userControlledUnsafe, .unavailable:
            XCTFail("Expected wallet-owned fee refresh")
        }

        let manual = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: staleWalletFee,
            feeSource: .manual,
            currentBaseFeePerGas: 50
        )
        switch preflight(manual, using: ethereum, network: network) {
        case .userControlledUnsafe(let transaction, let estimate):
            XCTAssertEqual(transaction.preparedFee, staleWalletFee)
            XCTAssertEqual(transaction.feeSource, .manual)
            XCTAssertEqual(transaction.currentBaseFeePerGas, 100)
            XCTAssertEqual(transaction.nextBaseFeePerGas, 110)
            XCTAssertEqual(estimate.endpointChainID, 9_003)
        case .safe, .walletManagedUpdated, .unavailable:
            XCTFail("Expected unsafe manual fee to be blocked")
        }
    }

    func testPreflightRefreshesOnlyUnsafeWalletFieldInMixedDappFee() {
        let rpc = makeEIP1559RPCStub(chainID: 9_004)
        let network = makeNetwork(
            chainID: 9_004,
            rpcURL: rpcURL + "/mixed-preflight"
        )
        let transaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 7,
                maxFeePerGas: nil
            ),
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 7,
                maxFeePerGas: 107
            ),
            feeProvenance: TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .automatic
            ),
            currentBaseFeePerGas: 50
        )

        switch preflight(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network
        ) {
        case .walletManagedUpdated(let updated, let estimate):
            XCTAssertEqual(updated.id, transaction.id)
            XCTAssertEqual(
                updated.preparedFee,
                .eip1559(
                    maxPriorityFeePerGas: 7,
                    maxFeePerGas: 227
                )
            )
            XCTAssertEqual(estimate.endpointChainID, 9_004)
            XCTAssertEqual(
                updated.feeProvenance,
                TransactionFeeProvenance(
                    maxPriorityFeePerGas: .dapp,
                    maxFeePerGas: .automatic
                )
            )
        case .safe, .userControlledUnsafe, .unavailable:
            XCTFail("Expected only the wallet-owned cap to refresh")
        }
    }

    func testPreflightReportsEndpointIdentityMismatchAsUnavailable() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x2")
        )
        let network = makeNetwork(
            chainID: 9_007,
            rpcURL: rpcURL + "/preflight-chain-mismatch"
        )
        let transaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 201
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )

        switch preflight(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network
        ) {
        case .unavailable(let candidate, let estimate):
            XCTAssertEqual(candidate.id, transaction.id)
            XCTAssertEqual(estimate.endpointChainID, 2)
            XCTAssertEqual(estimate.support, .unknown)
        case .safe, .walletManagedUpdated, .userControlledUnsafe:
            XCTFail("An endpoint mismatch is not an editable fee error")
        }
    }

    func testPreflightReportsUnknownFeeCapabilityAsUnavailable() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success(String.hex(9_008, withPrefix: true)),
            feeHistoryResult: .failure(StubError.expected),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x64")
        )
        let network = makeNetwork(
            chainID: 9_008,
            rpcURL: rpcURL + "/preflight-unknown-capability"
        )
        let transaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 201
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )

        switch preflight(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network
        ) {
        case .unavailable(let candidate, let estimate):
            XCTAssertEqual(candidate.id, transaction.id)
            XCTAssertEqual(candidate.currentBaseFeePerGas, 100)
            XCTAssertNil(candidate.nextBaseFeePerGas)
            XCTAssertEqual(estimate.endpointChainID, 9_008)
            XCTAssertEqual(estimate.support, .unknown)
        case .safe, .walletManagedUpdated, .userControlledUnsafe:
            XCTFail("Unknown capability is not an editable fee error")
        }
    }

    func testManualZeroTipPassesPreflight() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success(String.hex(9_022, withPrefix: true)),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x132",
                        next: "0x132"
                    ),
                    reward: fullRewards(
                        ["0x0", "0x0"]
                    )
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x132")
                )
            ),
            maxPriorityFeeResult: .success("0x0")
        )
        let network = makeNetwork(
            chainID: 9_022,
            rpcURL: rpcURL + "/manual-zero-tip-preflight"
        )
        let fee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 0,
            maxFeePerGas: 613
        )
        let transaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            preparedFee: fee,
            feeSource: .manual,
            currentBaseFeePerGas: 306
        )

        switch preflight(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network
        ) {
        case .safe(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, fee)
            XCTAssertEqual(candidate.feeSource, .manual)
            XCTAssertEqual(estimate.support, .eip1559)
            XCTAssertEqual(estimate.nextBaseFee, 306)
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("A covered manual zero tip is safe to send")
        }
    }

    func testCompleteDappEIP1559FeeProceedsOnUnknownSupportEndpoint() {
        let chainID = 9_023
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/unknown-support-dapp-type-2"
        )

        func makeContradictoryRPC() -> EthereumCoreRPCStub {
            EthereumCoreRPCStub(
                chainIDResult: .success(
                    String.hex(chainID, withPrefix: true)
                ),
                feeHistoryResult: .success(
                    EthereumFeeHistory(
                        baseFeePerGas: fullBaseFees(
                            current: "0x64",
                            next: "0x6e"
                        ),
                        reward: fullRewards(["0x2", "0x4"])
                    )
                ),
                latestBlockResult: .success(
                    EthereumLatestBlock(
                        number: "0x1",
                        baseFeeField: .missing
                    )
                )
            )
        }
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: 200
            ),
            feeSource: .dapp
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: makeContradictoryRPC()),
            network: network,
            description: "complete dapp pair on unknown support"
        )

        XCTAssertEqual(
            prepared?.preparedFee,
            .eip1559(
                maxPriorityFeePerGas: 2,
                maxFeePerGas: 200
            )
        )
        XCTAssertEqual(
            prepared?.feeProvenance,
            TransactionFeeProvenance(
                maxPriorityFeePerGas: .dapp,
                maxFeePerGas: .dapp
            )
        )
        XCTAssertNil(prepared?.feeBasisBaseFeePerGas)
        XCTAssertEqual(prepared?.isReadyForApproval(on: network), true)

        guard let prepared else { return }
        switch preflight(
            prepared,
            using: Ethereum(rpc: makeContradictoryRPC()),
            network: network
        ) {
        case .safe(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, prepared.preparedFee)
            XCTAssertEqual(estimate.support, .unknown)
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("A complete dapp pair is the user's call on an unknown market")
        }
    }

    func testManualFeeReachesReadyOnUnknownSupportEndpoint() {
        let chainID = 9_024
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success(String.hex(chainID, withPrefix: true)),
            feeHistoryResult: .failure(StubError.expected),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x64")
        )
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/unknown-support-manual-fee"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .legacy(gasPrice: 5),
            feeSource: .manual
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network,
            description: "manual fee on unknown support"
        )

        XCTAssertEqual(prepared?.preparedFee, .legacy(gasPrice: 5))
        XCTAssertEqual(prepared?.feeProvenance.gasPrice, .manual)
        XCTAssertEqual(prepared?.isReadyForApproval(on: network), true)
    }

    private func makeAnchorMismatchRPC(chainID: Int) -> EthereumCoreRPCStub {
        EthereumCoreRPCStub(
            chainIDResult: .success(String.hex(chainID, withPrefix: true)),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: ["0x63", "0x64", "0x6e"],
                    reward: [
                        ["0x2", "0x4"],
                        ["0x3", "0x5"],
                    ]
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x65")
                )
            ),
            gasPriceResult: .success("0x64")
        )
    }

    private func makeCatalogHintedNetwork(
        chainID: Int,
        rpcURL: String
    ) throws -> EthereumNetwork {
        let url = try XCTUnwrap(URL(string: rpcURL))
        return EthereumNetwork(
            chainId: chainID,
            name: "Hinted",
            symbol: "ETH",
            rpcEndpoint: .catalog(
                url,
                alchemyNetwork: nil,
                feeMarketHint: EthereumFeeMarketHint(
                    support: .eip1559,
                    checkedAt: ISO8601DateFormatter().string(from: Date()),
                    observedEndpoint: url.absoluteString
                )
            ),
            isTestnet: false,
            mightShowPrice: false,
            explorer: nil
        )
    }

    func testDappLegacyFeePreparesOnCatalogHintedChainWhenHistoryAnchorMismatches()
        throws {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let chainID = 9_031
        let network = try makeCatalogHintedNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/hinted-anchor-mismatch"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: 150),
            feeSource: .dapp
        )

        let prepared = prepare(
            transaction,
            using: Ethereum(rpc: makeAnchorMismatchRPC(chainID: chainID)),
            network: network,
            description: "dapp legacy fee on hinted chain"
        )

        XCTAssertEqual(prepared?.preparedFee, .legacy(gasPrice: 150))
        XCTAssertEqual(prepared?.feeProvenance.gasPrice, .dapp)
        XCTAssertEqual(prepared?.currentBaseFeePerGas, 101)
        XCTAssertNil(prepared?.nextBaseFeePerGas)
        XCTAssertEqual(prepared?.isReadyForApproval(on: network), true)
    }

    func testDappLegacyFeeBelowObservedUnknownBaseFeeRequiresFeeEdit()
        throws {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let chainID = 9_032
        let network = try makeCatalogHintedNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/hinted-below-basis"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: 50),
            feeSource: .dapp
        )
        let failed = expectation(description: "below-basis fee needs edit")

        Ethereum(rpc: makeAnchorMismatchRPC(chainID: chainID))
            .prepareTransaction(
                transaction,
                forceGasCheck: false,
                network: network,
                onUpdate: { _ in },
                completion: { result in
                    guard case .failure(let failure) = result else {
                        XCTFail("Unexpected preparation success")
                        return
                    }
                    XCTAssertEqual(failure, .unsafeFees)
                    failed.fulfill()
                }
            )

        wait(for: [failed], timeout: 2)
    }

    func testPreflightUnknownEstimateWithObservedBaseFeeValidatesUserFee() {
        let chainID = 9_033
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/preflight-unknown-observed-basis"
        )

        func makeTransaction(gasPrice: BigUInt) -> Transaction {
            Transaction(
                from: "0x1",
                to: "0x2",
                gas: "0x5208",
                value: "0x0",
                data: "0x",
                feeIntent: .legacy(gasPrice: gasPrice),
                preparedFee: .legacy(gasPrice: gasPrice),
                feeSource: .dapp
            )
        }

        switch preflight(
            makeTransaction(gasPrice: 150),
            using: Ethereum(rpc: makeAnchorMismatchRPC(chainID: chainID)),
            network: network
        ) {
        case .safe(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, .legacy(gasPrice: 150))
            XCTAssertEqual(candidate.currentBaseFeePerGas, 101)
            XCTAssertNil(candidate.nextBaseFeePerGas)
            XCTAssertEqual(estimate.support, .unknown)
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("A user fee covering the observed basis is safe")
        }

        switch preflight(
            makeTransaction(gasPrice: 50),
            using: Ethereum(rpc: makeAnchorMismatchRPC(chainID: chainID)),
            network: network
        ) {
        case .userControlledUnsafe(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, .legacy(gasPrice: 50))
            XCTAssertEqual(candidate.currentBaseFeePerGas, 101)
            XCTAssertEqual(estimate.support, .unknown)
        case .safe, .walletManagedUpdated, .unavailable:
            XCTFail("A user fee below the observed basis stays editable")
        }
    }

    func testPreflightUnknownEstimateWithoutDataPreservesCandidateBaseFees() {
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success(String.hex(9_034, withPrefix: true)),
            feeHistoryResult: .failure(StubError.expected),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x64")
        )
        let network = makeNetwork(
            chainID: 9_034,
            rpcURL: rpcURL + "/preflight-unknown-preserved-basis"
        )
        let transaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: 150),
            preparedFee: .legacy(gasPrice: 150),
            feeSource: .dapp,
            currentBaseFeePerGas: 100
        )

        switch preflight(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network
        ) {
        case .safe(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, .legacy(gasPrice: 150))
            XCTAssertEqual(candidate.currentBaseFeePerGas, 100)
            XCTAssertNil(candidate.nextBaseFeePerGas)
            XCTAssertEqual(estimate.support, .unknown)
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("A probe that learned nothing keeps the user fee safe")
        }
    }

    func testPreflightDoesNotInventPriorityWhenCurveIsUnavailable() {
        let chainID = 9_013
        let rpc = makeEIP1559RPCStubWithoutFeeSuggestion(chainID: chainID)
        let ethereum = Ethereum(rpc: rpc)
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/preflight-without-curve"
        )

        let safe = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 111
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 100
        )
        switch preflight(safe, using: ethereum, network: network) {
        case .safe(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, safe.preparedFee)
            XCTAssertNil(estimate.info)
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("An already-safe fee does not need a fresh curve")
        }

        let unsafeAutomatic = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 101
            ),
            feeSource: .automatic,
            currentBaseFeePerGas: 50
        )
        switch preflight(
            unsafeAutomatic,
            using: ethereum,
            network: network
        ) {
        case .unavailable(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, unsafeAutomatic.preparedFee)
            XCTAssertNil(estimate.info)
        case .safe, .walletManagedUpdated, .userControlledUnsafe:
            XCTFail("An unsafe automatic fee needs a real priority curve")
        }

        let sliderPriority = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .automatic,
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 7,
                maxFeePerGas: 107
            ),
            feeSource: .slider,
            currentBaseFeePerGas: 50
        )
        switch preflight(
            sliderPriority,
            using: ethereum,
            network: network
        ) {
        case .walletManagedUpdated(let candidate, let estimate):
            XCTAssertEqual(
                candidate.preparedFee,
                .eip1559(
                    maxPriorityFeePerGas: 7,
                    maxFeePerGas: 227
                )
            )
            XCTAssertEqual(candidate.feeSource, .slider)
            XCTAssertNil(estimate.info)
        case .safe, .userControlledUnsafe, .unavailable:
            XCTFail("Slider priority remains authoritative without a curve")
        }

        let lowUserCap = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .eip1559(
                maxPriorityFeePerGas: nil,
                maxFeePerGas: 105
            ),
            preparedFee: .eip1559(
                maxPriorityFeePerGas: 1,
                maxFeePerGas: 105
            ),
            feeProvenance: TransactionFeeProvenance(
                maxPriorityFeePerGas: .automatic,
                maxFeePerGas: .dapp
            ),
            currentBaseFeePerGas: 50
        )
        switch preflight(lowUserCap, using: ethereum, network: network) {
        case .userControlledUnsafe(let candidate, let estimate):
            XCTAssertEqual(candidate.preparedFee, lowUserCap.preparedFee)
            XCTAssertNil(estimate.info)
        case .safe, .walletManagedUpdated, .unavailable:
            XCTFail("A provably low user cap must remain editable")
        }
    }

    func testLegacySliderReusesItsPreviousPriorityWithoutCurve() {
        let chainID = 9_014
        let rpc = makeEIP1559RPCStubWithoutFeeSuggestion(chainID: chainID)
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/legacy-slider-without-curve"
        )
        let transaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: nil),
            preparedFee: .legacy(gasPrice: 107),
            feeProvenance: TransactionFeeProvenance(
                gasPrice: .slider
            ),
            currentBaseFeePerGas: 100
        )

        switch preflight(
            transaction,
            using: Ethereum(rpc: rpc),
            network: network
        ) {
        case .walletManagedUpdated(let candidate, let estimate):
            XCTAssertEqual(
                candidate.preparedFee,
                .legacy(gasPrice: 117)
            )
            XCTAssertEqual(candidate.feeSource, .slider)
            XCTAssertNil(estimate.info)
        case .safe, .userControlledUnsafe, .unavailable:
            XCTFail("The slider's known priority should be reusable")
        }
    }

    func testPreflightLegacyAutomaticRefreshIncludesHeadroom() {
        let chainID = 9_025
        let ethereum = Ethereum(rpc: makeEIP1559RPCStub(chainID: chainID))
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/preflight-legacy-headroom"
        )

        let automatic = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: nil),
            preparedFee: .legacy(gasPrice: 10),
            feeProvenance: TransactionFeeProvenance(
                gasPrice: .automatic
            ),
            currentBaseFeePerGas: 100
        )
        switch preflight(automatic, using: ethereum, network: network) {
        case .walletManagedUpdated(let candidate, _):
            XCTAssertEqual(candidate.preparedFee, .legacy(gasPrice: 125))
            XCTAssertEqual(
                candidate.feeProvenance,
                TransactionFeeProvenance(gasPrice: .automatic)
            )
        case .safe, .userControlledUnsafe, .unavailable:
            XCTFail("A stale automatic legacy fee refreshes with headroom")
        }

        let slider = Transaction(
            from: "0x1",
            to: "0x2",
            gas: "0x5208",
            value: "0x0",
            data: "0x",
            feeIntent: .legacy(gasPrice: nil),
            preparedFee: .legacy(gasPrice: 10),
            feeProvenance: TransactionFeeProvenance(
                gasPrice: .slider
            ),
            currentBaseFeePerGas: 100
        )
        switch preflight(slider, using: ethereum, network: network) {
        case .walletManagedUpdated(let candidate, _):
            XCTAssertEqual(candidate.preparedFee, .legacy(gasPrice: 112))
            XCTAssertEqual(candidate.feeSource, .slider)
        case .safe, .userControlledUnsafe, .unavailable:
            XCTFail("A stale slider legacy fee refreshes without headroom")
        }
    }

    func testPreflightRequiresCanonicalNonzeroGasLimit() {
        let chainID = 9_015
        let ethereum = Ethereum(rpc: makeEIP1559RPCStub(chainID: chainID))
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/preflight-gas-validation"
        )

        for gas in [nil, "0x0", "0x00", "not-hex"] as [String?] {
            let transaction = Transaction(
                from: "0x1",
                to: "0x2",
                gas: gas,
                value: "0x0",
                data: "0x",
                preparedFee: .eip1559(
                    maxPriorityFeePerGas: 2,
                    maxFeePerGas: 222
                ),
                feeSource: .automatic,
                currentBaseFeePerGas: 100
            )

            switch preflight(
                transaction,
                using: ethereum,
                network: network
            ) {
            case .unavailable(let candidate, _):
                XCTAssertEqual(candidate.gas, gas)
            case .safe, .walletManagedUpdated, .userControlledUnsafe:
                XCTFail("Invalid gas unexpectedly passed preflight: \(gas ?? "nil")")
            }
        }
    }

    func testPreflightSafeFeeProductAcceptsBoundaryAndRejectsOneOver() {
        let chainID = 9_016
        let ethereum = Ethereum(rpc: makeEIP1559RPCStub(chainID: chainID))
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/preflight-safe-product"
        )
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let gasBoundary = maximum.quotientAndRemainder(
            dividingBy: 222
        ).quotient

        func transaction(gasLimit: BigUInt) -> Transaction {
            Transaction(
                from: "0x1",
                to: "0x2",
                gas: gasLimit.toHexString(withPrefix: true),
                value: "0x0",
                data: "0x",
                preparedFee: .eip1559(
                    maxPriorityFeePerGas: 2,
                    maxFeePerGas: 222
                ),
                feeSource: .automatic,
                currentBaseFeePerGas: 100
            )
        }

        switch preflight(
            transaction(gasLimit: gasBoundary),
            using: ethereum,
            network: network
        ) {
        case .safe:
            break
        case .walletManagedUpdated, .userControlledUnsafe, .unavailable:
            XCTFail("The maximum safe fee product was rejected")
        }

        switch preflight(
            transaction(gasLimit: gasBoundary + BigUInt(1)),
            using: ethereum,
            network: network
        ) {
        case .unavailable:
            break
        case .safe, .walletManagedUpdated, .userControlledUnsafe:
            XCTFail("A one-over-uint256 wallet fee product was accepted")
        }
    }

    func testPreflightPreservesOverflowingUserFeeForEditing() {
        let chainID = 9_017
        let ethereum = Ethereum(rpc: makeEIP1559RPCStub(chainID: chainID))
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/preflight-user-product"
        )
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let gasBoundary = maximum.quotientAndRemainder(
            dividingBy: 222
        ).quotient
        let fee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 2,
            maxFeePerGas: 222
        )
        let transaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: (gasBoundary + BigUInt(1)).toHexString(withPrefix: true),
            value: "0x0",
            data: "0x",
            preparedFee: fee,
            feeSource: .dapp,
            currentBaseFeePerGas: 100
        )

        switch preflight(transaction, using: ethereum, network: network) {
        case .userControlledUnsafe(let candidate, _):
            XCTAssertEqual(candidate.id, transaction.id)
            XCTAssertEqual(candidate.preparedFee, fee)
            XCTAssertEqual(candidate.feeSource, .dapp)
        case .safe, .walletManagedUpdated, .unavailable:
            XCTFail("An overflowing dapp fee should remain editable")
        }

        let mixedProvenance = TransactionFeeProvenance(
            maxPriorityFeePerGas: .manual,
            maxFeePerGas: .automatic
        )
        let mixedTransaction = Transaction(
            from: "0x1",
            to: "0x2",
            gas: (gasBoundary + BigUInt(1)).toHexString(withPrefix: true),
            value: "0x0",
            data: "0x",
            preparedFee: fee,
            feeProvenance: mixedProvenance,
            currentBaseFeePerGas: 100
        )

        switch preflight(
            mixedTransaction,
            using: ethereum,
            network: network
        ) {
        case .userControlledUnsafe(let candidate, _):
            XCTAssertEqual(candidate.id, mixedTransaction.id)
            XCTAssertEqual(candidate.preparedFee, fee)
            XCTAssertEqual(candidate.feeProvenance, mixedProvenance)
        case .safe, .walletManagedUpdated, .unavailable:
            XCTFail("A manual priority with a wallet cap should remain editable")
        }
    }

    func testPreflightWalletRefreshChecksFeeProductBoundary() {
        let chainID = 9_018
        let ethereum = Ethereum(rpc: makeEIP1559RPCStub(chainID: chainID))
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/preflight-refreshed-product"
        )
        let maximum = BigUInt(data: Data(repeating: 0xff, count: 32))
        let gasBoundary = maximum.quotientAndRemainder(
            dividingBy: 222
        ).quotient
        let staleFee = PreparedTransactionFee.eip1559(
            maxPriorityFeePerGas: 1,
            maxFeePerGas: 101
        )

        func transaction(gasLimit: BigUInt) -> Transaction {
            Transaction(
                from: "0x1",
                to: "0x2",
                gas: gasLimit.toHexString(withPrefix: true),
                value: "0x0",
                data: "0x",
                feeIntent: .automatic,
                preparedFee: staleFee,
                feeSource: .automatic,
                currentBaseFeePerGas: 50
            )
        }

        switch preflight(
            transaction(gasLimit: gasBoundary),
            using: ethereum,
            network: network
        ) {
        case .walletManagedUpdated(let candidate, _):
            XCTAssertEqual(
                candidate.preparedFee,
                .eip1559(
                    maxPriorityFeePerGas: 2,
                    maxFeePerGas: 222
                )
            )
        case .safe, .userControlledUnsafe, .unavailable:
            XCTFail("A boundary-safe wallet refresh was rejected")
        }

        let overflowing = transaction(
            gasLimit: gasBoundary + BigUInt(1)
        )
        switch preflight(
            overflowing,
            using: ethereum,
            network: network
        ) {
        case .unavailable(let candidate, _):
            XCTAssertEqual(candidate.id, overflowing.id)
            XCTAssertEqual(candidate.preparedFee, staleFee)
        case .safe, .walletManagedUpdated, .userControlledUnsafe:
            XCTFail("An overflowing refreshed cap was accepted")
        }
    }

    func testEstimateSuggestedFeeRespectsRequestedFeeModel() {
        let dynamic = GasService.Estimate(
            info: GasService.Info(
                recommendedPriorityFee: 2,
                highPriorityFee: 4
            ),
            nextBaseFee: 110,
            currentBaseFee: 100,
            support: .eip1559,
            gasPrice: 999
        )

        XCTAssertEqual(
            dynamic.suggestedFee(for: .automatic),
            .eip1559(maxPriorityFeePerGas: 2, maxFeePerGas: 222)
        )
        XCTAssertEqual(
            dynamic.suggestedFee(
                for: .eip1559(
                    maxPriorityFeePerGas: 99,
                    maxFeePerGas: 100
                )
            ),
            .eip1559(maxPriorityFeePerGas: 2, maxFeePerGas: 222)
        )
        XCTAssertEqual(
            dynamic.suggestedFee(for: .legacy(gasPrice: nil)),
            .legacy(gasPrice: 125)
        )

        let legacy = GasService.Estimate(
            info: nil,
            nextBaseFee: nil,
            support: .legacy,
            gasPrice: 70
        )
        XCTAssertEqual(
            legacy.suggestedFee(for: .automatic),
            .legacy(gasPrice: 70)
        )
        XCTAssertNil(
            legacy.suggestedFee(
                for: .eip1559(
                    maxPriorityFeePerGas: nil,
                    maxFeePerGas: nil
                )
            )
        )
    }

    func testChainMismatchStopsBeforeEveryFeeMarketRPC() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x2"),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x64",
                        next: "0x6e"
                    ),
                    reward: fullRewards(["0x2", "0x4"])
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x64")
                )
            ),
            gasPriceResult: .success("0x70")
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            endpoint: endpoint(rpcURL + "/wrong-chain"),
            chainID: 1,
            description: "chain mismatch"
        )

        XCTAssertEqual(estimate.support, .unknown)
        XCTAssertEqual(estimate.endpointChainID, 2)
        XCTAssertEqual(rpc.chainIDCallCount, 1)
        XCTAssertEqual(rpc.latestBlockCallCount, 0)
        XCTAssertEqual(rpc.feeHistoryCallCount, 0)
        XCTAssertEqual(rpc.maxPriorityFeeCallCount, 0)
        XCTAssertEqual(rpc.gasPriceCallCount, 0)
    }

    func testUnparseableChainIdentityProceedsUnverifiedWithoutCaching() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let target = endpoint(rpcURL + "/malformed-chain")
        let unparseableRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0xzz"),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x64",
                        next: "0x6e"
                    ),
                    reward: fullRewards(["0x2", "0x4"])
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x64")
                )
            )
        )

        let unverified = fetchEstimate(
            using: GasService(rpc: unparseableRPC),
            endpoint: target,
            chainID: 1,
            description: "unparseable chain identity"
        )
        XCTAssertEqual(unverified.support, .eip1559)
        XCTAssertNil(unverified.endpointChainID)
        XCTAssertEqual(unparseableRPC.chainIDCallCount, 1)
        XCTAssertEqual(unparseableRPC.latestBlockCallCount, 1)
        XCTAssertEqual(unparseableRPC.feeHistoryCallCount, 1)

        let legacyShapedRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0x1"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x70")
        )
        let legacyDetection = fetchEstimate(
            using: GasService(rpc: legacyShapedRPC),
            endpoint: target,
            chainID: 1,
            description: "post-unverified legacy detection"
        )
        XCTAssertEqual(legacyDetection.support, .legacy)
        XCTAssertEqual(legacyDetection.endpointChainID, 1)
        XCTAssertEqual(legacyShapedRPC.latestBlockCallCount, 1)
        XCTAssertEqual(legacyShapedRPC.feeHistoryCallCount, 1)
    }

    func testChainIdMethodMissingProceedsUnverifiedWithoutCaching() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let target = endpoint(rpcURL + "/chain-id-method-missing")
        let noChainIDRPC = EthereumCoreRPCStub(
            chainIDResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x64",
                        next: "0x6e"
                    ),
                    reward: fullRewards(["0x2", "0x4"])
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x64")
                )
            )
        )

        let unverified = fetchEstimate(
            using: GasService(rpc: noChainIDRPC),
            endpoint: target,
            chainID: 1,
            description: "chain id method missing"
        )
        XCTAssertEqual(unverified.support, .eip1559)
        XCTAssertNil(unverified.endpointChainID)
        XCTAssertEqual(unverified.nextBaseFee, 110)
        XCTAssertEqual(noChainIDRPC.chainIDCallCount, 1)
        XCTAssertEqual(noChainIDRPC.latestBlockCallCount, 1)
        XCTAssertEqual(noChainIDRPC.feeHistoryCallCount, 1)

        let legacyShapedRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0x1"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x70")
        )
        let legacyDetection = fetchEstimate(
            using: GasService(rpc: legacyShapedRPC),
            endpoint: target,
            chainID: 1,
            description: "re-detection without cache"
        )
        XCTAssertEqual(legacyDetection.support, .legacy)
        XCTAssertEqual(legacyDetection.endpointChainID, 1)
        XCTAssertEqual(legacyDetection.gasPrice, 112)
    }

    func testChainIdTransientFailureProceedsUnverified() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .failure(StubError.expected),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x64",
                        next: "0x6e"
                    ),
                    reward: fullRewards(["0x2", "0x4"])
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x64")
                )
            )
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            endpoint: endpoint(rpcURL + "/chain-id-transient-failure"),
            chainID: 1,
            description: "transient chain id failure"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertNil(estimate.endpointChainID)
        XCTAssertEqual(estimate.info?.recommendedPriorityFee, 2)
        XCTAssertEqual(rpc.chainIDCallCount, 1)
        XCTAssertEqual(rpc.latestBlockCallCount, 1)
        XCTAssertEqual(rpc.feeHistoryCallCount, 1)
    }

    func testDappPricedTransactionSendsOnChainIdLessEndpoint() throws {
        let chainID = 9_026
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x64")
        )
        let ethereum = Ethereum(rpc: rpc)
        let network = makeNetwork(
            chainID: chainID,
            rpcURL: rpcURL + "/chain-id-less-send"
        )
        let transaction = Transaction(
            from: "0x0000000000000000000000000000000000000001",
            to: "0x0000000000000000000000000000000000000002",
            nonce: "0x0",
            gasPrice: "0x64",
            gas: "0x5208",
            value: "0x0",
            data: "0x"
        )

        let prepared = prepare(
            transaction,
            using: ethereum,
            network: network,
            description: "dapp-priced chain-id-less preparation"
        )
        XCTAssertEqual(prepared?.preparedFee, .legacy(gasPrice: 100))
        XCTAssertEqual(prepared?.feeProvenance.gasPrice, .dapp)

        let privateKey = try XCTUnwrap(
            WalletPrivateKey(
                data: Data(repeating: 0, count: 31) + Data([1])
            )
        )
        let sent = expectation(description: "chain-id-less send")
        ethereum.send(
            transaction: try XCTUnwrap(prepared),
            privateKey: privateKey,
            network: network
        ) { result in
            XCTAssertEqual(try? result.get(), "0xtransaction")
            sent.fulfill()
        }

        wait(for: [sent], timeout: 2)
        XCTAssertEqual(rpc.sentRawTransactions.count, 1)
    }

    func testBlockFetchFailureFallsBackToLegacyGasPricing() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let target = endpoint(rpcURL + "/block-fetch-legacy-fallback")
        let blocklessRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0x1"),
            latestBlockResult: .failure(StubError.expected),
            gasPriceResult: .success("0x64")
        )

        let fallback = fetchEstimate(
            using: GasService(rpc: blocklessRPC),
            endpoint: target,
            chainID: 1,
            description: "block fetch failure fallback"
        )
        XCTAssertEqual(fallback.support, .legacy)
        XCTAssertEqual(fallback.gasPrice, 100)
        XCTAssertEqual(fallback.endpointChainID, 1)
        XCTAssertNil(fallback.nextBaseFee)
        XCTAssertEqual(blocklessRPC.latestBlockCallCount, 1)
        XCTAssertEqual(blocklessRPC.feeHistoryCallCount, 0)

        let transientRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0x1"),
            feeHistoryResult: .failure(StubError.expected),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x2",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x65")
        )
        let transientProbe = fetchEstimate(
            using: GasService(rpc: transientRPC),
            endpoint: target,
            chainID: 1,
            description: "uncached legacy fallback probe"
        )
        XCTAssertEqual(transientProbe.support, .unknown)

        let recoveredRPC = makeEIP1559RPCStub(chainID: 1)
        let recovered = fetchEstimate(
            using: GasService(rpc: recoveredRPC),
            endpoint: target,
            chainID: 1,
            description: "eip1559 re-detection after fallback"
        )
        XCTAssertEqual(recovered.support, .eip1559)
        XCTAssertEqual(recoveredRPC.feeHistoryCallCount, 1)
    }

    func testBlockFetchFailureWithEIP1559HintStaysUnknown() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let url = URL(string: rpcURL + "/hinted-block-fetch-failure")!
        let target = EthereumRPCEndpoint.catalog(
            url,
            alchemyNetwork: nil,
            feeMarketHint: EthereumFeeMarketHint(
                support: .eip1559,
                checkedAt: ISO8601DateFormatter().string(from: Date()),
                observedEndpoint: url.absoluteString
            )
        )
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x1"),
            latestBlockResult: .failure(StubError.expected),
            gasPriceResult: .success("0x64")
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            endpoint: target,
            chainID: 1,
            description: "hinted block fetch failure"
        )

        XCTAssertEqual(
            estimate.support,
            .unknown,
            "A known fee-market chain is never legacy-priced off a failed block fetch"
        )
        XCTAssertEqual(estimate.endpointChainID, 1)
        XCTAssertEqual(rpc.latestBlockCallCount, 1)
        XCTAssertEqual(rpc.feeHistoryCallCount, 0)
    }

    func testNilExpectedChainDetectsWithoutIdentityCallOrCache() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let target = endpoint(rpcURL + "/identity-compatibility")

        for index in 0..<2 {
            let rpc = FakeEthereumRPCClient(
                feeHistoryResult: .success(
                    EthereumFeeHistory(
                        baseFeePerGas: fullBaseFees(
                            current: "0x64",
                            next: "0x6e"
                        ),
                        reward: fullRewards(
                            ["0x2", "0x4"]
                        )
                    )
                )
            )
            let estimate = fetchEstimate(
                using: GasService(rpc: rpc),
                endpoint: target,
                description: "compatibility detection \(index)"
            )

            XCTAssertEqual(estimate.support, .eip1559)
            XCTAssertNil(estimate.endpointChainID)
            XCTAssertEqual(rpc.chainIDCallCount, 0)
            XCTAssertEqual(rpc.latestBlockCallCount, 1)
            XCTAssertEqual(rpc.feeHistoryCalls.count, 1)
        }
    }

    func testCapabilityCacheIsKeyedByChainAndEndpoint() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let firstEndpoint = endpoint(rpcURL + "/capability-key-a")
        let secondEndpoint = endpoint(rpcURL + "/capability-key-b")
        let legacyRPC = EthereumCoreRPCStub(
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x70")
        )

        let initial = fetchEstimate(
            using: GasService(rpc: legacyRPC),
            endpoint: firstEndpoint,
            chainID: 1,
            description: "initial legacy detection"
        )
        XCTAssertEqual(initial.support, .legacy)
        XCTAssertEqual(initial.endpointChainID, 1)
        XCTAssertEqual(legacyRPC.chainIDCallCount, 1)
        XCTAssertEqual(legacyRPC.feeHistoryCallCount, 1)
        XCTAssertEqual(legacyRPC.latestBlockCallCount, 1)

        let eipRPC = makeEIP1559RPCStub(chainID: 2)
        let cached = fetchEstimate(
            using: GasService(rpc: eipRPC),
            endpoint: firstEndpoint,
            chainID: 1,
            description: "cached legacy detection"
        )
        XCTAssertEqual(cached.support, .unknown)
        XCTAssertEqual(cached.endpointChainID, 2)
        XCTAssertEqual(eipRPC.chainIDCallCount, 1)
        XCTAssertEqual(eipRPC.feeHistoryCallCount, 0)
        XCTAssertEqual(eipRPC.latestBlockCallCount, 0)

        let otherChain = fetchEstimate(
            using: GasService(rpc: eipRPC),
            endpoint: firstEndpoint,
            chainID: 2,
            description: "other-chain detection"
        )
        XCTAssertEqual(otherChain.support, .eip1559)
        XCTAssertEqual(otherChain.endpointChainID, 2)
        XCTAssertEqual(eipRPC.chainIDCallCount, 2)
        XCTAssertEqual(eipRPC.feeHistoryCallCount, 1)
        XCTAssertEqual(eipRPC.latestBlockCallCount, 1)

        let otherEndpointRPC = makeEIP1559RPCStub(chainID: 1)
        let otherEndpoint = fetchEstimate(
            using: GasService(rpc: otherEndpointRPC),
            endpoint: secondEndpoint,
            chainID: 1,
            description: "other-endpoint detection"
        )
        XCTAssertEqual(otherEndpoint.support, .eip1559)
        XCTAssertEqual(otherEndpointRPC.feeHistoryCallCount, 1)
        XCTAssertEqual(otherEndpointRPC.latestBlockCallCount, 1)
    }

    func testCatalogCapabilityHintsNeverBypassChainIdentity() {
        let checkedAt = ISO8601DateFormatter().string(from: Date())

        for support in [
            EthereumFeeMarketSupport.eip1559,
            EthereumFeeMarketSupport.legacy,
        ] {
            let url = URL(
                string: rpcURL + "/hint-identity-\(support.rawValue)"
            )!
            let target = EthereumRPCEndpoint.catalog(
                url,
                alchemyNetwork: nil,
                feeMarketHint: EthereumFeeMarketHint(
                    support: support,
                    checkedAt: checkedAt,
                    observedEndpoint: url.absoluteString
                )
            )
            let rpc = makeEIP1559RPCStub(chainID: 2)

            let estimate = fetchEstimate(
                using: GasService(rpc: rpc),
                endpoint: target,
                chainID: 1,
                description: "\(support.rawValue) hint identity"
            )

            XCTAssertEqual(estimate.support, .unknown)
            XCTAssertEqual(estimate.endpointChainID, 2)
            XCTAssertEqual(rpc.chainIDCallCount, 1)
            XCTAssertEqual(rpc.latestBlockCallCount, 0)
            XCTAssertEqual(rpc.feeHistoryCallCount, 0)
            XCTAssertEqual(rpc.maxPriorityFeeCallCount, 0)
            XCTAssertEqual(rpc.gasPriceCallCount, 0)
        }
    }

    func testCatalogLegacyObservationIsRevalidatedAfterNetworkUpgrade() {
        let url = URL(string: rpcURL + "/legacy-hint-upgrade")!
        let target = EthereumRPCEndpoint.catalog(
            url,
            alchemyNetwork: nil,
            feeMarketHint: EthereumFeeMarketHint(
                support: .legacy,
                checkedAt: ISO8601DateFormatter().string(from: Date()),
                observedEndpoint: url.absoluteString
            )
        )
        let rpc = makeEIP1559RPCStub(chainID: 1)

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            endpoint: target,
            chainID: 1,
            description: "legacy hint live upgrade"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertEqual(estimate.endpointChainID, 1)
        XCTAssertEqual(rpc.chainIDCallCount, 1)
        XCTAssertEqual(rpc.latestBlockCallCount, 1)
        XCTAssertEqual(rpc.feeHistoryCallCount, 1)
    }

    func testCachedLegacyCapabilityIsRevalidatedAfterNetworkUpgrade() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let target = endpoint(rpcURL + "/cached-legacy-upgrade")
        let legacyRPC = EthereumCoreRPCStub(
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x70")
        )
        XCTAssertEqual(
            fetchEstimate(
                using: GasService(rpc: legacyRPC),
                endpoint: target,
                chainID: 1,
                description: "prime legacy capability"
            ).support,
            .legacy
        )

        let upgradedRPC = makeEIP1559RPCStub(chainID: 1)
        let upgraded = fetchEstimate(
            using: GasService(rpc: upgradedRPC),
            endpoint: target,
            chainID: 1,
            description: "revalidate legacy capability"
        )

        XCTAssertEqual(upgraded.support, .eip1559)
        XCTAssertEqual(upgraded.endpointChainID, 1)
        XCTAssertEqual(upgradedRPC.chainIDCallCount, 1)
        XCTAssertEqual(upgradedRPC.latestBlockCallCount, 1)
        XCTAssertEqual(upgradedRPC.feeHistoryCallCount, 1)
    }

    func testLegacyFallbackSurvivesTransientLiveHistoryFailure() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let target = endpoint(rpcURL + "/cached-legacy-transient")
        let conclusiveLegacyRPC = EthereumCoreRPCStub(
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x70")
        )
        XCTAssertEqual(
            fetchEstimate(
                using: GasService(rpc: conclusiveLegacyRPC),
                endpoint: target,
                chainID: 1,
                description: "prime transient fallback"
            ).support,
            .legacy
        )
        let transientRPC = EthereumCoreRPCStub(
            feeHistoryResult: .failure(StubError.expected),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x2",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x71")
        )

        let fallback = fetchEstimate(
            using: GasService(rpc: transientRPC),
            endpoint: target,
            chainID: 1,
            description: "legacy transient fallback"
        )

        XCTAssertEqual(fallback.support, .legacy)
        XCTAssertEqual(fallback.endpointChainID, 1)
        XCTAssertEqual(fallback.gasPrice, 113)
        XCTAssertEqual(transientRPC.chainIDCallCount, 1)
        XCTAssertEqual(transientRPC.latestBlockCallCount, 1)
        XCTAssertEqual(transientRPC.feeHistoryCallCount, 1)
    }

    func testTransientCapabilityFailureIsNotCachedAsLegacy() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let target = endpoint(rpcURL + "/transient-capability")
        let transientRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0x21"),
            feeHistoryResult: .failure(StubError.expected),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x70")
        )

        let unknown = fetchEstimate(
            using: GasService(rpc: transientRPC),
            endpoint: target,
            chainID: 33,
            description: "transient unknown detection"
        )
        XCTAssertEqual(unknown.support, .unknown)

        let recoveredRPC = makeEIP1559RPCStub(chainID: 33)
        let recovered = fetchEstimate(
            using: GasService(rpc: recoveredRPC),
            endpoint: target,
            chainID: 33,
            description: "recovered capability detection"
        )
        XCTAssertEqual(recovered.support, .eip1559)
        XCTAssertEqual(recoveredRPC.feeHistoryCallCount, 1)
        XCTAssertEqual(recoveredRPC.latestBlockCallCount, 1)
    }

    func testValidBaseFeeEstablishesEIP1559WhenFeeHistoryIsUnsupported() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let rpc = EthereumCoreRPCStub(
            chainIDResult: .success("0x22"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x0")
                )
            ),
            maxPriorityFeeResult: .success("0x0")
        )

        let estimate = fetchEstimate(
            using: GasService(rpc: rpc),
            endpoint: endpoint(rpcURL + "/base-fee-without-history"),
            chainID: 34,
            description: "base fee capability"
        )

        XCTAssertEqual(estimate.support, .eip1559)
        XCTAssertEqual(estimate.currentBaseFee, 0)
        XCTAssertEqual(estimate.nextBaseFee, 0)
        XCTAssertEqual(estimate.info?.recommendedPriorityFee, 1)
        XCTAssertEqual(estimate.endpointChainID, 34)
    }

    func testContradictoryAndExplicitNullCapabilitySignalsRemainUnknown() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let validHistory = EthereumFeeHistory(
            baseFeePerGas: fullBaseFees(
                current: "0x64",
                next: "0x6e"
            ),
            reward: fullRewards(["0x2", "0x4"])
        )
        let contradictoryRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0x2c"),
            feeHistoryResult: .success(validHistory),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .missing
                )
            ),
            gasPriceResult: .success("0x70")
        )
        let contradiction = fetchEstimate(
            using: GasService(rpc: contradictoryRPC),
            endpoint: endpoint(rpcURL + "/contradictory-capability"),
            chainID: 44,
            description: "contradictory capability"
        )
        XCTAssertEqual(contradiction.support, .unknown)

        let explicitNullRPC = EthereumCoreRPCStub(
            chainIDResult: .success("0x2d"),
            feeHistoryResult: .failure(
                EthereumRPCError.serverError(
                    -32_601,
                    "Method not found"
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .null
                )
            ),
            gasPriceResult: .success("0x70")
        )
        let explicitNull = fetchEstimate(
            using: GasService(rpc: explicitNullRPC),
            endpoint: endpoint(rpcURL + "/null-capability"),
            chainID: 45,
            description: "explicit-null capability"
        )
        XCTAssertEqual(explicitNull.support, .unknown)
    }

    func testMissingOrMalformedBlockNumberNeverRequestsUnanchoredHistory() {
        GasService.resetCapabilityCacheForTests()
        defer { GasService.resetCapabilityCacheForTests() }
        let history = EthereumFeeHistory(
            baseFeePerGas: fullBaseFees(
                current: "0x64",
                next: "0x6e"
            ),
            reward: fullRewards(["0x2", "0x4"])
        )
        let fixtures: [(name: String, number: String?)] = [
            ("missing", nil),
            ("malformed", "latest"),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let rpc = EthereumCoreRPCStub(
                chainIDResult: .success(
                    String.hex(100 + index, withPrefix: true)
                ),
                feeHistoryResult: .success(history),
                latestBlockResult: .success(
                    EthereumLatestBlock(
                        number: fixture.number,
                        baseFeeField: .encoded("0x64")
                    )
                ),
                gasPriceResult: .success("0x70")
            )
            let estimate = fetchEstimate(
                using: GasService(rpc: rpc),
                endpoint: endpoint(
                    rpcURL + "/invalid-block-number-\(index)"
                ),
                chainID: 100 + index,
                description: fixture.name
            )

            XCTAssertEqual(estimate.support, .unknown, fixture.name)
            XCTAssertEqual(rpc.latestBlockCallCount, 1, fixture.name)
            XCTAssertEqual(rpc.feeHistoryCallCount, 0, fixture.name)
        }

        let paddedRPC = EthereumCoreRPCStub(
            chainIDResult: .success(String.hex(110, withPrefix: true)),
            feeHistoryResult: .success(history),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x01",
                    baseFeeField: .encoded("0x64")
                )
            ),
            gasPriceResult: .success("0x70")
        )
        let anchored = fetchEstimate(
            using: GasService(rpc: paddedRPC),
            endpoint: endpoint(rpcURL + "/padded-block-number"),
            chainID: 110,
            description: "padded block number"
        )

        XCTAssertEqual(paddedRPC.feeHistoryCallCount, 1)
        XCTAssertEqual(paddedRPC.feeHistoryNewestBlocks, ["0x1"])
        XCTAssertEqual(anchored.support, .eip1559)
        XCTAssertEqual(anchored.currentBaseFee, 100)
        XCTAssertEqual(anchored.nextBaseFee, 110)
        XCTAssertEqual(anchored.info?.recommendedPriorityFee, 2)
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
            let body = try Self.bodyData(from: request)
            let requestObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            let method = try XCTUnwrap(requestObject["method"] as? String)
            let result: Any
            switch method {
            case "eth_feeHistory":
                result = [
                    "baseFeePerGas":
                        Array(repeating: "0x1", count: 10) + ["0x64"],
                    "reward": [["0x1", 2]]
                ]
            case "eth_getBlockByNumber":
                result = ["number": "0x1", "baseFeePerGas": "0x1"]
            case "eth_maxPriorityFeePerGas":
                result = "0x1"
            default:
                throw StubError.expected
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": 1,
                "result": result
            ])
            return (response, data)
        }

        let estimate = fetchEstimate(using: GasService(rpc: EthereumRPC(urlSession: session)))

        XCTAssertEqual(requestCount.value, 3)
        XCTAssertEqual(curveValues(estimate.info), [1, 1, 1, 2])
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

    func testEthereumRPCBlocksRawSendRedirectOnInjectedSession() {
        let sourceURL = rpcURL + "/raw-send-redirect"
        let targetURL = rpcURL + "/raw-send-redirect-target"
        RedirectingGasServiceURLProtocol.configure(
            sourceURL: sourceURL,
            targetURL: targetURL
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            RedirectingGasServiceURLProtocol.self
        ]
        let session = URLSession(configuration: configuration)
        let completionReceived = expectation(
            description: "blocked raw-send redirect completed"
        )
        defer {
            session.invalidateAndCancel()
            RedirectingGasServiceURLProtocol.reset()
        }

        EthereumRPC(urlSession: session).sendRawTransaction(
            endpoint: endpoint(sourceURL),
            signedTxData: "0x01"
        ) { result in
            if case .success(let hash) = result {
                XCTFail("Unexpected redirected transaction hash: \(hash)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(
            RedirectingGasServiceURLProtocol.sourceRequestCount,
            1
        )
        XCTAssertEqual(
            RedirectingGasServiceURLProtocol.targetRequestCount,
            0
        )
        XCTAssertEqual(
            RedirectingGasServiceURLProtocol.sourceRequestBodies.count,
            1
        )
    }

    func testEthereumRPCRawSendPreservesInjectedSessionDelegateCallbacks()
        throws {
        let sendRPCURL = rpcURL + "/raw-send-session-delegate"
        let completionReceived = expectation(
            description: "raw-send completion received"
        )
        let sessionDelegate = RecordingRPCSessionDelegate()
        ChallengingGasServiceURLProtocol.configure(
            expectedURL: sendRPCURL
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ChallengingGasServiceURLProtocol.self
        ]
        let session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
        defer {
            session.invalidateAndCancel()
            ChallengingGasServiceURLProtocol.reset()
        }

        EthereumRPC(urlSession: session).sendRawTransaction(
            endpoint: endpoint(sendRPCURL),
            signedTxData: "0x01"
        ) { result in
            switch result {
            case .success(let hash):
                XCTAssertEqual(hash, "0xaccepted")
            case .failure(let error):
                XCTFail("Unexpected raw-send failure: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(
            ChallengingGasServiceURLProtocol.requestCount,
            1
        )
        XCTAssertEqual(sessionDelegate.challengeCount, 1)
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
            switch result {
            case .success(let hash):
                XCTFail("Unexpected transaction hash: \(hash)")
            case .failure(let error):
                XCTAssertEqual(error as? EthereumRPCError, .notSubmitted)
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived, unexpectedRequest], timeout: 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
    }

    func testEthereumRPCClassifiesInvalidEndpointAsNotSubmitted() {
        let completionReceived = expectation(
            description: "Invalid endpoint rejected before submission"
        )
        let invalidEndpoint = endpoint("rpc.example")
        XCTAssertNil(invalidEndpoint.url.scheme)

        EthereumRPC().sendRawTransaction(
            endpoint: invalidEndpoint,
            signedTxData: "0x01"
        ) { result in
            switch result {
            case .success(let hash):
                XCTFail("Unexpected transaction hash: \(hash)")
            case .failure(let error):
                XCTAssertEqual(error as? EthereumRPCError, .notSubmitted)
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 1)
    }

    func testEthereumRPCReturnsParsedRawSendResultFrom401WithoutReplay()
        throws {
        let requestCount = LockedCounter()
        let requestBodies = LockedDataRecorder()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "accepted raw transaction result returned"
        )
        let authorizationProvider =
            SequencedEthereumAuthorizationProviderStub(
                authorizations: [.success("rejected-token")],
                replacements: [.success("unused-replacement-token")]
            )
        defer {
            GasServiceURLProtocol.removeRequestHandler(for: alchemyRPCURL)
            session.invalidateAndCancel()
        }

        GasServiceURLProtocol.setRequestHandler(for: alchemyRPCURL) { request in
            _ = requestCount.increment()
            requestBodies.append(try Self.bodyData(from: request))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"0xaccepted"}"#.utf8
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
                XCTAssertEqual(hash, "0xaccepted")
            case .failure(let error):
                XCTFail("Unexpected raw-send failure: \(error)")
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(requestBodies.values.count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["rejected-token"]
        )
        XCTAssertEqual(
            authorizationProvider.invalidationURLs.map(\.absoluteString),
            [alchemyRPCURL]
        )
    }

    func testEthereumRPCNeverReplaysRawSendAfter401()
        throws {
        let requestCount = LockedCounter()
        let requestBodies = LockedDataRecorder()
        let session = makeRPCSession()
        let completionReceived = expectation(
            description: "raw transaction authorization failure returned"
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
            _ = requestCount.increment()
            requestBodies.append(try Self.bodyData(from: request))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
            )
            return (
                try Self.httpResponse(for: request, statusCode: 401),
                Data(
                    #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"FeeTooLow","data":null}}"#.utf8
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
                XCTFail("Unexpected transaction hash: \(hash)")
            case .failure(let error):
                XCTAssertEqual(
                    error as? EthereumRPCError,
                    .serverError(
                        -32_000,
                        "FeeTooLow",
                        dataJSON: "null"
                    )
                )
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(requestBodies.values.count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
    }

    func testEthereumRPCNeverReplaysRawSendWhen401AlsoHasTransferError()
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
            _ = requestCount.increment()
            requestBodies.append(try Self.bodyData(from: request))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
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
                XCTAssertEqual(error as? EthereumRPCError, .unknown)
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived], timeout: 2)
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(requestBodies.values.count, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
    }

    func testEthereumRPCInvalidatesFirstRejectedRawSendAuthorizationWithoutReplay()
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
            XCTAssertEqual(attempt, 1)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer rejected-token"
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
        XCTAssertEqual(requestCount.value, 1)
        XCTAssertEqual(requestBodies.values.count, 1)
        XCTAssertEqual(authorizationProvider.authorizationCallCount, 1)
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
        XCTAssertEqual(
            authorizationProvider.invalidatedTokens,
            ["rejected-token"]
        )
        XCTAssertEqual(
            authorizationProvider.invalidationURLs.map(\.absoluteString),
            [alchemyRPCURL]
        )
    }

    func testEthereumRPCDoesNotRequestReplacementAuthorizationForRawSend()
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
        XCTAssertEqual(authorizationProvider.replacementCallCount, 0)
        XCTAssertEqual(authorizationProvider.invalidationCallCount, 1)
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
                "error": [
                    "code": -32_601,
                    "message": "Method not found",
                    "data": [
                        "minimumPriorityFeePerGas": "0x1",
                        "baseFeePerGas": "0x132",
                    ],
                ],
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
                guard case let .serverError(
                    code,
                    message,
                    dataJSON
                ) = rpcError else {
                    XCTFail("Unexpected RPC error: \(rpcError)")
                    completionReceived.fulfill()
                    return
                }
                XCTAssertEqual(code, -32_601)
                XCTAssertEqual(message, "Method not found")
                XCTAssertEqual(
                    dataJSON,
                    #"{"baseFeePerGas":"0x132","minimumPriorityFeePerGas":"0x1"}"#
                )
            }
            completionReceived.fulfill()
        }

        wait(for: [completionReceived, unexpectedRetry], timeout: 1)
        XCTAssertEqual(requestCount.value, 1)
    }

    private func makeEIP1559RPCStub(
        chainID: Int = EthereumNetwork.ethMainnetChainId
    ) -> EthereumCoreRPCStub {
        EthereumCoreRPCStub(
            chainIDResult: .success(String.hex(chainID, withPrefix: true)),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: "0x64",
                        next: "0x6e"
                    ),
                    reward: fullRewards(
                        ["0x2", "0x4"]
                    )
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded("0x64")
                )
            ),
            maxPriorityFeeResult: .success("0x2"),
            gasPriceResult: .success("0x70")
        )
    }

    private func makeEIP1559RPCStubWithoutFeeSuggestion(
        chainID: Int,
        currentBaseFee: String = "0x64",
        nextBaseFee: String = "0x6e"
    ) -> EthereumCoreRPCStub {
        EthereumCoreRPCStub(
            chainIDResult: .success(
                String.hex(chainID, withPrefix: true)
            ),
            feeHistoryResult: .success(
                EthereumFeeHistory(
                    baseFeePerGas: fullBaseFees(
                        current: currentBaseFee,
                        next: nextBaseFee
                    ),
                    reward: nil
                )
            ),
            latestBlockResult: .success(
                EthereumLatestBlock(
                    number: "0x1",
                    baseFeeField: .encoded(currentBaseFee)
                )
            )
        )
    }

    private func prepare(
        _ transaction: Transaction,
        using ethereum: Ethereum,
        network: EthereumNetwork,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Transaction? {
        let completed = expectation(description: description)
        var prepared: Transaction?

        ethereum.prepareTransaction(
            transaction,
            forceGasCheck: false,
            network: network,
            onUpdate: { _ in },
            completion: { result in
                switch result {
                case .success(let transaction):
                    prepared = transaction
                case .failure(let failure):
                    XCTFail(
                        "Unexpected preparation failure: \(failure)",
                        file: file,
                        line: line
                    )
                }
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 2)
        return prepared
    }

    private func preflight(
        _ transaction: Transaction,
        using ethereum: Ethereum,
        network: EthereumNetwork,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TransactionFeePreflightResult {
        let completed = expectation(description: "fee preflight")
        var received: TransactionFeePreflightResult?

        ethereum.preflightTransactionFee(
            transaction,
            network: network
        ) { result in
            received = result
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        guard let received else {
            XCTFail(
                "Fee preflight did not complete",
                file: file,
                line: line
            )
            return .unavailable(
                transaction,
                GasService.Estimate(info: nil, nextBaseFee: nil)
            )
        }
        return received
    }

    private func fetchEstimate(
        using service: GasService,
        endpoint: EthereumRPCEndpoint? = nil,
        chainID: Int? = nil,
        description: String = "gas estimate",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GasService.Estimate {
        let completed = expectation(description: description)
        completed.assertForOverFulfill = true
        var receivedEstimate = GasService.Estimate(info: nil, nextBaseFee: nil)

        service.fetchEstimate(
            endpoint: endpoint ?? self.endpoint(rpcURL),
            chainID: chainID
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

    private func makeNetwork(
        chainID: Int,
        rpcURL: String? = nil,
        mightShowPrice: Bool = false
    ) -> EthereumNetwork {
        EthereumNetwork(
            chainId: chainID,
            name: "Test",
            symbol: "ETH",
            rpcEndpoint: endpoint(rpcURL ?? self.rpcURL),
            isTestnet: false,
            mightShowPrice: mightShowPrice,
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

private final class FakeEthereumRPCClient: EthereumFeeRPCClient {

    struct FeeHistoryCall {
        let endpoint: EthereumRPCEndpoint
        let blockCount: UInt
        let newestBlock: String
        let rewardPercentiles: [Double]

        var rpcURL: String { return endpoint.url.absoluteString }
        var allowsAlchemyAuthorization: Bool {
            return endpoint.allowsAlchemyAuthorization
        }
    }

    private let feeHistoryResult: Result<EthereumFeeHistory, Error>
    private let feeHistoryCompletionCount: Int
    private let chainIDResult: Result<String, Error>
    private let latestBlockResult: Result<EthereumLatestBlock, Error>?
    private let maxPriorityFeeResult: Result<String, Error>
    private let gasPriceResult: Result<String, Error>

    private(set) var feeHistoryCalls = [FeeHistoryCall]()
    private(set) var chainIDCallCount = 0
    private(set) var latestBlockCallCount = 0
    private(set) var maxPriorityFeeCallCount = 0
    private(set) var gasPriceCallCount = 0

    init(
        feeHistoryResult: Result<EthereumFeeHistory, Error>,
        feeHistoryCompletionCount: Int = 1,
        chainIDResult: Result<String, Error> = .success("0x1"),
        latestBlockResult: Result<EthereumLatestBlock, Error>? = nil,
        maxPriorityFeeResult: Result<String, Error> =
            .failure(StubError.expected),
        gasPriceResult: Result<String, Error> = .failure(StubError.expected)
    ) {
        self.feeHistoryResult = feeHistoryResult
        self.feeHistoryCompletionCount = feeHistoryCompletionCount
        self.chainIDResult = chainIDResult
        self.latestBlockResult = latestBlockResult
        self.maxPriorityFeeResult = maxPriorityFeeResult
        self.gasPriceResult = gasPriceResult
    }

    func fetchChainID(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        chainIDCallCount += 1
        completion(chainIDResult)
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        fetchFeeHistory(
            endpoint: endpoint,
            blockCount: blockCount,
            newestBlock: "latest",
            rewardPercentiles: rewardPercentiles,
            cancellation: cancellation,
            completion: completion
        )
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumFeeHistory, Error>) -> Void
    ) {
        feeHistoryCalls.append(FeeHistoryCall(
            endpoint: endpoint,
            blockCount: blockCount,
            newestBlock: newestBlock,
            rewardPercentiles: rewardPercentiles
        ))
        for _ in 0..<feeHistoryCompletionCount {
            completion(feeHistoryResult)
        }
    }

    func fetchLatestBlock(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<EthereumLatestBlock, Error>) -> Void
    ) {
        latestBlockCallCount += 1
        if let latestBlockResult {
            completion(latestBlockResult)
            return
        }
        switch feeHistoryResult {
        case .success(let history):
            let latestValue: String?
            if history.baseFeePerGas.count >= 2 {
                latestValue = history.baseFeePerGas[
                    history.baseFeePerGas.count - 2
                ]
            } else {
                latestValue = history.baseFeePerGas.last
            }
            let baseFee = latestValue.flatMap {
                BigUInt(hexString: $0)
            }.map { $0.toHexString(withPrefix: true) }
            completion(.success(EthereumLatestBlock(
                number: "0x1",
                baseFeeField: baseFee.map(
                    EthereumLatestBlock.BaseFeeField.encoded
                ) ?? .missing
            )))
        case .failure:
            completion(.success(EthereumLatestBlock(
                number: "0x1",
                baseFeeField: .missing
            )))
        }
    }

    func fetchMaxPriorityFeePerGas(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        maxPriorityFeeCallCount += 1
        completion(maxPriorityFeeResult)
    }

    func fetchGasPrice(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        gasPriceCallCount += 1
        completion(gasPriceResult)
    }

}

private final class EthereumCoreRPCStub: EthereumRPCClient {

    private let chainIDResult: Result<String, Swift.Error>
    private let feeHistoryResult: Result<EthereumFeeHistory, Swift.Error>
    private let latestBlockResult: Result<EthereumLatestBlock, Swift.Error>
    private let maxPriorityFeeResult: Result<String, Swift.Error>
    private let gasPriceResult: Result<String, Swift.Error>
    private let nonceResult: Result<String, Swift.Error>
    private let estimateGasResult: Result<String, Swift.Error>
    private let sendResult: Result<String, Swift.Error>

    private(set) var chainIDCallCount = 0
    private(set) var feeHistoryCallCount = 0
    private(set) var feeHistoryNewestBlocks = [String]()
    private(set) var latestBlockCallCount = 0
    private(set) var maxPriorityFeeCallCount = 0
    private(set) var gasPriceCallCount = 0
    private(set) var nonceCallCount = 0
    private(set) var estimateGasCallCount = 0
    private(set) var sentRawTransactions = [String]()

    init(
        chainIDResult: Result<String, Swift.Error> = .success("0x1"),
        feeHistoryResult: Result<EthereumFeeHistory, Swift.Error> =
            .failure(StubError.expected),
        latestBlockResult: Result<EthereumLatestBlock, Swift.Error> =
            .failure(StubError.expected),
        maxPriorityFeeResult: Result<String, Swift.Error> =
            .failure(StubError.expected),
        gasPriceResult: Result<String, Swift.Error> =
            .failure(StubError.expected),
        nonceResult: Result<String, Swift.Error> = .success("0x0"),
        estimateGasResult: Result<String, Swift.Error> = .success("0x5208"),
        sendResult: Result<String, Swift.Error> = .success("0xtransaction")
    ) {
        self.chainIDResult = chainIDResult
        self.feeHistoryResult = feeHistoryResult
        self.latestBlockResult = latestBlockResult
        self.maxPriorityFeeResult = maxPriorityFeeResult
        self.gasPriceResult = gasPriceResult
        self.nonceResult = nonceResult
        self.estimateGasResult = estimateGasResult
        self.sendResult = sendResult
    }

    func fetchChainID(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        chainIDCallCount += 1
        completion(chainIDResult)
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (
            Result<EthereumFeeHistory, Swift.Error>
        ) -> Void
    ) {
        fetchFeeHistory(
            endpoint: endpoint,
            blockCount: blockCount,
            newestBlock: "latest",
            rewardPercentiles: rewardPercentiles,
            cancellation: cancellation,
            completion: completion
        )
    }

    func fetchFeeHistory(
        endpoint: EthereumRPCEndpoint,
        blockCount: UInt,
        newestBlock: String,
        rewardPercentiles: [Double],
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (
            Result<EthereumFeeHistory, Swift.Error>
        ) -> Void
    ) {
        feeHistoryCallCount += 1
        feeHistoryNewestBlocks.append(newestBlock)
        completion(feeHistoryResult)
    }

    func fetchMaxPriorityFeePerGas(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        maxPriorityFeeCallCount += 1
        completion(maxPriorityFeeResult)
    }

    func fetchLatestBlock(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (
            Result<EthereumLatestBlock, Swift.Error>
        ) -> Void
    ) {
        latestBlockCallCount += 1
        completion(latestBlockResult)
    }

    func fetchGasPrice(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        gasPriceCallCount += 1
        completion(gasPriceResult)
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
        completion(nonceResult)
    }

    func estimateGas(
        endpoint: EthereumRPCEndpoint,
        transaction: Transaction,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        estimateGasCallCount += 1
        completion(estimateGasResult)
    }

    func sendRawTransaction(
        endpoint: EthereumRPCEndpoint,
        signedTxData: String,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        sentRawTransactions.append(signedTxData)
        completion(sendResult)
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

    func fetchChainID(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (Result<String, Swift.Error>) -> Void
    ) {
        completion(.success("0x1"))
    }

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

    func fetchLatestBlock(
        endpoint: EthereumRPCEndpoint,
        cancellation: EthereumRequestCancellation?,
        completion: @escaping (
            Result<EthereumLatestBlock, Swift.Error>
        ) -> Void
    ) {
        completion(.success(EthereumLatestBlock(
            number: "0x1",
            baseFeeField: .missing
        )))
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

private final class RecordingRPCSessionDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {

    private let lock = NSLock()
    private var storedChallengeCount = 0

    var challengeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedChallengeCount
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        lock.lock()
        storedChallengeCount += 1
        lock.unlock()
        completionHandler(.performDefaultHandling, nil)
    }
}

private final class RPCAuthenticationChallengeSender:
    NSObject,
    URLAuthenticationChallengeSender {

    private let lock = NSLock()
    private var resolution: ((Bool) -> Void)?

    init(resolution: @escaping (Bool) -> Void) {
        self.resolution = resolution
    }

    func use(
        _ credential: URLCredential,
        for challenge: URLAuthenticationChallenge
    ) {
        resolve(success: true)
    }

    func continueWithoutCredential(
        for challenge: URLAuthenticationChallenge
    ) {
        resolve(success: true)
    }

    func cancel(_ challenge: URLAuthenticationChallenge) {
        resolve(success: false)
    }

    func performDefaultHandling(
        for challenge: URLAuthenticationChallenge
    ) {
        resolve(success: true)
    }

    func rejectProtectionSpaceAndContinue(
        with challenge: URLAuthenticationChallenge
    ) {
        resolve(success: true)
    }

    private func resolve(success: Bool) {
        lock.lock()
        let resolution = resolution
        self.resolution = nil
        lock.unlock()
        resolution?(success)
    }
}

private final class ChallengingGasServiceURLProtocol: URLProtocol {

    private static let lock = NSLock()
    private static var expectedURL: String?
    private static var storedRequestCount = 0

    private var challengeSender: RPCAuthenticationChallengeSender?

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    static func configure(expectedURL: String) {
        lock.lock()
        self.expectedURL = expectedURL
        storedRequestCount = 0
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        expectedURL = nil
        storedRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            fail()
            return
        }

        Self.lock.lock()
        let isExpected = url.absoluteString == Self.expectedURL
        if isExpected {
            Self.storedRequestCount += 1
        }
        Self.lock.unlock()
        guard isExpected else {
            fail()
            return
        }

        let sender = RPCAuthenticationChallengeSender {
            [weak self] success in
            guard let self else { return }
            success ? self.finishSuccessfully() : self.fail()
        }
        challengeSender = sender
        let protectionSpace = URLProtectionSpace(
            host: url.host ?? "rpc.example",
            port: url.port ?? 443,
            protocol: url.scheme,
            realm: "test",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        client?.urlProtocol(
            self,
            didReceive: challenge
        )
    }

    override func stopLoading() {
        challengeSender = nil
    }

    private func finishSuccessfully() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            fail()
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(
                #"{"jsonrpc":"2.0","id":1,"result":"0xaccepted"}"#.utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
        challengeSender = nil
    }

    private func fail() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.userAuthenticationRequired)
        )
        challengeSender = nil
    }
}

private final class RedirectingGasServiceURLProtocol: URLProtocol {

    private static let lock = NSLock()
    private static var sourceURL: String?
    private static var targetURL: String?
    private static var storedSourceRequestCount = 0
    private static var storedTargetRequestCount = 0
    private static var storedSourceRequestBodies = [Data]()

    static var sourceRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSourceRequestCount
    }

    static var targetRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTargetRequestCount
    }

    static var sourceRequestBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedSourceRequestBodies
    }

    static func configure(sourceURL: String, targetURL: String) {
        lock.lock()
        self.sourceURL = sourceURL
        self.targetURL = targetURL
        storedSourceRequestCount = 0
        storedTargetRequestCount = 0
        storedSourceRequestBodies = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        sourceURL = nil
        targetURL = nil
        storedSourceRequestCount = 0
        storedTargetRequestCount = 0
        storedSourceRequestBodies = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: StubError.expected
            )
            return
        }

        Self.lock.lock()
        let sourceURL = Self.sourceURL
        let targetURL = Self.targetURL
        if requestURL.absoluteString == sourceURL {
            Self.storedSourceRequestCount += 1
            Self.storedSourceRequestBodies.append(
                request.httpBody ?? Data()
            )
        } else if requestURL.absoluteString == targetURL {
            Self.storedTargetRequestCount += 1
        }
        Self.lock.unlock()

        if requestURL.absoluteString == sourceURL,
           let targetURL,
           let redirectURL = URL(string: targetURL),
           let response = HTTPURLResponse(
               url: requestURL,
               statusCode: 307,
               httpVersion: "HTTP/1.1",
               headerFields: ["Location": targetURL]
           ) {
            var redirectedRequest = request
            redirectedRequest.url = redirectURL
            client?.urlProtocol(
                self,
                wasRedirectedTo: redirectedRequest,
                redirectResponse: response
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if requestURL.absoluteString == targetURL,
           let response = HTTPURLResponse(
               url: requestURL,
               statusCode: 200,
               httpVersion: "HTTP/1.1",
               headerFields: ["Content-Type": "application/json"]
           ) {
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(
                self,
                didLoad: Data(
                    #"{"jsonrpc":"2.0","id":1,"result":"0xredirected"}"#.utf8
                )
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        client?.urlProtocol(
            self,
            didFailWithError: StubError.expected
        )
    }

    override func stopLoading() {}
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

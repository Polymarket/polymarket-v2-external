// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BaseExchangeTest } from "./BaseExchangeTest.sol";
import { Exchange } from "@polymarket-v2/src/exchange/Exchange.sol";

contract ExchangeMathHarness is Exchange {
    // forgefmt: disable-next-item
    constructor(
        address positionManager,
        address combinatorialModule,
        address _feeReceiver,
        uint256 _maxFeeRate,
        address proxyFactory,
        address safeFactory,
        bytes32 proxyBytecodeHash,
        bytes32 safeBytecodeHash
    )
        Exchange(
            positionManager,
            combinatorialModule,
            _feeReceiver,
            _maxFeeRate,
            proxyFactory,
            safeFactory,
            proxyBytecodeHash,
            safeBytecodeHash
        )
    { }

    function calculateTakingAmount(uint256 makingAmount, uint256 makerAmount, uint256 takerAmount)
        external
        pure
        returns (uint256)
    {
        return _calculateTakingAmount(makingAmount, makerAmount, takerAmount);
    }
}

contract ExchangeMathTest is BaseExchangeTest {
    ExchangeMathHarness internal mathHarness;

    function setUp() public override {
        super.setUp();
        // forgefmt: disable-next-item
        mathHarness = new ExchangeMathHarness(
            address(positions.manager),
            address(combinatorialModule),
            feeReceiver,
            1000,
            address(proxyFactory),
            address(safeFactory),
            proxyFactory.bytecodeHash(),
            safeFactory.bytecodeHash()
        );
    }

    function test_calculateTakingAmount_fuzz(uint64 making, uint128 makerAmount, uint128 takerAmount) public view {
        vm.assume(makerAmount > 0 && making <= makerAmount);
        uint256 expected = making * uint256(takerAmount) / uint256(makerAmount);
        assertEq(mathHarness.calculateTakingAmount(making, makerAmount, takerAmount), expected);
    }

    function test_complementaryAggregateCrossingInvariant_fuzz(
        uint64 takerMakerAmount,
        uint64 takerTakerAmount,
        uint64 makerAmount1,
        uint64 takerAmount1,
        uint64 fill1,
        uint64 makerAmount2,
        uint64 takerAmount2,
        uint64 fill2
    ) public view {
        vm.assume(takerMakerAmount > 0 && takerTakerAmount > 0);
        vm.assume(makerAmount1 > 0 && makerAmount2 > 0);
        vm.assume(fill1 <= makerAmount1 && fill2 <= makerAmount2);

        vm.assume(uint256(takerMakerAmount) * makerAmount1 >= uint256(takerTakerAmount) * takerAmount1);
        vm.assume(uint256(takerMakerAmount) * makerAmount2 >= uint256(takerTakerAmount) * takerAmount2);

        uint256 takerMakingAmount = mathHarness.calculateTakingAmount(fill1, makerAmount1, takerAmount1)
            + mathHarness.calculateTakingAmount(fill2, makerAmount2, takerAmount2);
        uint256 minimumTakerTakingAmount =
            mathHarness.calculateTakingAmount(takerMakingAmount, takerMakerAmount, takerTakerAmount);

        assertGe(uint256(fill1) + fill2, minimumTakerTakingAmount);
    }
}

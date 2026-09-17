// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Test } from "forge-std/Test.sol";
import { OptimisticOraclePayoutLib } from "@polymarket-v2/src/oracle/libraries/OptimisticOraclePayoutLib.sol";

/// @notice Wrapper contract to expose internal library functions for testing
contract OptimisticOraclePayoutLibHarness {
    function priceToPayouts(int256 _price, uint8 _n) external pure returns (uint256[] memory) {
        return OptimisticOraclePayoutLib.priceToPayouts(_price, _n);
    }
}

/// @notice Parent test contract for OptimisticOraclePayoutLib
contract OptimisticOraclePayoutLibTest is Test {
    OptimisticOraclePayoutLibHarness public harness;

    function setUp() public virtual {
        harness = new OptimisticOraclePayoutLibHarness();
    }
}

/*--------------------------------------------------------------
                    priceToPayouts
--------------------------------------------------------------*/

contract OptimisticOraclePayoutLibTest_priceToPayouts is OptimisticOraclePayoutLibTest {
    /// @notice YES price with single outcome returns [RESULT_DENOMINATOR]
    function test_yesPrice_singleOutcome() public view {
        // _price = 1e18 (YES), _n = 1
        uint256[] memory payouts = harness.priceToPayouts(1e18, 1);

        // Should return a single-element array with full denomination
        assertEq(payouts.length, 1);
        assertEq(payouts[0], 1_000_000);
    }

    /// @notice NO price with single outcome returns [0]
    function test_noPrice_singleOutcome() public view {
        // _price = 0 (NO), _n = 1
        uint256[] memory payouts = harness.priceToPayouts(0, 1);

        // Should return a single-element array with zero payout
        assertEq(payouts.length, 1);
        assertEq(payouts[0], 0);
    }

    /// @notice P3 price with single outcome returns [500_000] (50/50 split)
    function test_p3Price_singleOutcome() public view {
        // _price = 0.5e18 (P3 / indeterminate), _n = 1
        uint256[] memory payouts = harness.priceToPayouts(0.5e18, 1);

        // Should return half denomination for 50/50 split
        assertEq(payouts.length, 1);
        assertEq(payouts[0], 500_000);
    }

    /// @notice NUMERICAL with winner index 0 (price=0, n=3) returns [1_000_000, 0, 0]
    function test_numerical_winnerIndex0() public view {
        // _price = 0, _n = 3 -> winnerIndex = 0/1e18 = 0
        uint256[] memory payouts = harness.priceToPayouts(0, 3);

        // Winner-takes-all at index 0
        assertEq(payouts.length, 3);
        assertEq(payouts[0], 1_000_000);
        assertEq(payouts[1], 0);
        assertEq(payouts[2], 0);
    }

    /// @notice NUMERICAL with winner index 2 (price=2e18, n=3) returns [0, 0, 1_000_000]
    function test_numerical_winnerIndex2() public view {
        // _price = 2e18, _n = 3 -> winnerIndex = 2e18/1e18 = 2
        uint256[] memory payouts = harness.priceToPayouts(2e18, 3);

        // Winner-takes-all at index 2
        assertEq(payouts.length, 3);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 0);
        assertEq(payouts[2], 1_000_000);
    }

    /// @notice Reverts with ZeroOutcomes when n == 0
    function test_revert_zeroOutcomes() public {
        // Any price with _n = 0 must revert explicitly
        vm.expectRevert(OptimisticOraclePayoutLib.ZeroOutcomes.selector);
        harness.priceToPayouts(0, 0);
    }

    /// @notice Reverts with ZeroOutcomes when n == 0 for non-zero price
    function test_revert_zeroOutcomes_nonZeroPrice() public {
        // Non-zero price with _n = 0 must also revert
        vm.expectRevert(OptimisticOraclePayoutLib.ZeroOutcomes.selector);
        harness.priceToPayouts(1e18, 0);
    }
}

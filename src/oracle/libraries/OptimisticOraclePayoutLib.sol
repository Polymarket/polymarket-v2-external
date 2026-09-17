// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title OptimisticOraclePayoutLib
/// @author Polymarket
/// @notice Shared constants and price-to-payout conversion logic
library OptimisticOraclePayoutLib {
    /// @notice Thrown when the outcome count is zero.
    error ZeroOutcomes();

    /// @dev Identifier for YES/NO questions
    bytes32 internal constant BINARY_IDENTIFIER = bytes32("YES_OR_NO_QUERY");

    /// @dev Identifier for NUMERICAL questions (atomic NegRisk)
    bytes32 internal constant NUMERICAL_IDENTIFIER = bytes32("NUMERICAL");

    /// @dev Price for YES outcome
    int256 internal constant YES_PRICE = 1e18;

    /// @dev Price for NO outcome
    int256 internal constant NO_PRICE = 0;

    /// @dev Price indicating unknown/indeterminate outcome (P3)
    int256 internal constant P3_PRICE = 0.5e18;

    /// @dev Price indicating "too early" / unresolvable (P4)
    int256 internal constant P4_PRICE = type(int256).min;

    /// @dev Payout arrays must sum to this value
    uint256 internal constant RESULT_DENOMINATOR = 1_000_000;

    /// @notice Convert price to payout array
    /// @dev Invariant: `_n` must be >= 1. Callers enforce this upstream via
    ///      `_isValidPrice` and `_determineRequestShape`; this
    ///      function rejects `_n == 0` explicitly as a defense-in-depth
    ///      guard so NUMERICAL identifiers with zero outcomes cannot
    ///      silently produce an empty payout array.
    ///      n==1: YES/NO mapped to a single payout value for the first
    ///      position. This is the only shape produced by current requests
    ///      (`resultLength` is always 1); atomic NegRisk NUMERICAL prices
    ///      are translated to `[winnerIndex]` in `OOReporterModule` and
    ///      never reach this function.
    ///      n>1: legacy NUMERICAL winner-takes-all over n payout entries.
    /// @param _price The settled price reported by the optimistic oracle.
    /// @param _n The number of outcomes for the condition.
    /// @return payouts The payout array sized to `_n`.
    function priceToPayouts(int256 _price, uint16 _n) internal pure returns (uint256[] memory payouts) {
        if (_n == 0) revert ZeroOutcomes();
        payouts = new uint256[](_n);
        if (_n == 1) {
            if (_price == YES_PRICE) payouts[0] = RESULT_DENOMINATOR;
            else if (_price == P3_PRICE) payouts[0] = RESULT_DENOMINATOR / 2;
        } else {
            // NUMERICAL: winning index gets full denomination
            uint256 winnerIndex = uint256(_price) / 1e18;
            payouts[winnerIndex] = RESULT_DENOMINATOR;
        }
    }
}

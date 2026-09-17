// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IBinaryReporter } from "@polymarket-v2/src/oracle/interfaces/IBinaryReporter.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title BinaryReporterTargetMock
/// @notice Resolution target for `OracleAggregator._finalizeConditions`, recording the
///         `(conditionId, payouts)` pair the aggregator forwards.
/// @dev Stands in for BinaryModule / NegRiskModule as the `targetContract` of a request. It
///      exists to make the aggregator's downstream translation observable as SCALARS: the
///      aggregator itself only ever stores `keccak256(abi.encode(result))`, and a real module
///      would drag PositionManager, CollateralToken and ConditionalTokens into the scene
///      without adding anything to the relay claim.
///
///      Deliberately permissive: it never reverts and imposes no authorization, so it removes
///      no path from the aggregator's finalize flow.
contract BinaryReporterTargetMock is IBinaryReporter {
    /// @notice Number of results the aggregator has reported to this target.
    uint256 public reportCount;
    /// @notice Condition id of the most recent report, as a raw `bytes32`.
    bytes32 public lastConditionId;
    /// @notice Length of the most recent payout array.
    uint256 public lastResultLen;
    /// @notice First payout element of the most recent report (YES numerator).
    uint256 public lastResult0;
    /// @notice Second payout element of the most recent report (NO numerator).
    uint256 public lastResult1;

    /// @inheritdoc IBinaryReporter
    function reportResult(ConditionId _conditionId, uint256[] calldata _result) external {
        reportCount = reportCount + 1;
        lastConditionId = bytes32(ConditionId.unwrap(_conditionId));
        lastResultLen = _result.length;
        if (_result.length > 0) lastResult0 = _result[0];
        if (_result.length > 1) lastResult1 = _result[1];
    }
}

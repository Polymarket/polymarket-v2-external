// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ConditionId, PositionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title NegRiskRedeemHarness
/// @notice REDEEM-01 harness for NegRiskModule. Unlike NegRiskModuleHarness, this harness does
///         NOT override `getPayout` — so `redeem` exercises the genuine `BaseModule.getPayout`
///         arithmetic reading the real `result` mapping. It only adds pure ID derivation and
///         result-read helpers so CVL rules can name positions/conditions without re-implementing
///         the bit layout.
contract NegRiskRedeemHarness is NegRiskModule {
    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        address _negRiskAdapter,
        ResolutionChain _chain
    ) NegRiskModule(_positionManager, _conditionalTokens, _usdceToken, _negRiskAdapter, _chain) { }

    /// @notice Position ID (uint256) for `(_conditionId, _outcome)` — the ghostBalance key.
    function pidOf(ConditionId _conditionId, uint256 _outcome) external pure returns (uint256) {
        return PositionId.unwrap(_conditionId.computePositionId(_outcome));
    }

    /// @notice Position ID (typed) for `(_conditionId, _outcome)` — used to call `redeem`.
    function pidObj(ConditionId _conditionId, uint256 _outcome) external pure returns (PositionId) {
        return _conditionId.computePositionId(_outcome);
    }

    /// @notice Underlying uint256 of a typed `PositionId`.
    function pidUnwrap(PositionId _positionId) external pure returns (uint256) {
        return PositionId.unwrap(_positionId);
    }

    /// @notice Length of the stored result vector (0 = unresolved, 2 = resolved).
    function resultLen(ConditionId _conditionId) external view returns (uint256) {
        return result[_conditionId].length;
    }

    /// @notice Real stored YES numerator r0 (0 if unresolved). Reads the SAME `result` mapping
    ///         `getPayout` uses, and never reverts — safe to call on unresolved conditions.
    function realR0(ConditionId _conditionId) external view returns (uint256) {
        uint256[] memory r = result[_conditionId];
        return r.length == 2 ? r[0] : 0;
    }

    /// @notice Real stored NO numerator r1 (0 if unresolved). Same backing mapping as `getPayout`.
    function realR1(ConditionId _conditionId) external view returns (uint256) {
        uint256[] memory r = result[_conditionId];
        return r.length == 2 ? r[1] : 0;
    }

    /// @notice Length of the DERIVED result (getResult): sibling NO / synthetic Other
    ///         may be derivable with nothing stored (PR #290). Never reverts.
    function derivedLen(ConditionId _conditionId) external view returns (uint256) {
        return getResult(_conditionId).length;
    }

    /// @notice Derived YES numerator r0 (0 if underivable). Never reverts.
    function derivedR0(ConditionId _conditionId) external view returns (uint256) {
        uint256[] memory r = getResult(_conditionId);
        return r.length == 2 ? r[0] : 0;
    }

    /// @notice Derived NO numerator r1 (0 if underivable). Never reverts.
    function derivedR1(ConditionId _conditionId) external view returns (uint256) {
        uint256[] memory r = getResult(_conditionId);
        return r.length == 2 ? r[1] : 0;
    }
}

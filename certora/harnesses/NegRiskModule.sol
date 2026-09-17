// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { NegRiskModule as NegRiskModuleBase } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ConditionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title NegRiskModule verification harness
/// @notice Extends the production NegRiskModule with read-only views the solvency
///         spec needs but CVL cannot express. Named `NegRiskModule` (rename-import
///         of the base) so specs, links and UDVT qualifiers written against the
///         production name keep resolving when this harness replaces it in scene.
contract NegRiskModule is NegRiskModuleBase {
    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        address _negRiskAdapter,
        ResolutionChain _moduleResolutionChain
    )
        NegRiskModuleBase(_positionManager, _conditionalTokens, _usdceToken, _negRiskAdapter, _moduleResolutionChain)
    { }

    /// @notice True iff the condition has a stored (length-2) result.
    function conditionResolved(uint256 condKey) external view returns (bool) {
        return result[ConditionId.wrap(bytes31(bytes32(condKey)))].length == 2;
    }

    /// @notice The YES payout numerator r0 (result[0]) of a resolved condition (0 if unresolved).
    function conditionResultR0(uint256 condKey) external view returns (uint256) {
        uint256[] memory res = result[ConditionId.wrap(bytes31(bytes32(condKey)))];
        return res.length == 2 ? res[0] : 0;
    }

    /// @notice The NO payout numerator r1 (result[1]) of a resolved condition (0 if unresolved).
    ///         The spec assumes the _storeResult invariant r0 + r1 == RESULT_DENOMINATOR.
    function conditionResultR1(uint256 condKey) external view returns (uint256) {
        uint256[] memory res = result[ConditionId.wrap(bytes31(bytes32(condKey)))];
        return res.length == 2 ? res[1] : 0;
    }

    /// @notice True iff the condition belongs to a registered neg-risk migration event
    ///         (its parent event has a legacy event id and the index is a real condition).
    function isMigrationCondition(uint256 condKey) external view returns (bool) {
        return _isMigrationCondition(ConditionId.wrap(bytes31(bytes32(condKey))));
    }

    /// @notice The condKey (YES position id, outcome byte cleared) of a ConditionId.
    function condKeyOf(ConditionId c) external pure returns (uint256) {
        return uint256(bytes32(ConditionId.unwrap(c)));
    }

    /// @notice Structured condition key for a legacy CTF condition id (0 when unregistered):
    ///         the mapped ConditionId as uint256 — numerically the spec's condKey (position id
    ///         with the outcome byte cleared; the bytes31 UDVT zero-pads its low byte).
    function migrationCondKeyOf(bytes32 legacyConditionId) external view returns (uint256) {
        return uint256(bytes32(ConditionId.unwrap(legacyConditionToConditionId[legacyConditionId])));
    }

}
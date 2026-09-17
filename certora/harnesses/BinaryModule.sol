// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BinaryModule as BinaryModuleBase } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { ConditionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title BinaryModule verification harness
/// @notice Extends the production BinaryModule with read-only views the solvency
///         spec needs but CVL cannot express. Named `BinaryModule` (rename-import
///         of the base) so specs, links and UDVT qualifiers written against the
///         production name keep resolving when this harness replaces it in scene.
contract BinaryModule is BinaryModuleBase {
    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        ResolutionChain _moduleResolutionChain
    ) BinaryModuleBase(_positionManager, _conditionalTokens, _usdceToken, _moduleResolutionChain) { }

    /// @notice Resolution flag and both payout numerators of a condition in one call.
    function conditionResultData(uint256 condKey) external view returns (bool resolved, uint256 r0, uint256 r1) {
        uint256[] storage res = result[ConditionId.wrap(bytes31(bytes32(condKey)))];
        if (res.length == 2) {
            resolved = true;
            r0 = res[0];
            r1 = res[1];
        }
    }

    /// @notice True iff the condition is registered for legacy migration
    ///         (`legacyConditionId[C] != 0`).
    function isMigrationCondition(uint256 condKey) external view returns (bool) {
        return legacyConditionId[ConditionId.wrap(bytes31(bytes32(condKey)))] != bytes32(0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { ConditionId, PositionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title BinaryMigrationRealHarness
/// @notice CLEAN `BinaryModule` subclass with NO migration overrides, used ONLY by
///         certora/specs/eq/BinaryMigrationResolutionEquivalence.spec to run the REAL
///         migration-resolution body that `BinaryModuleHarness` replaces with an
///         over-approximation (`_finalizeMigrationResolution` #4 and
///         `_redeemIfResolvedDuringMigrate` #5). Because this contract does NOT override those
///         hooks, the wrappers below execute the untouched production logic
///         (`BaseMigrationMixin._redeemIfResolved` -> real `_finalizeMigrationResolution` ->
///         `BaseModule._storeResult`), including the legacy `p0 * DENOM / (p0 + p1)` division.
///         The equivalence spec compares that real behaviour against the two harness models.
contract BinaryMigrationRealHarness is BinaryModule {
    constructor(address _positionManager, address _conditionalTokens, address _usdceToken, ResolutionChain _chain)
        BinaryModule(_positionManager, _conditionalTokens, _usdceToken, _chain)
    { }

    /*--------------------------------------------------------------
       EQUIVALENCE-PROOF REAL-CODE WRAPPERS
    --------------------------------------------------------------*/
    // Thin external entry points that execute the real migration internals so the equivalence spec
    // can certify the BinaryModuleHarness over-approximations against them. They add no logic.

    /// @notice REAL migrate-loop redeem (production pass-through to `_redeemIfResolved`): reads the
    ///         legacy payout numerators, and on a first-time resolution stores the division-normalized
    ///         result through the REAL `_finalizeMigrationResolution` -> `_storeResult`, then redeems
    ///         the legacy positions. The #5 certification target.
    /// @return True iff the legacy CTF condition is resolved (payout denominator != 0).
    function redeemIfResolvedDuringMigrateReal(ConditionId _conditionId, bytes32 _legacyConditionId)
        external
        returns (bool)
    {
        return _redeemIfResolvedDuringMigrate(_conditionId, _legacyConditionId);
    }

    /// @notice REAL `_finalizeMigrationResolution` (store + emit, no override) — the #4 baseline
    ///         showing the production finalize stores its input result vector verbatim.
    function finalizeMigrationResolutionReal(ConditionId _conditionId, uint256[] memory _result) external {
        _finalizeMigrationResolution(_conditionId, _result);
    }

    /*--------------------------------------------------------------
       RESULT READS (same backing mapping `getPayout` uses)
    --------------------------------------------------------------*/

    /// @notice Length of the stored result vector (0 = unresolved, 2 = resolved).
    function resultLen(ConditionId _conditionId) external view returns (uint256) {
        return result[_conditionId].length;
    }

    /// @notice Real stored YES numerator r0 (0 if unresolved). Never reverts.
    function realR0(ConditionId _conditionId) external view returns (uint256) {
        uint256[] memory r = result[_conditionId];
        return r.length == 2 ? r[0] : 0;
    }

    /// @notice Real stored NO numerator r1 (0 if unresolved). Never reverts.
    function realR1(ConditionId _conditionId) external view returns (uint256) {
        uint256[] memory r = result[_conditionId];
        return r.length == 2 ? r[1] : 0;
    }

    /// @notice RESULT_DENOMINATOR (BaseModule constant) exposed for the spec's endpoint math.
    function resultDenominator() external pure returns (uint256) {
        return RESULT_DENOMINATOR;
    }
}

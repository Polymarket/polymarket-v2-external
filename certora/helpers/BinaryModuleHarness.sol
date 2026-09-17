// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { ConditionId, PositionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title BinaryModuleHarness
/// @notice Certora harness exposing pure ID derivation and result reads so CVL rules can
///         reason about position supplies / stored results without re-implementing the
///         bytes31/uint256 bit-layout inside the spec.
contract BinaryModuleHarness is BinaryModule {
    constructor(address _positionManager, address _conditionalTokens, address _usdceToken, ResolutionChain _chain)
        BinaryModule(_positionManager, _conditionalTokens, _usdceToken, _chain)
    { }

    /*--------------------------------------------------------------
       VERIFICATION SEAM — payout-division summarization (Solvency-02)
    --------------------------------------------------------------*/

    /// @dev Overrides the migration-resolution store so the solvency proof does not reason about
    ///      the legacy payout division `payout0 * DENOM / (payout0 + payout1)` that made
    ///      `postResolutionSolvencyMigrate` diverge (undecidable NIA leaves). Ignores the passed
    ///      (division-derived) result and stores a nondet-but-normalized one pinned to the binary
    ///      endpoints: r0 in {0, DENOM}, r1 = DENOM - r0.
    function _finalizeMigrationResolution(
        ConditionId _conditionId,
        uint256[] memory /* _result */
    )
        internal
        override
    {
        uint256 r0 = _nondetPayoutNumerator();
        require(r0 == 0 || r0 == RESULT_DENOMINATOR);
        uint256[] memory summarized = new uint256[](2);
        summarized[0] = r0;
        summarized[1] = RESULT_DENOMINATOR - r0;
        super._finalizeMigrationResolution(_conditionId, summarized);
    }

    /// @dev Nondet source for the summarized migration payout numerator. The body is irrelevant:
    ///      it is summarized to NONDET (an arbitrary uint256, then pinned to {0, DENOM} above).
    function _nondetPayoutNumerator() internal virtual returns (uint256) {
        return 0;
    }

    /// @dev Sound over-approximation of the migrate-loop redeem, opted into only by Binary-Solvency02
    ///      (via `_useMigrateRedeemModel => ALWAYS(true)` + `_nondetResolved => NONDET`). The migrate
    ///      loop unrolls `loop_iter` times over TWO loops, and the real `_redeemIfResolved` body inlined
    ///      per iteration (legacy payout reads, `p0 * D / den` division, legacy redeem, vault settle)
    ///      is what makes both migratePositions overloads diverge — the split space exploded to 560+
    ///      subproblems at ~25% weight even with the isolated confs. This override drops that whole
    ///      body but KEEPS the resolution store: on a nondet-resolved legacy condition whose V2
    ///      condition is unresolved, it stores through the real `_finalizeMigrationResolution` (the
    ///      override above pins r0 to {0, DENOM}). Because the store is retained, the resultLen 0->2
    ///      transition is still exercised; only the un-modelled legacy plumbing is elided.
    ///      Gated by `_useMigrateRedeemModel()` (default false), so `resolveMigrationCondition` and
    ///      every non-opted Binary spec keep the untouched production body through `super`.
    function _redeemIfResolvedDuringMigrate(ConditionId _conditionId, bytes32 _legacyConditionId)
        internal
        override
        returns (bool)
    {
        if (!_useMigrateRedeemModel()) {
            return super._redeemIfResolvedDuringMigrate(_conditionId, _legacyConditionId);
        }

        if (!_nondetResolved()) return false;
        if (result[_conditionId].length == 0) {
            // Content ignored by the `_finalizeMigrationResolution` override, which stores the
            // {0, DENOM}-pinned result itself; the length-2 array just satisfies the signature.
            _finalizeMigrationResolution(_conditionId, new uint256[](2));
        }
        return true;
    }

    /// @dev Gate for the migrate-redeem over-approximation. Defaults to false; the
    ///      opted-in spec summarizes it to `ALWAYS(true)`.
    function _useMigrateRedeemModel() internal virtual returns (bool) {
        return false;
    }

    /// @dev Nondet source: whether the legacy CTF condition is resolved. Summarized to NONDET.
    function _nondetResolved() internal virtual returns (bool) {
        return false;
    }

    /// @notice EQ target: runs the OVER-APPROX `_finalizeMigrationResolution` override (stores the
    ///         `{0, DENOM}`-pinned binary endpoint). Lets
    ///         certora/specs/eq/BinaryMigrationResolutionEquivalence.spec certify the #4 model store
    ///         lands on a valid binary endpoint. The passed length-2 array is ignored by the override
    ///         (which supplies its own `_nondetPayoutNumerator`-derived result).
    function finalizeMigrationResolutionModel(ConditionId _conditionId) external {
        _finalizeMigrationResolution(_conditionId, new uint256[](2));
    }

    /// @notice Position ID (uint256) for `(_conditionId, _outcome)` — used as the supply ghost key.
    function pidOf(ConditionId _conditionId, uint256 _outcome) external pure returns (uint256) {
        return PositionId.unwrap(_conditionId.computePositionId(_outcome));
    }

    /// @notice Position ID (typed) for `(_conditionId, _outcome)` — used to call `redeem`.
    function pidObj(ConditionId _conditionId, uint256 _outcome) external pure returns (PositionId) {
        return _conditionId.computePositionId(_outcome);
    }

    /// @notice Underlying uint256 of a typed `PositionId` — the ghostBalance key for BRIDGE-02.
    function pidUnwrap(PositionId _positionId) external pure returns (uint256) {
        return PositionId.unwrap(_positionId);
    }

    /// @notice Length of the stored result vector (0 = unresolved, 2 = resolved).
    function resultLen(ConditionId _conditionId) external view returns (uint256) {
        return result[_conditionId].length;
    }

    /// @notice Stored result numerator at index `_i`.
    function resultAt(ConditionId _conditionId, uint256 _i) external view returns (uint256) {
        return result[_conditionId][_i];
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

    /// @notice Whether the condition was registered as a legacy-migration condition.
    function isMigration(ConditionId _conditionId) external view returns (bool) {
        return _isMigrationCondition(_conditionId);
    }

    /// @notice YES position id (uint256) of the condition that `_positionId` belongs to.
    /// @dev Used by invariant specs to attribute a redeem's collateral op to its condition.
    function yesPidOf(PositionId _positionId) external pure returns (uint256) {
        return PositionId.unwrap(_positionId.conditionId().computePositionId(0));
    }
}

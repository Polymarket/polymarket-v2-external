// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import {
    ConditionId,
    EventId,
    PositionId,
    ResolutionChain,
    ConditionIdLib
} from "@polymarket-v2/src/libraries/Ids.sol";

/// @title NegRiskModuleHarness
/// @notice Certora harness exposing pure ID derivation, event/condition wiring, and result reads
///         so CVL rules can reason about position supplies / stored results without
///         re-implementing the bytes29/bytes31/uint256 bit-layout inside the spec.
contract NegRiskModuleHarness is NegRiskModule {
    /// @dev uint256-keyed mirror of `result[c]`, keyed by uint256(bytes32(conditionId)) (== YES pid).
    ///      Written by the `_storeResult` override below so CVL can hook a simple mapping instead
    ///      of the nested `mapping(ConditionId => uint256[])`. Captures ALL result writes,
    ///      including migration results.
    mapping(uint256 => uint256) public r0Mirror;
    mapping(uint256 => uint256) public r1Mirror;
    mapping(uint256 => uint256) public lenMirror;

    /// @dev Independent per-event sum of stored YES numerators (result[c][0]), keyed by
    ///      uint256(bytes32(eventId)). Re-derived from every `_storeResult` write WITHOUT
    ///      reading the production `resultsSum` counter, so proving `resultsSum[e] == yesSumOf(e)`
    ///      (MODU-INT-01) is a genuine cross-check of the contract's running tally and its
    ///      auto-derived synthetic-fallback result, for any arity.
    mapping(uint256 => uint256) public yesSumMirror;

    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        address _negRiskAdapter,
        ResolutionChain _chain
    ) NegRiskModule(_positionManager, _conditionalTokens, _usdceToken, _negRiskAdapter, _chain) { }

    /// @dev Mirror every stored result into uint256-keyed mappings. r0/r1 are written BEFORE the
    ///      length so the CVL `lenMirror` hook (which fires last) can read the final r0/r1.
    function _storeResult(ConditionId _conditionId, uint256[] memory _result) internal override {
        super._storeResult(_conditionId, _result);
        uint256 key = uint256(bytes32(ConditionId.unwrap(_conditionId)));
        r0Mirror[key] = _result[0];
        r1Mirror[key] = _result[1];
        // even if 2 is required for wsum seeding hook on the spec
        lenMirror[key] = _result.length;
        // Independently accumulate the YES numerator into its event's running sum.
        uint256 evk = uint256(bytes32(EventId.unwrap(_conditionId.eventId())));
        yesSumMirror[evk] = yesSumMirror[evk] + _result[0];
    }

    /// @notice Independent sum of stored YES numerators for `_eventId` (MODU-INT-01 ground truth).
    function yesSumOf(EventId _eventId) external view returns (uint256) {
        return yesSumMirror[uint256(bytes32(EventId.unwrap(_eventId)))];
    }

    /*--------------------------------------------------------------
       VERIFICATION SEAM — migration redeem over-approximation
    --------------------------------------------------------------*/

    /// @dev Optional sound over-approximation of the migrate-loop redeem, used only by specs that opt
    ///      in (via the `_useMigrateRedeemModel` / `_nondetResolved` / `_nondetBinaryR0` summaries).
    ///      Overrides only the migrate-loop wrapper, so `resolveMigrationCondition` — which calls
    ///      `_redeemIfResolved` directly — always keeps the real body (over-approximating it makes its
    ///      resolution nondet and its preserved case VACUOUS; that is the exact regression this
    ///      scoping avoids).
    ///      DEFAULT is the real body: `_useMigrateRedeemModel()` returns false unless summarized, so
    ///      every non-opted spec (ResultNorm01, MigrationCoupling01, Partition02, ModuleEscrow01, ...)
    ///      runs the untouched production logic through `super`.
    ///      When opted in, it drops the expensive parts of `_redeemIfResolved` (legacy payout reads,
    ///      the `p0 * D / den` division, the legacy redeem and vault settle) but KEEPS the resolution
    ///      store: on a (nondet) resolved legacy condition whose V2 condition is unresolved, it stores
    ///      a NONDET result through the REAL `_finalizeMigrationResolution` ->
    ///      `_finalizeNegriskResolution` -> `_storeResult` pipeline. `_storeResult` requires
    ///      `result0 in {0, D}` (proved binary in NegRisk-ResultNorm01), so the nondet result is
    ///      filtered to the SAME binary shape the real body computes. Hence it OVER-approximates the
    ///      real store (covers it, plus more) — unlike the earlier unsound drop-the-store summary.
    function _redeemIfResolvedDuringMigrate(ConditionId _conditionId, bytes32 _legacyConditionId)
        internal
        override
        returns (bool)
    {
        if (!_useMigrateRedeemModel()) return super._redeemIfResolvedDuringMigrate(_conditionId, _legacyConditionId);

        if (!_nondetResolved()) return false;
        if (result[_conditionId].length == 0) {
            uint256[] memory result_ = new uint256[](2);
            result_[0] = _nondetBinaryR0();
            result_[1] = RESULT_DENOMINATOR - result_[0];
            _finalizeMigrationResolution(_conditionId, result_);
        }
        return true;
    }

    /// @dev Gate for the redeem over-approximation. Defaults to false (real body); opted-in specs
    ///      summarize it to `ALWAYS(true)`.
    function _useMigrateRedeemModel() internal virtual returns (bool) {
        return false;
    }

    /// @dev Nondet source: whether the legacy CTF condition is resolved. Summarized to NONDET.
    function _nondetResolved() internal virtual returns (bool) {
        return false;
    }

    /// @dev Nondet source: the stored YES numerator. Summarized to NONDET; `_storeResult`'s binary
    ///      guard filters it to {0, D}.
    function _nondetBinaryR0() internal virtual returns (uint256) {
        return 0;
    }

    /// @notice conditionsResolved counter for the event that `_conditionId` belongs to.
    function conditionsResolvedByCond(ConditionId _conditionId) external view returns (uint256) {
        return conditionsResolved[_conditionId.eventId()];
    }

    /* ---------------------------------------------------------------
                         POSITION / CONDITION IDS
    --------------------------------------------------------------- */

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

    /// @notice Condition ID at index `_i` within event `_eventId`.
    function condAt(EventId _eventId, uint256 _i) external pure returns (ConditionId) {
        return _eventId.computeConditionId(_i);
    }

    /// @notice YES position id (uint256) of the condition that `_positionId` belongs to.
    /// @dev Used by invariant specs to attribute a redeem's collateral op to its condition.
    function yesPidOf(PositionId _positionId) external pure returns (uint256) {
        return PositionId.unwrap(_positionId.conditionId().computePositionId(0));
    }

    /// @notice Typed ConditionId that `_positionId` belongs to (for redeem requireInvariants).
    function condOf(PositionId _positionId) external pure returns (ConditionId) {
        return _positionId.conditionId();
    }

    /// @notice Typed EventId that `_positionId` belongs to (for event-level requireInvariants).
    function eventOfPid(PositionId _positionId) external pure returns (EventId) {
        return _positionId.conditionId().eventId();
    }

    /// @notice Typed EventId that `_conditionId` belongs to (for event-level requireInvariants).
    function eventOfCond(ConditionId _conditionId) external pure returns (EventId) {
        return _conditionId.eventId();
    }

    /* ---------------------------------------------------------------
                              EVENT KEYS
    --------------------------------------------------------------- */

    /// @notice Canonical uint256 key for an event (used as the `committed` ghost key).
    function evKey(EventId _eventId) external pure returns (uint256) {
        return uint256(bytes32(EventId.unwrap(_eventId)));
    }

    /// @notice Canonical uint256 event key of the event that `_conditionId` belongs to.
    function condEvKey(ConditionId _conditionId) external pure returns (uint256) {
        return uint256(bytes32(EventId.unwrap(_conditionId.eventId())));
    }

    /// @notice Canonical uint256 event key of the event that `_positionId` belongs to.
    function pidEvKey(PositionId _positionId) external pure returns (uint256) {
        return uint256(bytes32(EventId.unwrap(_positionId.conditionId().eventId())));
    }

    /// @notice Encoded arity (condition count) of `_eventId`.
    function arityOf(EventId _eventId) external pure returns (uint256) {
        return _eventId.arity();
    }

    /// @notice Condition index of `_conditionId` within its event.
    function condIndexOf(ConditionId _conditionId) external pure returns (uint256) {
        return _conditionId.conditionIndex();
    }

    /// @notice Encoded arity (condition count) of the event that `_conditionId` belongs to.
    /// @dev Lets specs gate on "c is a real leg of its event" (conditionIndex <= arity, the
    ///      synthetic Other sits at index == arity). Out-of-range conditions have no positions.
    function arityOfCond(ConditionId _conditionId) external pure returns (uint256) {
        return _conditionId.eventId().arity();
    }

    /* ---------------------------------------------------------------
                          RESOLUTION STATE READS
    --------------------------------------------------------------- */

    /// @notice Length of the stored result vector (0 = unresolved, 2 = resolved).
    function resultLen(ConditionId _conditionId) external view returns (uint256) {
        return result[_conditionId].length;
    }

    /// @notice Timestamp at which resolution was paused for `_conditionId`'s event (0 = not paused).
    /// @dev Typed read of the `resolutionPausedAt` mapping so RESOLVE-NO-01 can gate on the
    ///      unpaused precondition without wrestling with the UDVT-keyed public getter in CVL.
    ///      Pause is now keyed per EVENT (PR #290), so this derives the event from the condition.
    function resolutionPausedAtOf(ConditionId _conditionId) external view returns (uint256) {
        return resolutionPausedAt[_conditionId.eventId()];
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

    /* ---------------------------------------------------------------
       `getResult` may now DERIVE results that are never stored:
       sibling NO once aggregate YES saturates the event, and the
       synthetic Other. These helpers expose the derived view so CVL
       can state properties over it; `resultLen`/`realR0`/`realR1`
       above stay STORAGE-only on purpose — the stored/derived gap is
       exactly what the derivation rules quantify over.
    --------------------------------------------------------------- */

    /// @notice Length of the DERIVED result vector (0 = underivable, 2 = resolved or derivable).
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

    /// @notice Cumulative YES-payout sum for an event.
    function resultsSumOf(EventId _eventId) external view returns (uint256) {
        return resultsSum[_eventId];
    }

    /// @notice Number of resolved conditions for an event.
    function conditionsResolvedOf(EventId _eventId) external view returns (uint256) {
        return conditionsResolved[_eventId];
    }

    /// @notice Ground-truth resolved-condition count for `_eventId`: number of indexes in
    ///         [0, arity - 1] whose canonical condition has a stored result (PARTITION-02).
    /// @dev Hand-unrolled over indexes 0..4 rather than a `for` loop, so this helper does NOT
    ///      constrain --loop_iter: an optimistic-loop assumption at loop_iter < 5 would silently
    ///      truncate the enumeration and make the counter invariant pass for the wrong reason.
    ///      EXACT for arity <= 5, truncated above — the spec guards its invariants on
    ///      `arityOf(e) <= 4` accordingly. Canonical enumeration is exhaustive because ConditionId
    ///      is structurally EventId ++ conditionIndex.
    function realResolvedCountOf(EventId _eventId) external view returns (uint256 n) {
        uint256 arity_ = _eventId.arity();
        if (arity_ >= 1 && result[_eventId.computeConditionId(0)].length != 0) ++n;
        if (arity_ >= 2 && result[_eventId.computeConditionId(1)].length != 0) ++n;
        if (arity_ >= 3 && result[_eventId.computeConditionId(2)].length != 0) ++n;
        if (arity_ >= 4 && result[_eventId.computeConditionId(3)].length != 0) ++n;
        if (arity_ >= 5 && result[_eventId.computeConditionId(4)].length != 0) ++n;
    }

    /// @notice Whether the condition was registered as a legacy-migration condition.
    function isMigration(ConditionId _conditionId) external view returns (bool) {
        return _isMigrationCondition(_conditionId);
    }

    /// @notice Canonical `ConditionId` constructed from a raw `bytes32` (truncates the outcome byte).
    /// @dev Mirrors `ConditionIdLib.from`; exposed so CVL `preserved` blocks keyed on the
    ///      `resolveMigrationCondition(bytes32)` external signature can obtain the typed id used by
    ///      the other `requireInvariant` helpers without reaching into the Solidity library.
    function condFrom(bytes32 _raw) external pure returns (ConditionId) {
        return ConditionIdLib.from(_raw);
    }

    /// @notice Canonical uint256 event key of the structured event a LEGACY conditionId migrates into.
    /// @dev Lets a migration `preserved` block attribute the pulled legacy backing (credited on the
    ///      `safeBatchTransferFrom` pull-in) to the right event without rebuilding the mapping key in
    ///      CVL. Returns 0 for an unregistered legacy id (legacyConditionToConditionId default).
    function legacyEvKey(bytes32 _legacyConditionId) external view returns (uint256) {
        return uint256(bytes32(EventId.unwrap(legacyConditionToConditionId[_legacyConditionId].eventId())));
    }

    /// @notice Legacy CTF condition id that `resolveMigrationCondition` will read payouts from.
    /// @dev Mirrors `_getLegacyConditionIdForResolve` minus its revert (returns 0 if unregistered),
    ///      so MIGRATION-COUPLING-01 can name the legacy payout ghost cells the real code reads.
    function legacyIdForResolve(ConditionId _conditionId) external view returns (bytes32) {
        return getLegacyConditionId(_conditionId);
    }

    /*--------------------------------------------------------------
       EQUIVALENCE-PROOF REAL-CODE WRAPPER
    --------------------------------------------------------------*/
    // Thin external entry point that executes the real migrate-loop redeem so
    // certora/specs/eq/NegRiskMigrationEquivalence.spec can certify that the nondet {0, DENOM}
    // over-approximation the solvency spec opts into (`_useMigrateRedeemModel => ALWAYS(true)`)
    // soundly covers the production body. When `_useMigrateRedeemModel` is left UNSUMMARIZED it
    // defaults to false, so this override falls through to `super._redeemIfResolvedDuringMigrate`,
    // i.e. the real `BaseMigrationMixin._redeemIfResolved` (legacy payout reads, the
    // `p0 * D / den` division, and the real `_finalizeMigrationResolution -> _storeResult` store).

    /// @notice REAL `_redeemIfResolvedDuringMigrate` (default gate -> production `_redeemIfResolved`).
    function redeemIfResolvedDuringMigrateReal(ConditionId _conditionId, bytes32 _legacyConditionId)
        external
        returns (bool)
    {
        return _redeemIfResolvedDuringMigrate(_conditionId, _legacyConditionId);
    }

    /// @notice Exact V2 position id (uint256) that `migratePositions` mints for a legacy entry.
    function legacyMintedKey(bytes32 _legacyConditionId, uint256 _outcome) external view returns (uint256) {
        return PositionId.unwrap(legacyConditionToConditionId[_legacyConditionId].computePositionId(_outcome));
    }
}

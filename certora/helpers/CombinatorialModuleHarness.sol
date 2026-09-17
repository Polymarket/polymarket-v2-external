// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { ConditionId, ConditionIdLib, EventId, PositionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

/// @title CombinatorialModuleHarness
/// @notice Certora harness exposing pure ID derivation so CVL rules can key the position
///         supply/balance ghosts by the YES/NO position IDs of a combinatorial condition
///         without re-implementing the bytes31/uint256 bit layout inside the spec.
contract CombinatorialModuleHarness is CombinatorialModule {
    constructor(address _positionManager) CombinatorialModule(_positionManager) { }

    /// @notice Position ID (uint256) for `(_conditionId, _outcome)` — the supply/balance ghost key.
    function pidOf(ConditionId _conditionId, uint256 _outcome) external pure returns (uint256) {
        return PositionId.unwrap(_conditionId.computePositionId(_outcome));
    }

    /// @notice Highest initialized version (Initializable slot) — 0 iff never initialized.
    /// @dev Lets a spec `require` the "live proxy" state so a batched `initialize` reverts
    ///      via the `initializer` guard (which keys on this slot, not the owner slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }

    /// @notice Module id encoded in a condition id (3 == COMBINATORIAL).
    function condModuleId(ConditionId _conditionId) external pure returns (uint256) {
        return _conditionId.moduleId();
    }

    /// @notice Underlying uint256 of a typed `PositionId` — the ghost key.
    function pidUnwrap(PositionId _positionId) external pure returns (uint256) {
        return PositionId.unwrap(_positionId);
    }

    /// @notice Typed position id for `(_conditionId, _outcome)` — used to drive redeem / compress.
    function pidObj(ConditionId _conditionId, uint256 _outcome) external pure returns (PositionId) {
        return _conditionId.computePositionId(_outcome);
    }

    /// @notice Typed condition id that `_positionId` belongs to.
    function condIdOf(PositionId _positionId) external pure returns (ConditionId) {
        return _positionId.conditionId();
    }

    /// @notice Outcome byte of a position id (0 = YES, 1 = NO).
    function outcomeOf(PositionId _positionId) external pure returns (uint256) {
        return _positionId.outcomeIndex();
    }

    /// @notice Number of stored canonical legs for a combinatorial condition (0 = not prepared).
    /// @dev Lets a spec bound the leg-loop count to loop_iter and gate "condition is prepared".
    function legsLength(ConditionId _conditionId) external view returns (uint256) {
        return legs[_conditionId].length;
    }

    /// @notice Stored leg position id (uint256) at index `_i` — the leg-payout mirror key.
    function legAt(ConditionId _conditionId, uint256 _i) external view returns (uint256) {
        return PositionId.unwrap(legs[_conditionId][_i]);
    }

    /// @notice Module id encoded in a raw position id (3 == COMBINATORIAL).
    function moduleIdOfPid(uint256 _pid) external pure returns (uint256) {
        return PositionId.wrap(_pid).moduleId();
    }

    /// @notice Outcome byte of a raw position id (0 = YES, 1 = NO).
    function outcomeOfPid(uint256 _pid) external pure returns (uint256) {
        return PositionId.wrap(_pid).outcomeIndex();
    }

    /// @notice Raw uint256 condition key of a raw position id — legs of the same market share it.
    /// @dev Mirrors `_validateCanonical`'s ConflictingConditions guard: two legs conflict iff
    ///      their conditionId matches, i.e. this key is equal. Injective on ConditionId
    ///      (bytes31 -> bytes32 -> uint256), so key inequality == conditionId inequality.
    function condKeyOfPid(uint256 _pid) external pure returns (uint256) {
        return uint256(bytes32(ConditionId.unwrap(PositionId.wrap(_pid).conditionId())));
    }

    /// @notice Number of stored legs for the condition of a raw position id (0 = not prepared).
    function legsLengthOfPid(uint256 _pid) external view returns (uint256) {
        return legs[PositionId.wrap(_pid).conditionId()].length;
    }

    /// @notice Stored leg position id (uint256) at index `_i` for the condition of a raw pid.
    function legAtOfPid(uint256 _pid, uint256 _i) external view returns (uint256) {
        return PositionId.unwrap(legs[PositionId.wrap(_pid).conditionId()][_i]);
    }

    /// @notice Raw uint256 key of a `ConditionId` (its bytes with the outcome byte zeroed).
    /// @dev Lets the getResult summary key its result ghost by the same uint256 a leg position id
    ///      clears to (leg - leg % 256), so the real getResult path and the payout summary agree.
    function condKeyOf(ConditionId _conditionId) external pure returns (uint256) {
        return uint256(bytes32(ConditionId.unwrap(_conditionId)));
    }

    /// @notice Number of stored legs for a condition addressed by its raw uint256 key.
    /// @dev `bytes31(bytes32(_condKey))` drops the (already-zero) outcome byte, matching
    ///      `PositionIdLib.conditionId`. Equals `legsLengthOfPid` when `_condKey` is a YES pid.
    function legCount(uint256 _condKey) external view returns (uint256) {
        return legs[ConditionId.wrap(bytes31(bytes32(_condKey)))].length;
    }

    /// @notice Stored leg position id (uint256) at index `_i` for a raw uint256 condition key.
    function legAt(uint256 _condKey, uint256 _i) external view returns (uint256) {
        return PositionId.unwrap(legs[ConditionId.wrap(bytes31(bytes32(_condKey)))][_i]);
    }

    /// @notice Leg-mapping well-formedness: a stored leg set must hash back to its own key.
    /// @dev Vacuously true for an unprepared condition. Used to require-away havoc pre-states
    ///      that place garbage legs at a keccak-derived condition slot.
    function legsRoundtrip(ConditionId _c) external view returns (bool) {
        PositionId[] memory storedLegs = legs[_c];
        if (storedLegs.length == 0) return true;
        return getConditionId(storedLegs) == _c;
    }

    /// @notice Derived child YES condition id for splitOnCondition (parent legs + Y(newCond)).
    function childYesId(PositionId _parentYes, ConditionId _newCond) external view returns (ConditionId) {
        PositionId[] memory childLegs = _insertLeg(legs[_parentYes.conditionId()], _newCond.computePositionId(0));
        return getConditionId(childLegs);
    }

    /// @notice Derived child NO condition id for splitOnCondition (parent legs + N(newCond)).
    function childNoId(PositionId _parentYes, ConditionId _newCond) external view returns (ConditionId) {
        PositionId[] memory childLegs = _insertLeg(legs[_parentYes.conditionId()], _newCond.computePositionId(1));
        return getConditionId(childLegs);
    }

    /// @notice Derived reduced (NO) condition id for extract (full legs minus index).
    function reducedId(PositionId _fullNo, uint256 _index) external view returns (ConditionId) {
        PositionId[] memory reduced = _removeLeg(legs[_fullNo.conditionId()], _index);
        return getConditionId(reduced);
    }

    /// @notice Derived residual (YES) condition id for extract (reduced legs + flip of extracted leg).
    function residualId(PositionId _fullNo, uint256 _index) external view returns (ConditionId) {
        PositionId[] memory fullLegs = legs[_fullNo.conditionId()];
        PositionId[] memory reduced = _removeLeg(fullLegs, _index);
        PositionId[] memory residual = _insertLeg(reduced, _flipLeg(fullLegs[_index]));
        return getConditionId(residual);
    }

    /*--------------------------------------------------------------
                     VALUE-LEMMA STORED-LEGS CHECKERS
    --------------------------------------------------------------*/

    /// @dev True iff legs[_c] equals `_expected` element-wise (length + contents).
    function _storedEquals(ConditionId _c, PositionId[] memory _expected) private view returns (bool) {
        PositionId[] memory stored = legs[_c];
        if (stored.length != _expected.length) return false;
        for (uint256 i; i < stored.length; ++i) {
            if (PositionId.unwrap(stored[i]) != PositionId.unwrap(_expected[i])) return false;
        }
        return true;
    }

    /// @notice Both splitOnCondition children of (_parentYes, _newCond) are stored with exactly
    ///         the derived legs — the state a prior splitOnCondition leaves behind. Used by the
    ///         mergeOnCondition value lemma (merge burns children WITHOUT storing them).
    function childLegsStored(PositionId _parentYes, ConditionId _newCond) external view returns (bool) {
        PositionId[] memory parentLegs = legs[_parentYes.conditionId()];
        PositionId[] memory yesLegs = _insertLeg(parentLegs, _newCond.computePositionId(0));
        PositionId[] memory noLegs = _insertLeg(parentLegs, _newCond.computePositionId(1));
        return _storedEquals(getConditionId(yesLegs), yesLegs) && _storedEquals(getConditionId(noLegs), noLegs);
    }

    /// @notice Reduced/residual conditions of (_fullNo, _index) are stored with exactly the
    ///         derived legs — the state a prior extract leaves behind. Used by the inject
    ///         value lemma (inject burns reduced/residual WITHOUT storing them).
    function reducedResidualStored(PositionId _fullNo, uint256 _index) external view returns (bool) {
        PositionId[] memory fullLegs = legs[_fullNo.conditionId()];
        PositionId[] memory reduced = _removeLeg(fullLegs, _index);
        PositionId[] memory residual = _insertLeg(reduced, _flipLeg(fullLegs[_index]));
        return _storedEquals(getConditionId(reduced), reduced) && _storedEquals(getConditionId(residual), residual);
    }

    /*--------------------------------------------------------------
             FORWARD-OP FRESH-OR-STORED CHECKERS (per target)
    --------------------------------------------------------------*/
    // Element-wise stored-equals for each condition a FORWARD refinement derives and
    // (re-)stores. Content equality is checked directly because getConditionId truncates
    // the baseHash to 128 bits: id equality alone cannot pin array contents in the
    // prover's hashing model (spurious truncation collisions).

    /// @notice Child YES condition of (_parentYes, _newCond) stored with exactly its derived legs.
    function childYesLegsStored(PositionId _parentYes, ConditionId _newCond) external view returns (bool) {
        PositionId[] memory childLegs = _insertLeg(legs[_parentYes.conditionId()], _newCond.computePositionId(0));
        return _storedEquals(getConditionId(childLegs), childLegs);
    }

    /// @notice Child NO condition of (_parentYes, _newCond) stored with exactly its derived legs.
    function childNoLegsStored(PositionId _parentYes, ConditionId _newCond) external view returns (bool) {
        PositionId[] memory childLegs = _insertLeg(legs[_parentYes.conditionId()], _newCond.computePositionId(1));
        return _storedEquals(getConditionId(childLegs), childLegs);
    }

    /// @notice Reduced condition of (_fullNo, _index) stored with exactly its derived legs.
    function reducedLegsStored(PositionId _fullNo, uint256 _index) external view returns (bool) {
        PositionId[] memory reduced = _removeLeg(legs[_fullNo.conditionId()], _index);
        return _storedEquals(getConditionId(reduced), reduced);
    }

    /// @notice Residual condition of (_fullNo, _index) stored with exactly its derived legs.
    function residualLegsStored(PositionId _fullNo, uint256 _index) external view returns (bool) {
        PositionId[] memory fullLegs = legs[_fullNo.conditionId()];
        PositionId[] memory reduced = _removeLeg(fullLegs, _index);
        PositionId[] memory residual = _insertLeg(reduced, _flipLeg(fullLegs[_index]));
        return _storedEquals(getConditionId(residual), residual);
    }

    /// @notice 1-leg condition wrap(_underlying) derives, stored with exactly [_underlying].
    function wrappedLegsStored(PositionId _underlying) external view returns (bool) {
        PositionId[] memory wrappedLegs = new PositionId[](1);
        wrappedLegs[0] = _underlying;
        return _storedEquals(getConditionId(wrappedLegs), wrappedLegs);
    }

    /// @notice Masked-subsequence condition of _pid (keep leg i iff _ki) stored with exactly
    ///         the kept legs — compress's reduced condition when the mask matches resolution.
    function remainingLegsStored(PositionId _pid, bool _k0, bool _k1, bool _k2) external view returns (bool) {
        PositionId[] memory stored = legs[_pid.conditionId()];
        uint256 n = stored.length;
        PositionId[] memory keep = new PositionId[](n);
        uint256 c;
        if (n > 0 && _k0) { keep[c] = stored[0]; ++c; }
        if (n > 1 && _k1) { keep[c] = stored[1]; ++c; }
        if (n > 2 && _k2) { keep[c] = stored[2]; ++c; }
        PositionId[] memory trimmed = _trimArray(keep, c);
        return _storedEquals(getConditionId(trimmed), trimmed);
    }

    /// @notice Remaining condition of (_pid, mask) is unstored (fresh) OR stored with exactly
    ///         the kept-legs subsequence. Single-derivation combiner: builds and hashes the
    ///         trimmed array ONCE — the two-call disjunction (remainingId + remainingLegsStored)
    ///         doubled the per-VC hash machinery and stalled the kept-leg compress rules.
    function remainingFreshOrStored(PositionId _pid, bool _k0, bool _k1, bool _k2) external view returns (bool) {
        PositionId[] memory stored = legs[_pid.conditionId()];
        uint256 n = stored.length;
        PositionId[] memory keep = new PositionId[](n);
        uint256 c;
        if (n > 0 && _k0) { keep[c] = stored[0]; ++c; }
        if (n > 1 && _k1) { keep[c] = stored[1]; ++c; }
        if (n > 2 && _k2) { keep[c] = stored[2]; ++c; }
        PositionId[] memory trimmed = _trimArray(keep, c);
        ConditionId rid = getConditionId(trimmed);
        if (legs[rid].length == 0) return true;
        return _storedEquals(rid, trimmed);
    }

    /// @notice Condition id of the masked subsequence of _pid's stored legs (keep leg i iff _ki).
    ///         Mirrors compress's reduced condition when the mask matches leg resolution.
    function remainingId(PositionId _pid, bool _k0, bool _k1, bool _k2) external view returns (ConditionId) {
        PositionId[] memory stored = legs[_pid.conditionId()];
        uint256 n = stored.length;
        PositionId[] memory keep = new PositionId[](n);
        uint256 c;
        if (n > 0 && _k0) { keep[c] = stored[0]; ++c; }
        if (n > 1 && _k1) { keep[c] = stored[1]; ++c; }
        if (n > 2 && _k2) { keep[c] = stored[2]; ++c; }
        return getConditionId(_trimArray(keep, c));
    }

    /// @notice Derived 1-leg condition id that wrap(_underlying) stores and mints against.
    function wrappedId(PositionId _underlying) external pure returns (ConditionId) {
        PositionId[] memory wrappedLegs = new PositionId[](1);
        wrappedLegs[0] = _underlying;
        return getConditionId(wrappedLegs);
    }

    /// @dev i-th canonical YES-basket leg array for an explicit full-leg array:
    ///      [l_0, ..., l_{i-1}, flip(l_i)]. Clean reimplementation (fresh arrays, no
    ///      mstore-length assembly) of the loop body in _getYesBasketPositionIds.
    function _basketLegsAt(PositionId[] memory _fullLegs, uint256 _i) private pure returns (PositionId[] memory out) {
        out = new PositionId[](_i + 1);
        for (uint256 j; j < _i; ++j) {
            out[j] = _fullLegs[j];
        }
        out[_i] = _flipLeg(_fullLegs[_i]);
    }

    /// @notice i-th YES-basket position id for an explicit leg array. Lets the CVL summary of
    ///         the basket builders pin its returned ids to the real derivation.
    function basketIdFromLegs(PositionId[] calldata _fullLegs, uint256 _i) external pure returns (uint256) {
        PositionId[] memory fullLegs = _fullLegs;
        return PositionId.unwrap(getConditionId(_basketLegsAt(fullLegs, _i)).computePositionId(0));
    }

    /// @notice Every basket condition of _fullNo's condition is stored with its derived legs.
    ///         Used by the basket value lemmas (the basket-builder summary drops the stores).
    function basketLegsStored(PositionId _fullNo) external view returns (bool) {
        PositionId[] memory fullLegs = legs[_fullNo.conditionId()];
        for (uint256 i; i < fullLegs.length; ++i) {
            PositionId[] memory basket = _basketLegsAt(fullLegs, i);
            if (!_storedEquals(getConditionId(basket), basket)) return false;
        }
        return true;
    }

    /// @notice i-th YES-basket position id for _fullNo's stored condition legs — exactly the id
    ///         mergeFromYesBasket burns. Lets the _allNonZero value stone chain read each basket
    ///         position's tracked value from the same derivation.
    function basketPidOf(PositionId _fullNo, uint256 _i) external view returns (uint256) {
        PositionId[] memory fullLegs = legs[_fullNo.conditionId()];
        return PositionId.unwrap(getConditionId(_basketLegsAt(fullLegs, _i)).computePositionId(0));
    }

    /*--------------------------------------------------------------
                     EVENT-OP DERIVED CONDITION CHECKERS
    --------------------------------------------------------------*/
    // split/mergeOnEvent fan a parent YES(P) across a neg-risk event's outcomes: each child is
    // getConditionId(insertLeg(parentLegs, Y(eventId, i))). convertOnEvent first drops the source
    // NO leg (baseLegs = parentLegs minus _index) then fans baseLegs across the event's outcomes.
    // These loop-free re-derivations let the *OnEventValuePreserving lemmas pin each child id and
    // the per-outcome complementarity keys without re-inlining the fan-out loop's keccak into the VC.

    /// @notice YES leg id of a neg-risk event's outcome _i: Y(eventId, i). The complementarity key.
    function eventOutcomeYesPid(EventId _eventId, uint256 _i) external pure returns (uint256) {
        return PositionId.unwrap(_eventId.computeConditionId(_i).computePositionId(0));
    }

    /// @notice i-th split/mergeOnEvent child YES condition id: getConditionId(parentLegs + Y(eventId,i)).
    function eventChildYesId(PositionId _parentYes, EventId _eventId, uint256 _i) external view returns (ConditionId) {
        PositionId[] memory childLegs =
            _insertLeg(legs[_parentYes.conditionId()], _eventId.computeConditionId(_i).computePositionId(0));
        return getConditionId(childLegs);
    }

    /// @notice i-th split/mergeOnEvent child YES condition stored with exactly its derived legs.
    function eventChildYesLegsStored(PositionId _parentYes, EventId _eventId, uint256 _i) external view returns (bool) {
        PositionId[] memory childLegs =
            _insertLeg(legs[_parentYes.conditionId()], _eventId.computeConditionId(_i).computePositionId(0));
        return _storedEquals(getConditionId(childLegs), childLegs);
    }

    /// @notice Combined i-th split/mergeOnEvent child YES derivation: the child condition id AND
    ///         whether it is stored with exactly its derived legs, from ONE _insertLeg + getConditionId
    ///         derivation. Callers needing both (the value-preservation stones) use this instead of
    ///         eventChildYesId + eventChildYesLegsStored to halve the keccak derivations (path count).
    function eventChildYes(PositionId _parentYes, EventId _eventId, uint256 _i)
        external
        view
        returns (ConditionId, bool)
    {
        PositionId[] memory childLegs =
            _insertLeg(legs[_parentYes.conditionId()], _eventId.computeConditionId(_i).computePositionId(0));
        ConditionId c = getConditionId(childLegs);
        return (c, _storedEquals(c, childLegs));
    }

    /// @notice Neg-risk event that the parent's leg at _index belongs to (convertOnEvent source event).
    function eventOfLeg(PositionId _parentYes, uint256 _index) external view returns (EventId) {
        return legs[_parentYes.conditionId()][_index].conditionId().eventId();
    }

    /// @notice Condition index of the parent's neg-risk NO leg at _index (convertOnEvent source index).
    function sourceConditionIndexOfLeg(PositionId _parentYes, uint256 _index) external view returns (uint256) {
        return legs[_parentYes.conditionId()][_index].conditionId().conditionIndex();
    }

    /// @notice i-th convertOnEvent child YES condition id: getConditionId(baseLegs + Y(sourceEvent,i)),
    ///         where baseLegs = parentLegs minus the source NO leg at _index.
    function eventConvertChildYesId(PositionId _parentYes, uint256 _index, uint256 _i)
        external
        view
        returns (ConditionId)
    {
        PositionId[] memory parentLegs = legs[_parentYes.conditionId()];
        EventId ev = parentLegs[_index].conditionId().eventId();
        PositionId[] memory childLegs = _insertLeg(_removeLeg(parentLegs, _index), ev.computeConditionId(_i).computePositionId(0));
        return getConditionId(childLegs);
    }

    /// @notice i-th convertOnEvent child YES condition stored with exactly its derived legs.
    function eventConvertChildYesLegsStored(PositionId _parentYes, uint256 _index, uint256 _i)
        external
        view
        returns (bool)
    {
        PositionId[] memory parentLegs = legs[_parentYes.conditionId()];
        EventId ev = parentLegs[_index].conditionId().eventId();
        PositionId[] memory childLegs = _insertLeg(_removeLeg(parentLegs, _index), ev.computeConditionId(_i).computePositionId(0));
        return _storedEquals(getConditionId(childLegs), childLegs);
    }

    /// @notice Combined i-th convertOnEvent child YES derivation: the child condition id AND whether it
    ///         is stored with exactly its derived legs, from ONE _removeLeg + _insertLeg + getConditionId.
    ///         Callers needing both (the _allBaseNonZero value stones) use this instead of
    ///         eventConvertChildYesId + eventConvertChildYesLegsStored to halve the keccak derivations.
    function eventConvertChildYes(PositionId _parentYes, uint256 _index, uint256 _i)
        external
        view
        returns (ConditionId, bool)
    {
        PositionId[] memory parentLegs = legs[_parentYes.conditionId()];
        EventId ev = parentLegs[_index].conditionId().eventId();
        PositionId[] memory childLegs =
            _insertLeg(_removeLeg(parentLegs, _index), ev.computeConditionId(_i).computePositionId(0));
        ConditionId c = getConditionId(childLegs);
        return (c, _storedEquals(c, childLegs));
    }

    /// @notice Canonical COMBINATORIAL condition id (arity 0, conditionIndex 0, POLYGON) with the
    ///         given base-hash region. Lets a CVL summary of getConditionId build a valid, cheap
    ///         condition id without the real abi.encode + keccak, preserving the module-id byte so
    ///         downstream valuation (moduleIdOfPid == 3) still routes through the combinatorial path.
    function makeComboConditionId(uint256 _baseHash) external pure returns (ConditionId) {
        return ConditionIdLib.encode(ModuleIds.COMBINATORIAL, bytes32(_baseHash), 0, 0, ResolutionChain.POLYGON);
    }

    /*--------------------------------------------------------------
       EQUIVALENCE-PROOF REAL-CODE WRAPPERS
    --------------------------------------------------------------*/
    // Thin external entry points that execute the REAL internal helpers so
    // certora/specs/eq/CombinatorialHelperEquivalence.spec can compare them against the loop-free
    // CVL summaries (flipLegCVL / trimArrayCVL / yesBasketCVL) the solvency specs wire in place of
    // this code. They add no logic of their own — they just expose the production helper to CVL.

    /// @notice REAL `_flipLeg` (outcome-byte toggle) — the flipLegCVL certification target.
    function flipLegReal(PositionId _leg) external pure returns (PositionId) {
        return _flipLeg(_leg);
    }

    /// @notice REAL `_trimArray` (in-place mstore length shrink) — the trimArrayCVL target.
    function trimArrayReal(PositionId[] memory _arr, uint256 _length) external pure returns (PositionId[] memory) {
        return _trimArray(_arr, _length);
    }

    /// @notice REAL storing `_prepareYesBasketPositionIds` builder — the yesBasketCVL target.
    /// @dev The pure `_getYesBasketPositionIds` variant this file also wrapped was REMOVED by the
    ///      leg-binding change (#325): `mergeFromYesBasket` now prepares (stores) its basket legs
    ///      like `convertToYesBasket` does, so this single wrapper covers both wirings.
    function prepareYesBasketReal(PositionId[] memory _fullLegs) external returns (PositionId[] memory) {
        return _prepareYesBasketPositionIds(_fullLegs);
    }
}

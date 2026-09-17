// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CombinatorialModule as CombinatorialModuleBase } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

/// @title CombinatorialModule verification harness
/// @notice Extends the production CombinatorialModule with read-only views the solvency
///         spec needs but CVL cannot express. Named `CombinatorialModule` (rename-import
///         of the base) so specs, links and UDVT qualifiers written against the production
///         name keep resolving when this harness replaces it in scene.
contract CombinatorialModule is CombinatorialModuleBase {
    /// @notice Harness-only: raised by the `_storeLegsFromMemory` override below, so a spec can
    ///         observe whether an execution entered the store at all.
    bool public storeLegsCalled;

    constructor(address _positionManager) CombinatorialModuleBase(_positionManager) { }

    /*--------------------------------------------------------------
                      LEG-STORE PROVENANCE SEAM
    --------------------------------------------------------------*/

    /// @dev Raise the "entered the store" flag, then run the real store body. Every one of the 14
    ///      `_storeLegsFromMemory` call sites dispatches through this override, so
    ///      `storeLegsCalled` is exactly "this execution entered `_storeLegsFromMemory`".
    function _storeLegsFromMemory(PositionId[] memory _legs) internal override returns (ConditionId) {
        storeLegsCalled = true;
        return super._storeLegsFromMemory(_legs);
    }

    /// @notice Number of legs stored for the combinatorial condition keyed by `condKey`.
    function legCount(uint256 condKey) external view returns (uint256) {
        return legs[ConditionId.wrap(bytes31(bytes32(condKey)))].length;
    }

    /// @notice The i-th leg position id (as uint256) of the combinatorial condition keyed by `condKey`.
    function legAt(uint256 condKey, uint256 i) external view returns (uint256) {
        return PositionId.unwrap(legs[ConditionId.wrap(bytes31(bytes32(condKey)))][i]);
    }

    /// @notice Whether the conjunction stored at `condKey`'s slot hashes back to that id
    ///         (`getConditionId(legs[cid]) == cid`).
    function isWellFormed(uint256 condKey) external view returns (bool) {
        ConditionId cid = ConditionId.wrap(bytes31(bytes32(condKey)));
        PositionId[] memory ls = legs[cid];
        if (ls.length == 0) return false;
        return ConditionId.unwrap(getConditionId(ls)) == ConditionId.unwrap(cid);
    }

    /// @notice Whether the conjunction stored at `condKey` is canonical.
    function isCanonical(uint256 condKey) external view returns (bool) {
        PositionId[] memory ls = legs[ConditionId.wrap(bytes31(bytes32(condKey)))];
        uint256 n = ls.length;
        if (n == 0) return false;
        for (uint256 i = 0; i < n; ++i) {
            uint256 mid = ls[i].moduleId();
            if (mid != ModuleIds.BINARY && mid != ModuleIds.NEGRISK) return false;
            if (ls[i].outcomeIndex() >= 2) return false;
            if (i > 0) {
                if (PositionId.unwrap(ls[i]) <= PositionId.unwrap(ls[i - 1])) return false;
                if (ls[i].conditionId() == ls[i - 1].conditionId()) return false;
            }
        }
        return true;
    }

    /// @notice The condKey (YES position id, outcome byte cleared) of a ConditionId.
    function condKeyOf(ConditionId c) external pure returns (uint256) {
        return uint256(bytes32(ConditionId.unwrap(c)));
    }

    /// @notice read-only derivation of the two child condKeys a `splitOnCondition` would create
    ///         (`YES(P^Ym)`, `YES(P^Nm)`).
    /// @param _parentCondKey The parent's YES position id (condKey).
    /// @param _splitConditionId The condition to split on.
    /// @return childYesCondKey The condKey (YES position id) of YES(P^Ym).
    /// @return childNoCondKey The condKey (YES position id) of YES(P^Nm).
    function splitChildCondKeys(uint256 _parentCondKey, ConditionId _splitConditionId)
        external
        view
        returns (uint256 childYesCondKey, uint256 childNoCondKey)
    {
        PositionId[] memory parentLegs = legs[ConditionId.wrap(bytes31(bytes32(_parentCondKey)))];
        PositionId[] memory childYesLegs = _insertLeg(parentLegs, _splitConditionId.computePositionId(0));
        PositionId[] memory childNoLegs = _insertLeg(parentLegs, _splitConditionId.computePositionId(1));
        childYesCondKey = PositionId.unwrap(getConditionId(childYesLegs).computePositionId(0));
        childNoCondKey = PositionId.unwrap(getConditionId(childNoLegs).computePositionId(0));
    }

    /// @notice read-only derivation of the two condKeys an `extract` would create (`NO(P)`,
    ///         `YES(P^!d)`).
    /// @param _fullCondKey The full combinatorial condition's condKey (YES position id).
    /// @param _conditionIndex Index of the condition `d` being extracted.
    /// @return reducedCondKey The condKey (YES position id) of the reduced conjunction P.
    /// @return residualCondKey The condKey (YES position id) of the residual conjunction P^!d.
    function extractChildCondKeys(uint256 _fullCondKey, uint256 _conditionIndex)
        external
        view
        returns (uint256 reducedCondKey, uint256 residualCondKey)
    {
        PositionId[] memory fullLegs = legs[ConditionId.wrap(bytes31(bytes32(_fullCondKey)))];
        PositionId d = fullLegs[_conditionIndex];
        PositionId[] memory reduced = _removeLeg(fullLegs, _conditionIndex);
        PositionId[] memory residual = _insertLeg(reduced, _flipLeg(d));
        reducedCondKey = PositionId.unwrap(getConditionId(reduced).computePositionId(0));
        residualCondKey = PositionId.unwrap(getConditionId(residual).computePositionId(0));
    }

    /// @notice read-only derivation of the two basket condKeys a `convertToYesBasket` would create
    ///         for a 2-leg full NO (`YES(!c1)`, `YES(c1^!c2)`).
    /// @param _fullCondKey The full combinatorial condition's condKey (YES position id).
    /// @return basket0CondKey The condKey (YES position id) of YES(!c1).
    /// @return basket1CondKey The condKey (YES position id) of YES(c1^!c2).
    function basketCondKeys(uint256 _fullCondKey)
        external
        view
        returns (uint256 basket0CondKey, uint256 basket1CondKey)
    {
        PositionId[] memory fullLegs = legs[ConditionId.wrap(bytes31(bytes32(_fullCondKey)))];

        PositionId[] memory b0legs = new PositionId[](1);
        b0legs[0] = _flipLeg(fullLegs[0]);

        PositionId[] memory b1legs = new PositionId[](2);
        b1legs[0] = fullLegs[0];
        b1legs[1] = _flipLeg(fullLegs[1]);

        basket0CondKey = PositionId.unwrap(getConditionId(b0legs).computePositionId(0));
        basket1CondKey = PositionId.unwrap(getConditionId(b1legs).computePositionId(0));
    }

    /// @dev Element-wise leg-array equality (bounded to <= 2 legs).
    function _legsEq(PositionId[] memory a, PositionId[] memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i; i < a.length; ++i) {
            if (PositionId.unwrap(a[i]) != PositionId.unwrap(b[i])) return false;
        }
        return true;
    }

    /// @notice Whether the stored legs of a `splitOnCondition`'s two children equal the parent-derived
    ///         partition (P^Ym, P^Nm).
    /// @param _splitConditionId The condition being merged on.
    /// @return True iff both stored child leg arrays equal the parent-derived partition.
    function splitChildrenMatch(uint256 _parentCondKey, ConditionId _splitConditionId)
        external
        view
        returns (bool)
    {
        PositionId[] memory parentLegs = legs[ConditionId.wrap(bytes31(bytes32(_parentCondKey)))];
        PositionId[] memory childYesLegs = _insertLeg(parentLegs, _splitConditionId.computePositionId(0));
        PositionId[] memory childNoLegs = _insertLeg(parentLegs, _splitConditionId.computePositionId(1));
        return _legsEq(legs[getConditionId(childYesLegs)], childYesLegs)
            && _legsEq(legs[getConditionId(childNoLegs)], childNoLegs);
    }

    /// @notice Whether the stored legs of an `extract`'s two children equal the full-derived reduced
    ///         (P) and residual (P^!d).
    /// @param _fullCondKey The full combinatorial condition's condKey (YES position id).
    /// @param _conditionIndex Index of the condition `d`.
    /// @return True iff both stored child leg arrays equal the full-derived reduced/residual.
    function extractChildrenMatch(uint256 _fullCondKey, uint256 _conditionIndex)
        external
        view
        returns (bool)
    {
        PositionId[] memory fullLegs = legs[ConditionId.wrap(bytes31(bytes32(_fullCondKey)))];
        PositionId d = fullLegs[_conditionIndex];
        PositionId[] memory reduced = _removeLeg(fullLegs, _conditionIndex);
        PositionId[] memory residual = _insertLeg(reduced, _flipLeg(d));
        return _legsEq(legs[getConditionId(reduced)], reduced)
            && _legsEq(legs[getConditionId(residual)], residual);
    }

    /// @notice Whether the stored legs of a 2-leg `convertToYesBasket`'s basket equal the full-derived
    ///         YES(!c1) and YES(c1^!c2).
    /// @param _fullCondKey The full combinatorial condition's condKey (YES position id).
    /// @return True iff both stored basket leg arrays equal the full-derived basket.
    function basketMatch(uint256 _fullCondKey) external view returns (bool) {
        PositionId[] memory fullLegs = legs[ConditionId.wrap(bytes31(bytes32(_fullCondKey)))];

        PositionId[] memory b0legs = new PositionId[](1);
        b0legs[0] = _flipLeg(fullLegs[0]);

        PositionId[] memory b1legs = new PositionId[](2);
        b1legs[0] = fullLegs[0];
        b1legs[1] = _flipLeg(fullLegs[1]);

        return _legsEq(legs[getConditionId(b0legs)], b0legs) && _legsEq(legs[getConditionId(b1legs)], b1legs);
    }

    /// @notice The combi YES position id `wrap` creates for an underlying position.
    /// @param _underlyingPid The underlying binary/negrisk position id being wrapped.
    /// @return The combi YES position id (condKey) of the single-condition conjunction `[underlyingPid]`.
    function wrapCombiId(uint256 _underlyingPid) external view returns (uint256) {
        PositionId[] memory wrappedLegs = new PositionId[](1);
        wrappedLegs[0] = PositionId.wrap(_underlyingPid);
        return PositionId.unwrap(getConditionId(wrappedLegs).computePositionId(0));
    }

    /// @notice The underlying position id `unwrap` mints for a single-condition combi
    ///         position — `storedLegs[0]` for a YES combi, `_flipLeg(storedLegs[0])` for a NO combi.
    /// @param _combiPid The single-condition combi position id being unwrapped.
    /// @return The underlying position id (`storedLegs[0]` or its flip).
    function unwrapUnderlyingId(uint256 _combiPid) external view returns (uint256) {
        PositionId[] memory storedLegs = legs[ConditionId.wrap(bytes31(bytes32(_combiPid)))];
        require(storedLegs.length == 1);
        if (_combiPid % 256 == 0) return PositionId.unwrap(storedLegs[0]);
        return PositionId.unwrap(_flipLeg(storedLegs[0]));
    }

    /// @notice Tthe position id of the single-condition conjunction `[leg]` at `outcome`.
    /// @param _leg The single kept (unresolved) leg.
    /// @param _outcome The residual's outcome (same as the compressed input's).
    /// @return The residual position id.
    function singleLegPositionId(uint256 _leg, uint256 _outcome) external view returns (uint256) {
        PositionId[] memory ls = new PositionId[](1);
        ls[0] = PositionId.wrap(_leg);
        return PositionId.unwrap(getConditionId(ls).computePositionId(_outcome));
    }

    /*--------------------------------------------------------------
                  LEG-STORE SEAM
    --------------------------------------------------------------*/

    /// @notice MAX_LEGS getter.
    function maxLegs() external pure returns (uint256) {
        return MAX_LEGS;
    }

    /// @notice The condKey the real `_storeLegsFromMemory` targets for `_legs`.
    /// @param _legs The candidate leg array.
    /// @return The condKey (YES position id) of the conjunction `_legs`.
    function condKeyOfLegs(PositionId[] memory _legs) external pure returns (uint256) {
        return uint256(bytes32(ConditionId.unwrap(getConditionId(_legs))));
    }

    /// @notice The real `_legsMatchStored`, so a spec's "differs from the stored definition"
    ///         hypothesis is the contract's own element-wise comparison.
    /// @param _condKey The condKey whose stored definition is compared.
    /// @param _legs The candidate leg array.
    /// @return True when the stored definition is element-wise equal to `_legs`.
    function legsMatchStoredReal(uint256 _condKey, PositionId[] memory _legs) external view returns (bool) {
        return _legsMatchStored(ConditionId.wrap(bytes31(bytes32(_condKey))), _legs);
    }

    /// @notice MUTATING: the REAL `_storeLegsFromMemory`, reachable as an entry point.
    /// @dev Used in certora/specs/solvency/CombinatorialLegStore.spec only
    /// @param _legs The leg array to store.
    /// @return The conditionId the definition is stored under.
    function storeLegsFromMemoryReal(PositionId[] memory _legs) external returns (ConditionId) {
        return _storeLegsFromMemory(_legs);
    }
}

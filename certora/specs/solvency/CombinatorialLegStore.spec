
/*
 * MODULE
 * @module CombinatorialModule Conjunction Store
 * @contract CombinatorialModule
 * @impact A condition id could bind to the wrong leg set, settling a position against a different market than it was sold as
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 *
 * PROPERTIES
 * @property COMBI-SL-FIX-1 A stored leg definition is authoritative: an occupied slot rejects a different definition.
 * @property COMBI-SL-FIX-2 The internal leg-store helper is the only writer of the leg store.
 * @property COMBI-SL-FIX-3 Once stored, a leg definition never changes.
 */

import "CombinatorialRefinementBase.spec";
import "CombinatorialCondIdModel.spec";

// ============================================================
// COMBI-SL-FIX-1 / FIX-2 / FIX-3.
//
//   FIX-1  storeLegsRevertsOnDefinitionMismatch  — occupied slot + different legs => revert
//   FIX-2  legsChangeOnlyThroughStoreLegs        — _storeLegsFromMemory is the unique writer
//   FIX-3  storedLegCountImmutable / storedLegsImmutable — once set, a definition never changes
// ============================================================

methods {
    // ---- Leg-store harness views ----
    function CombinatorialModule.maxLegs() external returns (uint256) envfree;
    function CombinatorialModule.condKeyOfLegs(CombinatorialModule.PositionId[]) external
        returns (uint256) envfree;
    function CombinatorialModule.legsMatchStoredReal(uint256, CombinatorialModule.PositionId[]) external
        returns (bool) envfree;

    // Harness helper for calling _storeLegsFromMemory.
    function CombinatorialModule.storeLegsFromMemoryReal(CombinatorialModule.PositionId[]) external
        returns (CombinatorialModule.ConditionId);

    // Harness-only provenance flag.
    function CombinatorialModule.storeLegsCalled() external returns (bool) envfree;

    // The assembly-bearing ops build position ids with inline mstore, which breaks the Prover's
    // sighash resolution of the following PM.mint/burn/batchBurn.
    unresolved external in CombinatorialModule.convertToYesBasket(address[], CombinatorialModule.PositionId, uint256)
        => DISPATCH [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.burn(PositionManager.PositionId, uint256)
        ] default NONDET;
    unresolved external in CombinatorialModule.mergeFromYesBasket(address, CombinatorialModule.PositionId, uint256)
        => DISPATCH [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.batchBurn(PositionManager.PositionId[], uint256[])
        ] default NONDET;
    unresolved external in CombinatorialModule.splitOnEvent(
        address[], CombinatorialModule.PositionId, CombinatorialModule.EventId, uint256
    ) => DISPATCH [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.burn(PositionManager.PositionId, uint256)
    ] default NONDET;
    unresolved external in CombinatorialModule.mergeOnEvent(
        address, CombinatorialModule.PositionId, CombinatorialModule.EventId, uint256
    ) => DISPATCH [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.batchBurn(PositionManager.PositionId[], uint256[])
    ] default NONDET;
    unresolved external in CombinatorialModule.convertOnEvent(
        address[], CombinatorialModule.PositionId, uint256, uint256
    ) => DISPATCH [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.burn(PositionManager.PositionId, uint256)
    ] default NONDET;
}

// Ownership-handover never touches `legs` and its two-step flow needs a warp to be meaningful.
definition LEG_STORE_SCOPE(method f) returns bool =
    !f.isView
    && !f.isPure
    && f.selector != sig:CombinatorialModule.requestOwnershipHandover().selector
    && f.selector != sig:CombinatorialModule.cancelOwnershipHandover().selector
    && f.selector != sig:CombinatorialModule.completeOwnershipHandover(address).selector;

/*--------------------------------------------------------------
    COMBI-SL-FIX-1 — the definition-mismatch revert
--------------------------------------------------------------*/

/**
 * @title a stored definition is authoritative
 * @description Presenting a different leg definition for an occupied slot reverts.
 * @link_property COMBI-SL-FIX-1
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a5681a1e4d64ba38b81020de3db7b8a?anonymousKey=0887ac90d6062d606efbe4a4148d538cff729850
 */
rule storeLegsRevertsOnDefinitionMismatch(env e, CombinatorialModule.PositionId[] legs) {
    require legs.length > 0 && legs.length <= 3, "bounded proof: <= 3 legs (loop_iter)";

    uint256 condKey = CombinatorialModule.condKeyOfLegs(legs);
    require CombinatorialModule.legCount(condKey) > 0, "a definition is already stored";
    require !CombinatorialModule.legsMatchStoredReal(condKey, legs), "and it differs from the input";

    CombinatorialModule.storeLegsFromMemoryReal@withrevert(e, legs);

    assert lastReverted, "storing a different definition under an occupied conditionId must revert";
}

/**
 * @title re-presenting the same definition is accepted
 * @description Presenting the identical leg definition for an occupied slot succeeds.
 * @link_property COMBI-SL-FIX-1
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a5681a1e4d64ba38b81020de3db7b8a?anonymousKey=0887ac90d6062d606efbe4a4148d538cff729850
 */
rule storeLegsSucceedsOnExactMatch(env e, CombinatorialModule.PositionId[] legs) {
    require legs.length > 0 && legs.length <= 3, "bounded proof: <= 3 legs (loop_iter)";
    require e.msg.value == 0, "storeLegsFromMemoryReal is non-payable";

    uint256 condKey = CombinatorialModule.condKeyOfLegs(legs);
    require CombinatorialModule.legCount(condKey) > 0, "a definition is already stored";
    require CombinatorialModule.legsMatchStoredReal(condKey, legs), "and it equals the input";

    CombinatorialModule.storeLegsFromMemoryReal@withrevert(e, legs);

    assert !lastReverted, "re-storing the identical definition must not revert";
}

/**
 * @title a fresh slot accepts the input
 * @description A fresh slot stores exactly the presented leg definition.
 * @link_property COMBI-SL-FIX-1
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a5681a1e4d64ba38b81020de3db7b8a?anonymousKey=0887ac90d6062d606efbe4a4148d538cff729850
 */
rule storeLegsWritesInputWhenFresh(env e, CombinatorialModule.PositionId[] legs) {
    require legs.length > 0 && legs.length <= 3, "bounded proof: <= 3 legs (loop_iter)";

    uint256 condKey = CombinatorialModule.condKeyOfLegs(legs);
    require CombinatorialModule.legCount(condKey) == 0, "the slot is fresh";

    CombinatorialModule.storeLegsFromMemoryReal(e, legs);

    assert CombinatorialModule.legCount(condKey) == legs.length, "the whole array must be stored";
    assert CombinatorialModule.legsMatchStoredReal(condKey, legs), "the stored legs must equal the input";
}

/*--------------------------------------------------------------
    COMBI-SL-FIX-2 — _storeLegsFromMemory is the unique writer
--------------------------------------------------------------*/

/**
 * @title the leg store has a single writer
 * @description No entry point changes the leg store except through the internal store helper.
 * @link_property COMBI-SL-FIX-2
 * @assumption The ownership-handover entry points are excluded because they never touch the leg store and their two-step flow needs a time warp to be meaningful
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a5681a1e4d64ba38b81020de3db7b8a?anonymousKey=0887ac90d6062d606efbe4a4148d538cff729850
 */
rule legsChangeOnlyThroughStoreLegs(env e, method f, calldataarg args, uint256 condKey)
    filtered { f -> LEG_STORE_SCOPE(f) }
{
    require !CombinatorialModule.storeLegsCalled(), "fresh flag: the store has not been entered yet";

    uint256 lenBefore = CombinatorialModule.legCount(condKey);

    f(e, args);

    bool entered = CombinatorialModule.storeLegsCalled();
    uint256 lenAfter = CombinatorialModule.legCount(condKey);

    assert lenAfter != lenBefore => entered,
        "legs changed without entering _storeLegsFromMemory";
    assert lenAfter != lenBefore =>
        (lenBefore == 0 && lenAfter > 0 && lenAfter <= CombinatorialModule.maxLegs()
            && CombinatorialModule.isWellFormed(condKey)),
        "legs changed with a shape _storeLegsFromMemory cannot produce";
}

/*--------------------------------------------------------------
    COMBI-SL-FIX-3 — stored legs are immutable
--------------------------------------------------------------*/

/**
 * @title a stored leg count is immutable
 * @description Once a definition is stored, its length never changes again.
 * @link_property COMBI-SL-FIX-3
 * @assumption The ownership-handover entry points are excluded because they never touch the leg store and their two-step flow needs a time warp to be meaningful
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a5681a1e4d64ba38b81020de3db7b8a?anonymousKey=0887ac90d6062d606efbe4a4148d538cff729850
 */
rule storedLegCountImmutable(env e, method f, calldataarg args, uint256 condKey)
    filtered { f -> LEG_STORE_SCOPE(f) }
{
    uint256 lenBefore = CombinatorialModule.legCount(condKey);
    require lenBefore > 0, "a definition is already stored";

    f(e, args);

    assert CombinatorialModule.legCount(condKey) == lenBefore, "stored leg count changed";
}

/**
 * @title stored legs are immutable
 * @description Once a definition is stored, no element of it ever changes.
 * @link_property COMBI-SL-FIX-3
 * @assumption The ownership-handover entry points are excluded because they never touch the leg store and their two-step flow needs a time warp to be meaningful
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a5681a1e4d64ba38b81020de3db7b8a?anonymousKey=0887ac90d6062d606efbe4a4148d538cff729850
 */
rule storedLegsImmutable(env e, method f, calldataarg args, uint256 condKey, uint256 i)
    filtered { f -> LEG_STORE_SCOPE(f) }
{
    uint256 lenBefore = CombinatorialModule.legCount(condKey);
    require lenBefore > 0, "a definition is already stored";
    require i < lenBefore, "in-range witness leg";
    uint256 legBefore = CombinatorialModule.legAt(condKey, i);

    f(e, args);

    // Proved by storedLegCountImmutable; assumed here so the in-range post-state read cannot
    // revert and prune the path.
    require CombinatorialModule.legCount(condKey) == lenBefore;

    assert CombinatorialModule.legAt(condKey, i) == legBefore, "stored leg changed";
}

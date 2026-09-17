
/*
 * MODULE
 * @module CombinatorialModule Refinement Value Conservation
 * @contract CombinatorialModule
 * @impact A refinement could mint positions worth more than those it consumed, creating redemption value from nothing
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 2 iterations
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 *
 * PROPERTIES
 * @property COMBO-REFINE-INVERSE-01 The inverse refinements mint the coarse position for no more than the parts were worth, up to one wei of recovered rounding dust.
 */

import "CombinatorialRefinementBase.spec";
import "CombinatorialValueConservationBase.spec";
import "./CombinatorialCondIdModel.spec";

// ============================================================
// inverse refinements (value conservation up to 1-wei dust)
//
// Inverse ops mint one coarse "whole" and burn two fine "parts" (the inverse of the
// forward ops). They cannot be proven strict `Σminted <= Σburned` per-ω: floor rounding lets the
// whole redeem for strictly more than the parts. For every fully-resolved omega,
//   payout(whole) = Σ payout(parts) + dust,   dust ∈ {0, 1} wei  (K = #parts - 1 = 1 at legs <= 2),
// because the parts' exact values sum to the whole's and `floor(a)+floor(b) ∈ {floor(a+b)-1,
// floor(a+b)}`. So we prove the dust tolerant bound
//   payout(whole) <= Σ payout(parts) + 1.
//
// Bounded at legs <= 2.
// ============================================================

// batchBurn records each element (arrays are loop_iter <= 2 bounded, so at most 2 live entries).
function recordBatchBurnCVL(PositionManager.PositionId[] ids, uint256[] amounts) {
    if (ids.length > 0) { recordBurnCVL(assert_uint256(ids[0]), amounts[0]); }
    if (ids.length > 1) { recordBurnCVL(assert_uint256(ids[1]), amounts[1]); }
}

methods {
    function CombinatorialModule.splitChildrenMatch(uint256, CombinatorialModule.ConditionId)
        external returns (bool) envfree;
    function CombinatorialModule.extractChildrenMatch(uint256, uint256) external returns (bool) envfree;
    function CombinatorialModule.basketMatch(uint256) external returns (bool) envfree;

    // Inverse ops burn the two parts via batchBurn -> record each element
    function PositionManager.batchBurn(PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external => recordBatchBurnCVL(_positionIds, _amounts);

    unresolved external in CombinatorialModule.mergeFromYesBasket(address, CombinatorialModule.PositionId, uint256)
        => DISPATCH [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.batchBurn(PositionManager.PositionId[], uint256[])
        ] default NONDET;
}

/**
 * @title mergeOnCondition conserves value up to dust
 * @description mergeOnCondition mints the parent and burns the two children, and the parent redeems for no more than the children plus one wei.
 * @link_property COMBO-REFINE-INVERSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/fc90aacbfcd8466a8dd80c2f83a7533c?anonymousKey=1424ff632f6088543fa9c6d5d78533f415a2f5eb
 * @dev mint YES(P), burn YES(P^Ym) + YES(P^Nm). The children are burned, so they must be
 *      prepared for the payout read.
 */
rule mergeOnConditionValueConserving(
    env e, address to, uint256 parentYesPid, CombinatorialModule.ConditionId condId, uint256 amt
) {
    require gMintCount == 0 && gBurnCount == 0;   // fresh log
    require parentYesPid % 256 == 0;              // YES parent (mergeOnCondition requires outcomeIndex 0)
    require CombinatorialModule.legCount(parentYesPid) == 1; // 1-leg parent => 2-leg children (legs <= 2)

    requireInvariant storedConjunctionsCanonical(parentYesPid);       // 1-leg parent: valid leg (module + outcome<2)

    uint256 childYesCondKey;
    uint256 childNoCondKey;
    childYesCondKey, childNoCondKey = CombinatorialModule.splitChildCondKeys(parentYesPid, condId);
    requireInvariant storedConjunctionsWellFormed(parentYesPid);

    // Children are burned so their STORED legs are read for payout. Pin them to the
    // parent-derived partition (P^Ym, P^Nm)
    require CombinatorialModule.splitChildrenMatch(parentYesPid, condId);
    require childYesCondKey != childNoCondKey;
    require childYesCondKey != parentYesPid;
    require childNoCondKey != parentYesPid;

    CombinatorialModule.mergeOnCondition(e, to, parentYesPid, condId, amt);

    // (a) supply-delta structure: mint the parent, burn the two children (via batchBurn).
    assert gMintCount == 1 && gBurnCount == 2, "mergeOnCondition must mint 1 and burn 2";
    assert gMintId[0] == parentYesPid, "mergeOnCondition must mint the parent YES";
    assert gBurnId[0] == childYesCondKey && gBurnId[1] == childNoCondKey,
        "mergeOnCondition moved unexpected positions";

    // (b) value conservation up to 1-wei dust on the recorded positions.
    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0])
        + CombinatorialModule.getPayout(e, gBurnId[1], gBurnAmt[1]);
    assert vMint <= vBurn + 1, "mergeOnCondition creates more than 1 wei of redemption value";
}

/**
 * @title inject conserves value up to dust
 * @description inject mints the full position and burns the reduced and residual parts, and the full position redeems for no more than the parts plus one wei.
 * @link_property COMBO-REFINE-INVERSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/fc90aacbfcd8466a8dd80c2f83a7533c?anonymousKey=1424ff632f6088543fa9c6d5d78533f415a2f5eb
 * @dev mint NO(P^d), burn NO(P) + YES(P^!d). The parts are burned, so their stored legs are
 *      pinned to the full-derived reduced/residual via extractChildrenMatch.
 */
rule injectValueConserving(env e, address to, uint256 fullNoPid, uint256 condIndex, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0;
    require fullNoPid % 256 == 1;                         // NO whole (inject requires outcomeIndex 1)
    uint256 fullCondKey = require_uint256(fullNoPid - 1);  // YES condKey
    require CombinatorialModule.legCount(fullCondKey) == 2; // inject needs >= 2; at legs <= 2, == 2
    require condIndex < 2;
    requireInvariant storedConjunctionsCanonical(fullCondKey);

    uint256 reducedCondKey;
    uint256 residualCondKey;
    reducedCondKey, residualCondKey = CombinatorialModule.extractChildCondKeys(fullCondKey, condIndex);
    requireInvariant storedConjunctionsWellFormed(fullCondKey);
    // Pin the burned parts' stored legs to the full-derived reduced (P) / residual (P^!d).
    require CombinatorialModule.extractChildrenMatch(fullCondKey, condIndex);
    require reducedCondKey != residualCondKey;
    require reducedCondKey != fullCondKey;
    require residualCondKey != fullCondKey;

    CombinatorialModule.inject(e, to, fullNoPid, condIndex, amt);

    // supply-delta structure: mint NO(full), burn NO(reduced) [id = reducedCondKey+1] + YES(residual).
    assert gMintCount == 1 && gBurnCount == 2, "inject must mint 1 and burn 2";
    assert gMintId[0] == fullNoPid, "inject must mint the full NO";
    assert gBurnId[0] == require_uint256(reducedCondKey + 1) && gBurnId[1] == residualCondKey,
        "inject moved unexpected positions";

    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0])
        + CombinatorialModule.getPayout(e, gBurnId[1], gBurnAmt[1]);
    assert vMint <= vBurn + 1, "inject creates more than 1 wei of redemption value";
}

/**
 * @title mergeFromYesBasket conserves value up to dust
 * @description mergeFromYesBasket mints the full position and burns the basket, and the full position redeems for no more than the basket plus one wei.
 * @link_property COMBO-REFINE-INVERSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/fc90aacbfcd8466a8dd80c2f83a7533c?anonymousKey=1424ff632f6088543fa9c6d5d78533f415a2f5eb
 * @dev mint NO(c1^c2), burn YES(!c1) + YES(c1^!c2).
 */
rule mergeFromYesBasketValueConserving(env e, address to, uint256 fullNoPid, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0;
    require fullNoPid % 256 == 1;                         // NO whole (requires outcomeIndex 1)
    uint256 fullCondKey = require_uint256(fullNoPid - 1);  // YES condKey
    require CombinatorialModule.legCount(fullCondKey) == 2; // 2-leg full (legs <= 2)
    requireInvariant storedConjunctionsCanonical(fullCondKey);

    uint256 basket0CondKey;
    uint256 basket1CondKey;
    basket0CondKey, basket1CondKey = CombinatorialModule.basketCondKeys(fullCondKey);
    requireInvariant storedConjunctionsWellFormed(fullCondKey);
    // Pin the burned basket's stored legs to the full-derived YES(!c1) / YES(c1^!c2).
    require CombinatorialModule.basketMatch(fullCondKey);
    require basket0CondKey != basket1CondKey;
    require basket0CondKey != fullCondKey;
    require basket1CondKey != fullCondKey;

    CombinatorialModule.mergeFromYesBasket(e, to, fullNoPid, amt);

    // supply-delta structure: mint NO(full), burn YES(!c1) + YES(c1^!c2).
    assert gMintCount == 1 && gBurnCount == 2, "mergeFromYesBasket must mint 1 and burn 2";
    assert gMintId[0] == fullNoPid, "mergeFromYesBasket must mint the full NO";
    assert gBurnId[0] == basket0CondKey && gBurnId[1] == basket1CondKey,
        "mergeFromYesBasket moved unexpected positions";

    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0])
        + CombinatorialModule.getPayout(e, gBurnId[1], gBurnAmt[1]);
    assert vMint <= vBurn + 1, "mergeFromYesBasket creates more than 1 wei of redemption value";
}
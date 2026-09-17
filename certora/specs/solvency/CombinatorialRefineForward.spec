
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
 * @property COMBO-REFINE-FORWARD-01 The forward refinements mint exactly the expected fine-grained positions and never create redemption value.
 */

import "CombinatorialRefinementBase.spec";
import "CombinatorialValueConservationBase.spec";
import "CombinatorialCondIdModel.spec";

// ============================================================
// forward refinements (value conservation)
//
// PositionManager.mint / burn are summarized to record each (positionId, amount) into a
// mint/burn log. After calling the op we assert:
//   (a) SUPPLY-DELTA STRUCTURE — the op minted / burned exactly the expected count, AND
//   (b) VALUE CONSERVATION      — Sum getPayout(minted_i) <= Sum getPayout(burned_j)
//       on the ACTUAL recorded positions (via the loop-free exact positionPayoutCVL), for every
//       fully-resolved omega (getPayout reverts otherwise -> the worst-case omega is what's checked).
// Together with collateral-neutrality (certora/specs/solvency/CombinatorialModule.spec) this is solvency preservation.
//
// Bounded at legs <= 2.
// ============================================================

methods {
    // convertToYesBasket's mint/burn are AUTO-havoc'd.
    // Force resolution to PositionManager.mint/burn so the record summaries attach.
    unresolved external in CombinatorialModule.convertToYesBasket(address[], CombinatorialModule.PositionId, uint256)
        => DISPATCH [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.burn(PositionManager.PositionId, uint256)
        ] default NONDET;
}

/**
 * @title splitOnCondition conserves value
 * @description splitOnCondition mints exactly the two children and burns the parent, and the children redeem for no more than the parent at every complete resolution.
 * @link_property COMBO-REFINE-FORWARD-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/19a9ee0158954ead97b6bc3c0ec8469f?anonymousKey=8ef1403ac2d174b8596cb3299dbcc616957e8e18
 * @dev YES(P) -> YES(P^Ym) + YES(P^Nm).
 */
rule splitOnConditionValueConserving(
    env e, address[] to, uint256 parentYesPid, CombinatorialModule.ConditionId condId, uint256 amt
) {
    require gMintCount == 0 && gBurnCount == 0;   // fresh log
    require parentYesPid % 256 == 0;              // YES position (splitOnCondition requires outcomeIndex 0)
    require CombinatorialModule.legCount(parentYesPid) == 1; // 1-leg parent => 2-leg children (legs <= 2)

    // Pre-state well-formedness of the parent and the child slots.
    uint256 childYesCondKey;
    uint256 childNoCondKey;
    childYesCondKey, childNoCondKey = CombinatorialModule.splitChildCondKeys(parentYesPid, condId);
    requireInvariant storedConjunctionsWellFormed(parentYesPid);

    requireInvariant storedConjunctionsWellFormed(childYesCondKey);
    requireInvariant storedConjunctionsCanonical(childYesCondKey);
    requireInvariant storedConjunctionsWellFormed(childNoCondKey);
    requireInvariant storedConjunctionsCanonical(childNoCondKey);
    require childYesCondKey != childNoCondKey;
    require childYesCondKey != parentYesPid;
    require childNoCondKey != parentYesPid;

    CombinatorialModule.splitOnCondition(e, to, parentYesPid, condId, amt);

    // (a) supply-delta structure: exactly two mints, one burn, of exactly the derived children/parent.
    assert gMintCount == 2 && gBurnCount == 1, "splitOnCondition must mint 2 and burn 1";
    assert gMintId[0] == childYesCondKey && gMintId[1] == childNoCondKey && gBurnId[0] == parentYesPid,
        "splitOnCondition moved unexpected positions";

    // (b) value conservation on the recorded positions.
    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0])
        + CombinatorialModule.getPayout(e, gMintId[1], gMintAmt[1]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0]);
    assert vMint <= vBurn, "splitOnCondition creates redemption value";
}

/**
 * @title extract conserves value
 * @description extract mints exactly the reduced and residual positions and burns the full one, and the outputs redeem for no more than the input at every complete resolution.
 * @link_property COMBO-REFINE-FORWARD-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/bdc6d023a41246498cc7b57a37116d27?anonymousKey=466143ead57f00fd33b6fce554233a0da546e3e9
 * @dev NO(P^d) -> NO(P) + YES(P^!d).
 */
rule extractValueConserving(env e, address[] to, uint256 fullNoPid, uint256 condIndex, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0;
    require fullNoPid % 256 == 1;                        // NO position (extract requires outcomeIndex 1)
    uint256 fullCondKey = require_uint256(fullNoPid - 1); // YES condKey
    require CombinatorialModule.legCount(fullCondKey) == 2; // extract needs >= 2; at legs <= 2, == 2
    require condIndex < 2;
    // The full must be canonical (distinct conditions, ascending, valid modules). A non-canonical full 
    // (e.g. [YES(c), NO(c)]) makes the payout formula compute a bogus product and breaks the value identity. 
    requireInvariant storedConjunctionsCanonical(fullCondKey);

    uint256 reducedCondKey;
    uint256 residualCondKey;
    reducedCondKey, residualCondKey = CombinatorialModule.extractChildCondKeys(fullCondKey, condIndex);
    requireInvariant storedConjunctionsWellFormed(fullCondKey);
    requireInvariant storedConjunctionsWellFormed(reducedCondKey);
    requireInvariant storedConjunctionsCanonical(reducedCondKey);
    requireInvariant storedConjunctionsWellFormed(residualCondKey);
    requireInvariant storedConjunctionsCanonical(residualCondKey);
    require reducedCondKey != residualCondKey;
    require reducedCondKey != fullCondKey;
    require residualCondKey != fullCondKey;

    CombinatorialModule.extract(e, to, fullNoPid, condIndex, amt);

    // supply-delta structure: mint NO(reduced) [id = reducedCondKey+1] + YES(residual) [= residualCondKey],
    // burn NO(full) [= fullNoPid].
    assert gMintCount == 2 && gBurnCount == 1, "extract must mint 2 and burn 1";
    assert gBurnId[0] == fullNoPid, "extract must burn the full NO";
    assert gMintId[0] == require_uint256(reducedCondKey + 1) && gMintId[1] == residualCondKey,
        "extract moved unexpected positions";

    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0])
        + CombinatorialModule.getPayout(e, gMintId[1], gMintAmt[1]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0]);
    assert vMint <= vBurn, "extract creates redemption value";
}

/**
 * @title convertToYesBasket conserves value
 * @description convertToYesBasket mints exactly the basket positions and burns the full one, and the basket redeems for no more than the input at every complete resolution.
 * @link_property COMBO-REFINE-FORWARD-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/19a9ee0158954ead97b6bc3c0ec8469f?anonymousKey=8ef1403ac2d174b8596cb3299dbcc616957e8e18
 * @dev NO(c1^c2) -> YES(!c1) + YES(c1^!c2).
 */
rule convertToYesBasketValueConserving(env e, address[] to, uint256 fullNoPid, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0;
    require fullNoPid % 256 == 1;                        // NO position (convert requires outcomeIndex 1)
    uint256 fullCondKey = require_uint256(fullNoPid - 1); // YES condKey
    require CombinatorialModule.legCount(fullCondKey) == 2; // 2-leg full (legs <= 2)
    // The full must be canonical.
    requireInvariant storedConjunctionsCanonical(fullCondKey);

    uint256 basket0CondKey;
    uint256 basket1CondKey;
    basket0CondKey, basket1CondKey = CombinatorialModule.basketCondKeys(fullCondKey);
    requireInvariant storedConjunctionsWellFormed(fullCondKey);

    requireInvariant storedConjunctionsWellFormed(basket0CondKey);
    requireInvariant storedConjunctionsCanonical(basket0CondKey);
    requireInvariant storedConjunctionsWellFormed(basket1CondKey);
    requireInvariant storedConjunctionsCanonical(basket1CondKey);

    require basket0CondKey != basket1CondKey;
    require basket0CondKey != fullCondKey;
    require basket1CondKey != fullCondKey;

    CombinatorialModule.convertToYesBasket(e, to, fullNoPid, amt);

    // supply-delta structure: mint YES(!c1) + YES(c1^!c2), burn NO(full).
    assert gMintCount == 2 && gBurnCount == 1, "convert must mint 2 and burn 1";
    assert gBurnId[0] == fullNoPid, "convert must burn the full NO";
    assert gMintId[0] == basket0CondKey && gMintId[1] == basket1CondKey,
        "convert moved unexpected positions";

    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0])
        + CombinatorialModule.getPayout(e, gMintId[1], gMintAmt[1]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0]);
    assert vMint <= vBurn, "convert creates redemption value";
}
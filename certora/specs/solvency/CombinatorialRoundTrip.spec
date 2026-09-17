
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
 * @property COMBO-ROUNDTRIP-01 A forward refinement followed by its inverse is exactly value-neutral, with no rounding dust.
 */

import "CombinatorialRefinementBase.spec";
import "CombinatorialValueConservationBase.spec";
import "CombinatorialCondIdModel.spec";

// ============================================================
// ROUND-TRIP VALUE NEUTRALITY
//
// Bounded at legs <= 2.
// ============================================================

// batchBurn records each element (arrays are loop_iter <= 2 bounded, so at most 2 live
// entries). The inverse ops burn their parts via _burnPair / _burnMany, both of which
// route to PositionManager.batchBurn.
function recordBatchBurnCVL(PositionManager.PositionId[] ids, uint256[] amounts) {
    if (ids.length > 0) { recordBurnCVL(assert_uint256(ids[0]), amounts[0]); }
    if (ids.length > 1) { recordBurnCVL(assert_uint256(ids[1]), amounts[1]); }
}

methods {
    function PositionManager.batchBurn(PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external => recordBatchBurnCVL(_positionIds, _amounts);

    // _prepareYesBasketPositionIds' inline assembly leaves both basket ops' later external
    // calls unresolved. Force resolution so the record summaries attach. 
    // convertToYesBasket burns singly; mergeFromYesBasket via batchBurn.
    unresolved external in CombinatorialModule.convertToYesBasket(address[], CombinatorialModule.PositionId, uint256)
        => DISPATCH(optimistic=true) [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.burn(PositionManager.PositionId, uint256)
        ];

    unresolved external in CombinatorialModule.mergeFromYesBasket(address, CombinatorialModule.PositionId, uint256)
        => DISPATCH(optimistic=true) [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.batchBurn(PositionManager.PositionId[], uint256[])
        ];
}

/**
 * @title split then merge on condition is value-neutral
 * @description splitOnCondition followed by mergeOnCondition returns exactly the original position, minting and burning equal value.
 * @link_property COMBO-ROUNDTRIP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c43343cce42a4c8ea73e898c758eb7fb?anonymousKey=0056b59f8d39b63b56fa2ca8713665078e8d98a3
 * @dev YES(P) -> YES(P^Ym) + YES(P^Nm) -> YES(P).
 */
rule splitThenMergeOnConditionIsValueNeutral(
    env e, address[] toSplit, address toMerge,
    uint256 parentYesPid, CombinatorialModule.ConditionId condId, uint256 amt
) {
    require gMintCount == 0 && gBurnCount == 0;   // fresh log
    require toSplit.length == 2;                  // splitOnCondition requires 2 recipients
    require parentYesPid % 256 == 0;              // YES parent (splitOnCondition requires outcomeIndex 0)
    require CombinatorialModule.legCount(parentYesPid) == 1; // 1-leg parent => 2-leg children (legs <= 2)

    requireInvariant storedConjunctionsWellFormed(parentYesPid);
    requireInvariant storedConjunctionsCanonical(parentYesPid);

    CombinatorialModule.splitOnCondition(e, toSplit, parentYesPid, condId, amt);
    CombinatorialModule.mergeOnCondition(e, toMerge, parentYesPid, condId, amt);

    // Asserted because the sums below index the log.
    assert gMintCount == 3 && gBurnCount == 3,
        "split-then-merge must mint 3 and burn 3 in total";

    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0])
        + CombinatorialModule.getPayout(e, gMintId[1], gMintAmt[1])
        + CombinatorialModule.getPayout(e, gMintId[2], gMintAmt[2]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0])
        + CombinatorialModule.getPayout(e, gBurnId[1], gBurnAmt[1])
        + CombinatorialModule.getPayout(e, gBurnId[2], gBurnAmt[2]);

    assert vMint == vBurn,
        "splitOnCondition then mergeOnCondition is not value neutral";
}

/**
 * @title extract then inject is value-neutral
 * @description extract followed by inject returns exactly the original position, minting and burning equal value.
 * @link_property COMBO-ROUNDTRIP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c43343cce42a4c8ea73e898c758eb7fb?anonymousKey=0056b59f8d39b63b56fa2ca8713665078e8d98a3
 * @dev NO(P^d) -> NO(P) + YES(P^!d) -> NO(P^d).
 */
rule extractThenInjectIsValueNeutral(
    env e, address[] toExtract, address toInject,
    uint256 fullNoPid, uint256 condIndex, uint256 amt
) {
    require gMintCount == 0 && gBurnCount == 0;
    require toExtract.length == 2;                        // extract requires 2 recipients
    require fullNoPid % 256 == 1;                         // NO whole (extract requires outcomeIndex 1)
    uint256 fullCondKey = require_uint256(fullNoPid - 1);  // YES condKey
    require CombinatorialModule.legCount(fullCondKey) == 2; // extract needs >= 2; at legs <= 2, == 2
    require condIndex < 2;

    requireInvariant storedConjunctionsWellFormed(fullCondKey);
    requireInvariant storedConjunctionsCanonical(fullCondKey);

    CombinatorialModule.extract(e, toExtract, fullNoPid, condIndex, amt);
    CombinatorialModule.inject(e, toInject, fullNoPid, condIndex, amt);

    assert gMintCount == 3 && gBurnCount == 3,
        "extract-then-inject must mint 3 and burn 3 in total";

    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0])
        + CombinatorialModule.getPayout(e, gMintId[1], gMintAmt[1])
        + CombinatorialModule.getPayout(e, gMintId[2], gMintAmt[2]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0])
        + CombinatorialModule.getPayout(e, gBurnId[1], gBurnAmt[1])
        + CombinatorialModule.getPayout(e, gBurnId[2], gBurnAmt[2]);

    assert vMint == vBurn,
        "extract then inject is not value neutral";
}

/**
 * @title convert then merge from basket is value-neutral
 * @description convertToYesBasket followed by mergeFromYesBasket returns exactly the original position, minting and burning equal value.
 * @link_property COMBO-ROUNDTRIP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c43343cce42a4c8ea73e898c758eb7fb?anonymousKey=0056b59f8d39b63b56fa2ca8713665078e8d98a3
 * @dev NO(c1^c2) -> YES(!c1) + YES(c1^!c2) -> NO(c1^c2).
 */
rule convertThenMergeFromYesBasketIsValueNeutral(
    env e, address[] toConvert, address toMerge, uint256 fullNoPid, uint256 amt
) {
    require gMintCount == 0 && gBurnCount == 0;
    require fullNoPid % 256 == 1;                         // NO whole (convert requires outcomeIndex 1)
    uint256 fullCondKey = require_uint256(fullNoPid - 1);  // YES condKey
    require CombinatorialModule.legCount(fullCondKey) == 2; // 2-leg full (legs <= 2)
    require toConvert.length == 2;                         // convert requires one recipient per leg

    requireInvariant storedConjunctionsWellFormed(fullCondKey);
    requireInvariant storedConjunctionsCanonical(fullCondKey);

    CombinatorialModule.convertToYesBasket(e, toConvert, fullNoPid, amt);
    CombinatorialModule.mergeFromYesBasket(e, toMerge, fullNoPid, amt);

    assert gMintCount == 3 && gBurnCount == 3,
        "convert-then-mergeFromYesBasket must mint 3 and burn 3 in total";

    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0])
        + CombinatorialModule.getPayout(e, gMintId[1], gMintAmt[1])
        + CombinatorialModule.getPayout(e, gMintId[2], gMintAmt[2]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0])
        + CombinatorialModule.getPayout(e, gBurnId[1], gBurnAmt[1])
        + CombinatorialModule.getPayout(e, gBurnId[2], gBurnAmt[2]);

    assert vMint == vBurn,
        "convertToYesBasket then mergeFromYesBasket is not value neutral";
}

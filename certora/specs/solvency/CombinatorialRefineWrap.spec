
/*
 * MODULE
 * @module CombinatorialModule Position Lifecycle
 * @contract CombinatorialModule
 * @impact split, merge or wrap could break the pairing between a conjunction and its complement, so the pair would redeem for more collateral than created it
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 3 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 *
 * PROPERTIES
 * @property COMBO-WRAP-01 Wrap and unwrap are a value-preserving bijection between an underlying position and its single-leg combinatorial form.
 */

import "CombinatorialRefinementBase.spec";
import "CombinatorialValueConservationBase.spec";
import "./CombinatorialCondIdModel.spec";

// ============================================================
// wrap / unwrap value conservation
//
// wrap/unwrap 1:1-convert between an underlying binary/negrisk position and its single-condition
// combinatorial wrapper. A single-condition conjunction has no product/multi-leg flooring, so the
// conversion is exact (no rounding):
//   payout(combi YES([p])) = floor(a*legFactorNum(p)/D) = BaseModule.getPayout(p)  (underlying)
//   payout(combi NO([p]))  = a - ceil(a*legFactorNum(p)/D) = floor(a*(D-f_p)/D) = underlying flip(p)
// so we assert equality.
//
// Cross-module: the underlying p lives in Binary/NegRisk. We model its payout with
// `underlyingPayoutCVL(q,a) = floor(a*legFactorNum(q)/D)` like in BaseModule.getPayout, and the
// |P|=1 case of the already-validated positionPayoutCVL. legFactorNum reads the shared result ghost by
// conditionId, so it is module-agnostic.
//
// Bounded at legs <= 2.
// ============================================================

// BaseModule.getPayout for an underlying leg: floor(a * result[cid][outcome] / D). result[cid][outcome]
// = legFactorNum(q); the |P|=1 case of positionPayoutCVL. Module-agnostic.
function underlyingPayoutCVL(uint256 q, uint256 amount) returns mathint {
    return (to_mathint(amount) * legFactorNum(q)) / RESULT_DENOMINATOR();
}

methods {
    function CombinatorialModule.wrapCombiId(uint256) external returns (uint256) envfree;
    function CombinatorialModule.unwrapUnderlyingId(uint256) external returns (uint256) envfree;
}

/**
 * @title wrap preserves value exactly
 * @description wrap burns the underlying position and mints exactly the single-leg combinatorial YES, and the two redeem for exactly equal value.
 * @link_property COMBO-WRAP-01
 * @assumption Verified with loops unrolled to at most 2 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af99bffd2a844277bcec0ec6d27d1156?anonymousKey=273d3785acc235032b2b25ceff984f68866077f7
 * @dev burn underlying p, mint combi YES([p]).
 */
rule wrapValueConserving(env e, address to, uint256 underlyingPid, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0, "ghosts starting state";

    uint256 combiId = CombinatorialModule.wrapCombiId(underlyingPid);
    // Combi slot FRESH: _storeLegsFromMemory is idempotent, so a stale colliding slot would else be
    // kept; requiring empty makes the store write [p] and pins legs[combiId] = [underlyingPid].
    // require CombinatorialModule.legCount(combiId) == 0;
    require combiId != underlyingPid;

    CombinatorialModule.wrap(e, to, underlyingPid, amt);

    // (a) supply-delta structure: mint the combi YES([p]), burn the underlying p.
    assert gMintCount == 1 && gBurnCount == 1, "wrap must mint 1 and burn 1";
    assert gMintId[0] == combiId, "wrap must mint the combi YES([p])";
    assert gBurnId[0] == underlyingPid, "wrap must burn the underlying position";

    // (b) EXACT value equality: combi YES([p]) redeems for the same as underlying p.
    mathint vMint = CombinatorialModule.getPayout(e, gMintId[0], gMintAmt[0]);
    mathint vBurn = underlyingPayoutCVL(gBurnId[0], gBurnAmt[0]);
    assert vMint == vBurn, "wrap does not preserve redemption value";
}

/**
 * @title unwrap preserves value exactly
 * @description unwrap burns the single-leg combinatorial position and mints exactly the matching underlying, and the two redeem for exactly equal value.
 * @link_property COMBO-WRAP-01
 * @assumption Verified with loops unrolled to at most 2 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af99bffd2a844277bcec0ec6d27d1156?anonymousKey=273d3785acc235032b2b25ceff984f68866077f7
 * @dev burn combi YES/NO([p]), mint underlying p (YES) / flip(p) (NO).
 */
rule unwrapValueConserving(env e, address to, uint256 combiPid, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0, "ghosts starting state";
    require combiPid % 256 < 2;                              // outcome < 2 (unwrap requires it)
    // wrap stores a 1-leg conjunction, so unwrap's input is one. Stated explicitly because the two
    // invariants below are guarded on legCount > 0, which the replaced `require isCanonical` implied.
    require CombinatorialModule.legCount(combiPid) == 1;
    requireInvariant storedConjunctionsCanonical(combiPid);   // leg module in {BINARY,NEGRISK}, outcome<2

    uint256 underlyingId = CombinatorialModule.unwrapUnderlyingId(combiPid);
    requireInvariant storedConjunctionsWellFormed(combiPid);

    CombinatorialModule.unwrap(e, to, combiPid, amt);

    // supply-delta structure: mint the underlying, burn the combi.
    assert gMintCount == 1 && gBurnCount == 1, "unwrap must mint 1 and burn 1";
    assert gMintId[0] == underlyingId, "unwrap must mint the underlying position";
    assert gBurnId[0] == combiPid, "unwrap must burn the combi position";

    // EXACT value equality: underlying redeems for the same as the combi.
    mathint vMint = underlyingPayoutCVL(gMintId[0], gMintAmt[0]);
    mathint vBurn = CombinatorialModule.getPayout(e, gBurnId[0], gBurnAmt[0]);
    assert vMint == vBurn, "unwrap does not preserve redemption value";
}
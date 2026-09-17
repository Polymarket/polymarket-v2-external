
/*
 * MODULE
 * @module CombinatorialModule Refinement Value Conservation
 * @contract CombinatorialModule
 * @impact A refinement could mint positions worth more than those it consumed, creating redemption value from nothing
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 2 iterations
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 * PROPERTIES
 * @property COMBO-COMPRESS-01 Compress pays out collateral and a residual worth no more than the position it consumed.
 */

import "CombinatorialRefinementBase.spec";
import "CombinatorialValueConservationBase.spec";
import "./CombinatorialCondIdModel.spec";

// ============================================================
// compress value conservation
//
// compress scans Q = legs[pid]; resolved legs fold into a payout factor (paid as collateral / a scaled
// amount), unresolved legs are kept in a residual position. It mints pUSD (collateralOut), so it is not
// collateral-neutral: the obligation is `collateralOut + payout(residual|omega) <= payout(input|omega)`
// at every COMPLETE omega. 
//
// Core challenge is partial vs complete resolution: compress computes its outputs from the compress-time
// resolution (the kept leg u unresolved, else u folds into the factor and there is no residual), but
// value is checked at a complete omega (u resolved). One result-ghost cannot make u both, and getPayout
// reverts while u is unresolved. So u's future factor is a symbolic parameter f_u in [0, D], and the
// payout-at-complete-omega is the parametrized closed form `payoutAtComplete` (positionPayoutCVL's YES=
// floor(amt*P/scale) / NO=amt-ceil(amt*P/scale) with the leg factors passed in).
//
// Bounded at legs <= 2 (Q = {r resolved, u unresolved}).
// ============================================================

ghost uint256 gCollatOut;      // collateral (pUSD) minted by compress (0 if none)
ghost uint256 gCollatCount;

function recordCollatOutCVL(uint256 amt) {
    gCollatOut = amt;
    gCollatCount = require_uint256(gCollatCount + 1);
}

// Payout at a complete omega with the leg factors passed in (positionPayoutCVL's closed form):
// YES = floor(amt*P/scale); NO = amt - ceil(amt*P/scale). Input Q={r,u}: P=f_r*f_u, scale=D^2. Residual
// {u} (1 leg, absent 2nd = D): P=f_u*D, scale=D^2 -> floor(amt*f_u/D).
function payoutAtComplete(mathint outcome, mathint amount, mathint P, mathint scale) returns mathint {
    if (outcome == 0) {
        return (amount * P) / scale;                       // floor
    }
    return amount - (amount * P + scale - 1) / scale;      // amount - ceil
}

methods {
    function CombinatorialModule.singleLegPositionId(uint256, uint256) external returns (uint256) envfree;

    function CollateralToken.mint(address _to, uint256 _amount) external => recordCollatOutCVL(_amount);
}

/**
 * @title compress with a residual conserves value
 * @description When one leg is resolved with a non-zero factor and one is unresolved, the collateral paid plus the residual redeem for no more than the input at every complete resolution.
 * @link_property COMBO-COMPRESS-01
 * @assumption Case split covering one leg resolved with a non-zero payout factor and one leg unresolved
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/fda02888ad28455a83770cc89b69d036?anonymousKey=d83af83f08ce101f830428c2759096891ed0aee9
 * @dev Q = {r resolved (f_r != 0), u unresolved}. The real op pays some collateral and mints a
 *      residual over {u}, burning the input.
 */
rule compressResidualValueConserving(env e, address to, uint256 pid, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0 && gCollatCount == 0 && gCollatOut == 0; // fresh log
    require pid % 256 < 2;                                  // outcome < 2
    uint256 qKey = require_uint256(pid - pid % 256);        // YES condKey of the input
    require CombinatorialModule.legCount(qKey) == 2;        // 2-leg conjunction
    requireInvariant storedConjunctionsCanonical(qKey);       // valid legs (module + outcome<2), ascending

    uint256 leg0 = CombinatorialModule.legAt(qKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(qKey, 1);
    bool res0 = legResolved(leg0);
    bool res1 = legResolved(leg1);
    require res0 != res1;                                   // exactly one resolved -> residual over the other
    uint256 rLeg = res0 ? leg0 : leg1;                      // resolved leg
    uint256 uLeg = res0 ? leg1 : leg0;                      // kept (unresolved) leg
    mathint fr = legFactorNum(rLeg);
    require fr != 0;                                         // f_r == 0 short-circuits (break) -> no residual

    mathint outcome = to_mathint(pid % 256);
    uint256 residualPid = CombinatorialModule.singleLegPositionId(uLeg, assert_uint256(outcome));

    CombinatorialModule.compress(e, to, pid, amt);

    // (a) supply-delta structure: burn the input, mint at most one residual (== the derived residual).
    assert gBurnCount == 1 && gBurnId[0] == pid, "compress must burn the input";
    assert gMintCount <= 1, "compress mints at most one residual position";
    assert gMintCount == 0 || gMintId[0] == residualPid, "compress residual id mismatch";

    // (b) value conservation at every complete omega (u -> f_u in [0, D]).
    mathint fu;
    require fu >= 0 && fu <= RESULT_DENOMINATOR();
    mathint residualVal = gMintCount >= 1
        ? payoutAtComplete(outcome, to_mathint(gMintAmt[0]), fu * RESULT_DENOMINATOR(), D2())
        : 0;
    mathint vOut = to_mathint(gCollatOut) + residualVal;
    mathint vIn = payoutAtComplete(outcome, to_mathint(amt), fr * fu, D2());
    assert vOut <= vIn, "compress creates redemption value";
}

/**
 * @title compress at a terminal zero conserves value
 * @description When a resolved leg pays zero no residual is minted and the collateral paid does not exceed the input value.
 * @link_property COMBO-COMPRESS-01
 * @assumption Case split covering one leg resolved with a zero payout factor and one leg unresolved
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/b0845c967c7a41d8ad097b13f030f957?anonymousKey=f05f3c7707127d2c70fd8b17cdf7bbef7023f7b1
 * @dev Q = {r resolved with f_r == 0, u unresolved}. The zero-payout leg short-circuits the scan
 *      (payoutFactor = 0; break), so YES compresses to nothing and NO pays the full complement as
 *      collateral. No residual is minted on either side.
 */
rule compressTerminalZeroValueConserving(env e, address to, uint256 pid, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0 && gCollatCount == 0 && gCollatOut == 0; // fresh log
    require pid % 256 < 2;                                  // outcome < 2
    uint256 qKey = require_uint256(pid - pid % 256);        // YES condKey of the input
    require CombinatorialModule.legCount(qKey) == 2;        // 2-leg conjunction
    requireInvariant storedConjunctionsCanonical(qKey);       // valid legs (module + outcome<2), ascending

    uint256 leg0 = CombinatorialModule.legAt(qKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(qKey, 1);
    bool res0 = legResolved(leg0);
    bool res1 = legResolved(leg1);
    require res0 != res1;                                   // exactly one resolved
    uint256 rLeg = res0 ? leg0 : leg1;                      // resolved leg
    require legFactorNum(rLeg) == 0;                        // terminal zero: short-circuits the scan

    mathint outcome = to_mathint(pid % 256);

    CombinatorialModule.compress(e, to, pid, amt);

    // (a) supply-delta structure: burn the input, mint NO residual (positionAmount collapses to 0).
    assert gBurnCount == 1 && gBurnId[0] == pid, "compress must burn the input";
    assert gMintCount == 0, "terminal-zero compress mints no residual position";

    // (b) value conservation at every complete omega: P = f_r * f_u = 0, so YES = 0 / NO = amount.
    mathint vOut = to_mathint(gCollatOut);
    mathint vIn = payoutAtComplete(outcome, to_mathint(amt), 0, D2());
    assert vOut <= vIn, "terminal-zero compress creates redemption value";
}

/**
 * @title compress with all legs resolved conserves value
 * @description When every leg is resolved compress mints no residual and pays out collateral worth no more than the input.
 * @link_property COMBO-COMPRESS-01
 * @assumption Case split covering every leg being resolved
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49538196cdd9479c9ddccb8526934ebe?anonymousKey=2f08bb6746c8b70722a63fc43eb82cfaf0240a08
 * @dev Both legs resolved -> no residual, pure collateral (equivalent to redeem).
 */
rule compressAllResolvedValueConserving(env e, address to, uint256 pid, uint256 amt) {
    require gMintCount == 0 && gBurnCount == 0 && gCollatCount == 0 && gCollatOut == 0; // fresh log
    require pid % 256 < 2;
    uint256 qKey = require_uint256(pid - pid % 256);
    require CombinatorialModule.legCount(qKey) == 2;
    requireInvariant storedConjunctionsCanonical(qKey);
    require legResolved(CombinatorialModule.legAt(qKey, 0));
    require legResolved(CombinatorialModule.legAt(qKey, 1));

    uint256 payoutIn = CombinatorialModule.getPayout(e, pid, amt);

    CombinatorialModule.compress(e, to, pid, amt);

    // no residual (all legs resolved); collateral out <= the input's redemption value.
    assert gMintCount == 0, "all-resolved compress mints no residual";
    assert gBurnCount == 1 && gBurnId[0] == pid, "compress must burn the input";
    assert to_mathint(gCollatOut) <= to_mathint(payoutIn), "compress pays out more than the input redeems for";
}
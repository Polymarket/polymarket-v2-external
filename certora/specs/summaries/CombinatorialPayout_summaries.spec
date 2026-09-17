// ============================================================
// CombinatorialPayout_summaries.spec — shared payout model for the combinatorial module.
//
// The result-ghost model + the loop-free payout summaries (condPayoutCVL / positionPayoutCVL).
//
// The 2-leg / D2 variant, wired by certora/specs/solvency/CombinatorialModuleRedeem.spec and
// certora/specs/solvency/CombinatorialRefinementBase.spec.
//
// This file owns the leg-result ghosts, the RESULT_DENOMINATOR / D2 scales, the harness leg views
// (legCount / legAt / condKeyOf) and the getResult ghost summary — everything the payout functions
// read. Consumers must NOT re-declare these. The `_getConditionPayout` / `_getPositionPayout`
// summary WIRING stays in the consumer (the solvency spec wires it; the equivalence spec must not).
// ============================================================

methods {
    // ---- Combinatorial harness views (read the `legs` mapping CVL cannot index) ----
    function CombinatorialModule.legCount(uint256) external returns (uint256) envfree;
    function CombinatorialModule.legAt(uint256, uint256) external returns (uint256) envfree;
    function CombinatorialModule.condKeyOf(CombinatorialModule.ConditionId) external returns (uint256) envfree;

    // Underlying leg results: the combinatorial module reads each leg's result via
    // BaseModule(module).getResult(leg.conditionId()) (module = moduleById[leg.moduleId()]).
    // Route it through the result ghost so the REAL payout AND the liability use the same results.
    function _.getResult(CombinatorialModule.ConditionId cid) external => getResultExtCVL(cid) expect uint256[] memory;
}

// RESULT_DENOMINATOR (BaseModule): results are numerators out of 1e6.
definition RESULT_DENOMINATOR() returns mathint = 1000000;
// D^2 scale (maxLegs = 2): keeps PR = Π(factor/D) an exact integer.
definition D2() returns mathint = 1000000 * 1000000;

// ------------------------------------------------------------
// Underlying-leg result ghosts (binary/negrisk). Keyed by the underlying condition's YES
// position id (outcome byte cleared). Never written in this scene (combinatorial resolves
// nothing) — they are the havoc'd pre-state representing what the underlying modules resolved
// to, read consistently by both the real getResult and the liability.
// ------------------------------------------------------------
ghost mapping(uint256 => bool) ghostResultSet {
    init_state axiom forall uint256 c. !ghostResultSet[c];
}
// element 0 of a resolved result, a numerator out of RESULT_DENOMINATOR (<= 1e6). Element 1 is
// derived as RESULT_DENOMINATOR - element 0, so a resolved result is ALWAYS length 2 with the two
// elements summing to exactly RESULT_DENOMINATOR (1e6) — the shape of a resolved binary/neg-risk
// result. A single ghost makes the sum exact by construction (no two-mapping axiom to couple).
ghost mapping(uint256 => uint256) ghostResultR0 {
    axiom forall uint256 c. to_mathint(ghostResultR0[c]) <= RESULT_DENOMINATOR();
}

// getResult ghost summary: returns an EMPTY array (unresolved) or a length-2 array whose two
// uint256 elements sum to exactly RESULT_DENOMINATOR. Keyed by condKey so a condition read more
// than once (real getResult + liability) observes the same result.
function getResultExtCVL(CombinatorialModule.ConditionId cid) returns uint256[] {
    uint256 condKey = CombinatorialModule.condKeyOf(cid);
    uint256[] res;
    if (ghostResultSet[condKey]) {
        require res.length == 2;
        require res[0] == ghostResultR0[condKey];
        require to_mathint(res[1]) == RESULT_DENOMINATOR() - to_mathint(ghostResultR0[condKey]);
    } else {
        require res.length == 0;
    }
    return res;
}

// True iff the leg's underlying condition is resolved. leg is an underlying position id; its
// YES key (outcome byte cleared) is the ghost key.
function legResolved(uint256 leg) returns bool {
    uint256 uck = require_uint256(leg - leg % 2);
    return ghostResultSet[uck];
}

// The leg's payout numerator for the side it references (element 0 if the leg is YES, element 1 =
// RESULT_DENOMINATOR - element 0 if NO), consistent with the length-2/sum-1e6 getResult ghost.
function legFactorNum(uint256 leg) returns mathint {
    mathint outcome = leg % 2;
    uint256 uck = require_uint256(leg - outcome);
    return outcome == 0 ? to_mathint(ghostResultR0[uck]) : (RESULT_DENOMINATOR() - to_mathint(ghostResultR0[uck]));
}

// Exact model of _getConditionPayout: (resolved, factor). Mirrors the real (res.length == 2 iff
// resolved; conditionPayout = res[outcomeIndex]) with no getResult array and no external call.
function condPayoutCVL(uint256 leg) returns (bool, uint256) {
    bool resolved = legResolved(leg);
    uint256 factor = resolved ? require_uint256(legFactorNum(leg)) : 0;
    return (resolved, factor);
}

// Exact model of _getPositionPayout, unrolled over the (<= 2) legs — no loop, no getResult, no
// chained mulDiv. Shares the pinned P = f0*f1 and D2 scale with combiLiabScaled, so it is exactly
// the contract's payout (the chained mulDiv has no intermediate rounding, 1e36/1e30/1e24 all
// divisible by 1e6) and couples to the liability with no nonlinear reasoning beyond amount*P:
//   YES -> floor(amount*P/D2);  NO -> amount - ceil(amount*P/D2)
//   terminal-zero (a resolved leg pays 0) -> 0 (YES) / amount (NO)
//   unresolved (no zero) / outcome >= 2 / unprepared -> revert (mirrors the real reverts)
//   msg.value != 0 -> revert (getPayout is a non-payable view; a value-bearing call reverts)
function positionPayoutCVL(env e, uint256 positionId, uint256 amount) returns uint256 {
    if (e.msg.value != 0) { revert(); } // non-payable getPayout
    mathint outcome = positionId % 256;
    if (outcome != 0 && outcome != 1) { revert(); } // require(outcomeIndex < 2)
    uint256 condKey = require_uint256(positionId - outcome);
    uint256 cnt = CombinatorialModule.legCount(condKey);
    if (cnt == 0) { revert(); } // ConditionNotPrepared
    require cnt <= 2, "bounded proof: combinatorial conjunction has 1 or 2 legs";

    bool r0;
    uint256 p0;
    r0, p0 = condPayoutCVL(CombinatorialModule.legAt(condKey, 0));

    bool r1 = true; // arity-1: absent second leg = resolved certain factor D
    uint256 p1 = require_uint256(RESULT_DENOMINATOR());
    if (cnt == 2) {
        r1, p1 = condPayoutCVL(CombinatorialModule.legAt(condKey, 1));
    }

    bool zero = (r0 && p0 == 0) || (cnt == 2 && r1 && p1 == 0);
    bool anyUnresolved = !r0 || (cnt == 2 && !r1);
    uint256 P = require_uint256(to_mathint(p0) * to_mathint(p1)); // same P as combiLiabScaled

    if (outcome == 0) {
        if (zero) { return 0; }
        if (anyUnresolved) { revert(); } // PositionNotRedeemable
        return require_uint256(to_mathint(amount) * to_mathint(P) / D2()); // floor
    } else {
        if (zero) { return amount; }
        if (anyUnresolved) { revert(); } // PositionNotRedeemable
        return require_uint256(to_mathint(amount) - (to_mathint(amount) * to_mathint(P) + D2() - 1) / D2()); // amount - ceil
    }
}

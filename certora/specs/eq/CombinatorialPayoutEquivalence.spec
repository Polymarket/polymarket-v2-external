// ============================================================
// Certifies that positionPayoutCVL and transitively condPayoutCVL in
// certora/specs/summaries/CombinatorialPayout_summaries.spec faithfully models the REAL
// CombinatorialModule._getPositionPayout so the solvency spec, which uses 
// positionPayoutCVL as the summary of _getPositionPayout, may soundly rely on it.
//
// The real payout reads leg results through the getResult ghost summary (getResultExtCVL) 
// and the summary reads the same ghosts (legResolved/legFactorNum), so no
// real-storage coupling is needed — the proof is the pure arithmetic claim
//   loop + chained mulDiv  ==  floor(amount*P/D2) (YES) / amount - ceil(amount*P/D2) (NO).
//
// CASE-SPLIT STRUCTURE. Family of case rules, each with one control-flow:
//
//   VALUE family (real call with reverting paths pruned):
//     * outcome in {YES, NO} x legCount in {1, 2}  ->  4 base rules
//     * the 2-leg rules are further split by resolved-leg status, partitioning the non-reverting
//       input space:
//         zeroFactor : some RESOLVED leg pays 0 (terminal early-return; other leg status free)
//         bothFull   : both resolved, both factors == RESULT_DENOMINATOR (mulDiv chain skipped)
//         oneScaled  : both resolved, exactly one factor in (0, D) (one chained mulDiv)
//         bothScaled : both resolved, both factors in (0, D) (two chained mulDivs — the
//                      nonlinear-arithmetic core, isolated so the solver faces it alone)
//       The remaining 2-leg states (some leg unresolved and no resolved zero) revert on both
//       sides.
//
//   REVERT family (both calls @withrevert), split by revert cause. The five cases partition the
//   full input space, so together they imply realRev <=> summRev:
//     msgValue / invalidOutcome / unprepared / unresolved  ->  assert both sides revert
//     resolvedOrZero (residual)                            ->  assert neither side reverts
//
//   STEPPING-STONE DECOMPOSITION (the two bothScaled rules). The two rules 
//   chain small asserts, checked via multi_assert_check (each assert is
//   verified with all EARLIER asserts assumed; the stones are asserts, not requires, so the
//   chain is sound):
//     1. shape/operands: the real chain's three mulDiv calls are pinned through the call log
//        of muldiv_logged.spec;
//     2. exactness: each intermediate mulDiv is divisibility-exact (pf1 = 1e30*f0,
//        pf2 = 1e24*f0*f1);
//     3. cancellation: with t = amount*f0*f1 held opaque, floor(t*1e24/1e36) == floor(t/1e12)
//        (resp. the ceil analogue) is linear in t;
//     4. the final realOut == summOut assert only reassembles 1–3 by congruence.
// ============================================================

import "../summaries/PositionManager_full_summaries.spec";
import "../summaries/CombinatorialPayout_summaries.spec";
import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";
import "../summaries/Solady/SafeTransferLib.spec";
import "../summaries/CTFHelpers_summaries.spec";
import "../summaries/muldiv_logged.spec"; 

using CombinatorialModule as CombinatorialModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;

links {
    PositionManager.moduleById[_] => [CombinatorialModule];
    PositionManager.COLLATERAL_TOKEN => CollateralToken;

    CombinatorialModule.POSITION_MANAGER => PositionManager;
    CombinatorialModule.COLLATERAL_TOKEN => CollateralToken;
}

methods {
    function CombinatorialModule.moduleId() external returns uint256 => 3; // 3 == ModuleIds.COMBINATORIAL
    // Combinatorial module dispatch for the underlying leg's getResult target.
    function _.moduleId() external => DISPATCHER(true);
    // The real _getPositionPayout, exposed. NOT summarized — this is the code under test.
    function CombinatorialModule.getPayout(CombinatorialModule.PositionId, uint256) external returns (uint256);

    // ---- Call resolution ----
    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);
}

/*--------------------------------------------------------------
                       SHARED CASE SETUP
--------------------------------------------------------------*/

// Reachable-state assumptions shared by every case rule (identical to the original monolithic
// rules): bounded to <= 2 legs (loop_iter = 2 on the real side), and stored legs are binary/
// neg-risk YES/NO position ids (outcome byte in {0,1}) so the real getResult key coincides with
// the summary key and res[leg.outcomeIndex()] is in-bounds. Returns the condKey.
function setupBoundedWellFormed(uint256 positionId) returns uint256 {
    uint256 condKey = require_uint256(positionId - positionId % 256);
    uint256 cnt = CombinatorialModule.legCount(condKey);
    require cnt <= 2; // bounded proof; loop_iter = 2 on the real side
    if (cnt >= 1) { require CombinatorialModule.legAt(condKey, 0) % 256 < 2; }
    if (cnt == 2) { require CombinatorialModule.legAt(condKey, 1) % 256 < 2; }
    return condKey;
}

/*--------------------------------------------------------------
                    VALUE EQUIVALENCE — 1 LEG
--------------------------------------------------------------*/

/// @title Value, YES, 1 leg. All leg statuses (zero / full / scaled) — a single mulDiv at most;
///        unresolved states revert on the real side and are pruned.
rule valueEq_yes_1Leg(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 0;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 1;

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/// @title Value, NO, 1 leg. All leg statuses (zero / full / scaled).
rule valueEq_no_1Leg(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 1;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 1;

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/*--------------------------------------------------------------
                 VALUE EQUIVALENCE — 2 LEGS, YES
--------------------------------------------------------------*/

/// @title Value, YES, 2 legs: some RESOLVED leg pays 0 -> terminal payout 0. Other leg free.
rule valueEq_yes_2Legs_zeroFactor(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 0;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require (legResolved(leg0) && legFactorNum(leg0) == 0) || (legResolved(leg1) && legFactorNum(leg1) == 0);

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/// @title Value, YES, 2 legs: both resolved, both factors == D -> mulDiv chain fully skipped.
rule valueEq_yes_2Legs_bothFull(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 0;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require legResolved(leg0) && legResolved(leg1);
    require legFactorNum(leg0) == RESULT_DENOMINATOR() && legFactorNum(leg1) == RESULT_DENOMINATOR();

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/// @title Value, YES, 2 legs: both resolved, exactly one factor in (0, D) -> one chained mulDiv.
rule valueEq_yes_2Legs_oneScaled(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 0;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require legResolved(leg0) && legResolved(leg1);
    mathint f0 = legFactorNum(leg0);
    mathint f1 = legFactorNum(leg1);
    require f0 > 0 && f1 > 0;
    require (f0 == RESULT_DENOMINATOR() && f1 < RESULT_DENOMINATOR())
        || (f0 < RESULT_DENOMINATOR() && f1 == RESULT_DENOMINATOR());

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/// @title Value, YES, 2 legs: both resolved, both factors in (0, D) -> two chained mulDivs.
///        The nonlinear-arithmetic core, proven as a stepping-stone chain: shape/operands ->
///        chain exactness -> linear-in-t cancellation -> reassembly by congruence.
rule valueEq_yes_2Legs_bothScaled(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 0;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require legResolved(leg0) && legResolved(leg1);
    mathint f0 = legFactorNum(leg0);
    mathint f1 = legFactorNum(leg1);
    require f0 > 0 && f0 < RESULT_DENOMINATOR();
    require f1 > 0 && f1 < RESULT_DENOMINATOR();
    require gMdCount == 0 && gMduCount == 0; // fresh mulDiv call log (havoc'd otherwise)

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);

    // Chain shape: the both-scaled YES path makes exactly three mulDiv calls,
    //   (1e36, f0, 1e6) -> pf1;  (pf1, f1, 1e6) -> pf2;  (amount, pf2, 1e36) -> realOut.
    assert gMdCount == 3, "chain shape: exactly three mulDiv calls";
    assert gMdX[0] == 10^36 && gMdY[0] == f0 && gMdD[0] == 10^6, "call 0 operands";
    // Exactness: 1e6 divides 1e36*f0, so the floor is exact — linear in f0.
    assert gMdOut[0] == 10^30 * f0, "pf1 = 1e30*f0 (exact)";
    assert gMdX[1] == gMdOut[0] && gMdY[1] == f1 && gMdD[1] == 10^6, "call 1 operands";
    // Exactness: 1e6 divides 1e30*f0*f1 — linear in the opaque monomial f0*f1.
    assert gMdOut[1] == 10^24 * f0 * f1, "pf2 = 1e24*f0*f1 (exact)";
    assert gMdX[2] == amount && gMdY[2] == gMdOut[1] && gMdD[2] == 10^36, "call 2 operands";

    // Cancellation, made linear: hold t = amount*f0*f1 opaque.
    mathint t = amount * f0 * f1;
    assert amount * gMdOut[1] == t * 10^24, "final numerator is t*1e24 (AC of multiplication)";
    assert (t * 10^24) / 10^36 == t / 10^12, "floor cancellation, linear in t";

    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    // Reassembly: realOut = floor(amount*pf2/1e36) = floor(t/1e12) = summOut from the stones.
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/*--------------------------------------------------------------
                 VALUE EQUIVALENCE — 2 LEGS, NO
--------------------------------------------------------------*/

/// @title Value, NO, 2 legs: some RESOLVED leg pays 0 -> terminal payout `amount`. Other leg free.
rule valueEq_no_2Legs_zeroFactor(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 1;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require (legResolved(leg0) && legFactorNum(leg0) == 0) || (legResolved(leg1) && legFactorNum(leg1) == 0);

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/// @title Value, NO, 2 legs: both resolved, both factors == D -> mulDivUp chain fully skipped.
rule valueEq_no_2Legs_bothFull(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 1;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require legResolved(leg0) && legResolved(leg1);
    require legFactorNum(leg0) == RESULT_DENOMINATOR() && legFactorNum(leg1) == RESULT_DENOMINATOR();

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/// @title Value, NO, 2 legs: both resolved, exactly one factor in (0, D) -> one chained mulDivUp.
rule valueEq_no_2Legs_oneScaled(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 1;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require legResolved(leg0) && legResolved(leg1);
    mathint f0 = legFactorNum(leg0);
    mathint f1 = legFactorNum(leg1);
    require f0 > 0 && f1 > 0;
    require (f0 == RESULT_DENOMINATOR() && f1 < RESULT_DENOMINATOR())
        || (f0 < RESULT_DENOMINATOR() && f1 == RESULT_DENOMINATOR());

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);
    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/// @title Value, NO, 2 legs: both resolved, both factors in (0, D) -> two chained mulDivUps.
///        The nonlinear-arithmetic core (ceil variant), proven as a stepping-stone chain —
///        the mulDivUp mirror of valueEq_yes_2Legs_bothScaled.
rule valueEq_no_2Legs_bothScaled(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 1;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
    require legResolved(leg0) && legResolved(leg1);
    mathint f0 = legFactorNum(leg0);
    mathint f1 = legFactorNum(leg1);
    require f0 > 0 && f0 < RESULT_DENOMINATOR();
    require f1 > 0 && f1 < RESULT_DENOMINATOR();
    require gMdCount == 0 && gMduCount == 0; // fresh mulDiv call log (havoc'd otherwise)

    uint256 realOut = CombinatorialModule.getPayout(e, positionId, amount);

    // Chain shape: the both-scaled NO path makes exactly three mulDivUp calls,
    //   (1e36, f0, 1e6) -> pf1;  (pf1, f1, 1e6) -> pf2;  (amount, pf2, 1e36) -> ceil part.
    assert gMduCount == 3, "chain shape: exactly three mulDivUp calls";
    assert gMduX[0] == 10^36 && gMduY[0] == f0 && gMduD[0] == 10^6, "call 0 operands";
    // Exactness: 1e6 divides 1e36*f0, so the ceil equals the exact quotient — linear in f0.
    assert gMduOut[0] == 10^30 * f0, "pf1 = 1e30*f0 (exact)";
    assert gMduX[1] == gMduOut[0] && gMduY[1] == f1 && gMduD[1] == 10^6, "call 1 operands";
    // Exactness: 1e6 divides 1e30*f0*f1 — linear in the opaque monomial f0*f1.
    assert gMduOut[1] == 10^24 * f0 * f1, "pf2 = 1e24*f0*f1 (exact)";
    assert gMduX[2] == amount && gMduY[2] == gMduOut[1] && gMduD[2] == 10^36, "call 2 operands";

    // Cancellation (ceil form), made linear: hold t = amount*f0*f1 opaque.
    mathint t = amount * f0 * f1;
    assert amount * gMduOut[1] == t * 10^24, "final numerator is t*1e24 (AC of multiplication)";
    assert (t * 10^24 + 10^36 - 1) / 10^36 == (t + 10^12 - 1) / 10^12, "ceil cancellation, linear in t";

    uint256 summOut = positionPayoutCVL(e, positionId, amount);
    // Reassembly: realOut = amount - ceil(amount*pf2/1e36) = amount - ceil(t/1e12) = summOut.
    assert realOut == summOut, "payout summary: value must match the real _getPositionPayout";
}

/*--------------------------------------------------------------
              REVERT EQUIVALENCE — CAUSE PARTITION
--------------------------------------------------------------*/

/// @title Revert: value-bearing call. getPayout is a non-payable view; both sides revert.
rule revertEq_msgValue(env e, uint256 positionId, uint256 amount) {
    require e.msg.value != 0;
    uint256 condKey = setupBoundedWellFormed(positionId);

    uint256 realOut = CombinatorialModule.getPayout@withrevert(e, positionId, amount);
    bool realRev = lastReverted;
    uint256 summOut = positionPayoutCVL@withrevert(e, positionId, amount);
    bool summRev = lastReverted;
    assert realRev && summRev, "value-bearing call: both sides must revert";
}

/// @title Revert: outcome byte >= 2 (InvalidOutcomeIndex); both sides revert.
rule revertEq_invalidOutcome(env e, uint256 positionId, uint256 amount) {
    require e.msg.value == 0;
    require positionId % 256 >= 2;
    uint256 condKey = setupBoundedWellFormed(positionId);

    uint256 realOut = CombinatorialModule.getPayout@withrevert(e, positionId, amount);
    bool realRev = lastReverted;
    uint256 summOut = positionPayoutCVL@withrevert(e, positionId, amount);
    bool summRev = lastReverted;
    assert realRev && summRev, "invalid outcome: both sides must revert";
}

/// @title Revert: no legs stored (ConditionNotPrepared); both sides revert.
rule revertEq_unprepared(env e, uint256 positionId, uint256 amount) {
    require e.msg.value == 0;
    require positionId % 256 < 2;
    uint256 condKey = setupBoundedWellFormed(positionId);
    require CombinatorialModule.legCount(condKey) == 0;

    uint256 realOut = CombinatorialModule.getPayout@withrevert(e, positionId, amount);
    bool realRev = lastReverted;
    uint256 summOut = positionPayoutCVL@withrevert(e, positionId, amount);
    bool summRev = lastReverted;
    assert realRev && summRev, "unprepared condition: both sides must revert";
}

/// @title Revert: some leg unresolved and NO resolved leg pays 0 (PositionNotRedeemable);
///        both sides revert. (An unresolved leg alongside a resolved zero does NOT revert —
///        the zero short-circuits first on both sides; that state is in revertEq_resolvedOrZero.)
rule revertEq_unresolved(env e, uint256 positionId, uint256 amount) {
    require e.msg.value == 0;
    require positionId % 256 < 2;
    uint256 condKey = setupBoundedWellFormed(positionId);
    uint256 cnt = CombinatorialModule.legCount(condKey);
    require cnt == 1 || cnt == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    if (cnt == 2) {
        uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
        require !legResolved(leg0) || !legResolved(leg1);
        require !(legResolved(leg0) && legFactorNum(leg0) == 0);
        require !(legResolved(leg1) && legFactorNum(leg1) == 0);
    } else {
        require !legResolved(leg0); // 1 leg: unresolved, hence no resolved zero either
    }

    uint256 realOut = CombinatorialModule.getPayout@withrevert(e, positionId, amount);
    bool realRev = lastReverted;
    uint256 summOut = positionPayoutCVL@withrevert(e, positionId, amount);
    bool summRev = lastReverted;
    assert realRev && summRev, "unresolved without terminal zero: both sides must revert";
}

/// @title Residual: prepared, valid outcome, zero-value call, and (all legs resolved OR some
///        resolved leg pays 0) — neither side reverts. Together with the four cases above this
///        partitions the input space, discharging the original realRev <=> summRev biconditional.
rule revertEq_resolvedOrZero(env e, uint256 positionId, uint256 amount) {
    require e.msg.value == 0;
    require positionId % 256 < 2;
    uint256 condKey = setupBoundedWellFormed(positionId);
    uint256 cnt = CombinatorialModule.legCount(condKey);
    require cnt == 1 || cnt == 2;
    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    if (cnt == 2) {
        uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
        require (legResolved(leg0) && legResolved(leg1))
            || (legResolved(leg0) && legFactorNum(leg0) == 0)
            || (legResolved(leg1) && legFactorNum(leg1) == 0);
    } else {
        require legResolved(leg0);
    }

    uint256 realOut = CombinatorialModule.getPayout@withrevert(e, positionId, amount);
    bool realRev = lastReverted;
    uint256 summOut = positionPayoutCVL@withrevert(e, positionId, amount);
    bool summRev = lastReverted;
    assert !realRev && !summRev, "resolved (or terminal-zero) state: neither side may revert";
}

/*--------------------------------------------------------------
              PAYOUT GATE — STANDALONE (REAL getPayout)
--------------------------------------------------------------*/

/// @title [COMBO-PAYOUT-GATE-01a] YES getPayout reverts unless fully resolved or terminally false.
rule payoutGateYes(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 0;                          // YES
    uint256 condKey = setupBoundedWellFormed(positionId);
    uint256 cnt = CombinatorialModule.legCount(condKey);
    require cnt == 1 || cnt == 2;                           // prepared (legCount > 0), bounded

    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    bool res0 = legResolved(leg0);
    bool zero0 = res0 && legFactorNum(leg0) == 0;
    bool res1;
    bool zero1;
    if (cnt == 2) {
        uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
        res1 = legResolved(leg1);
        zero1 = res1 && legFactorNum(leg1) == 0;
    } else {
        res1 = true;                                       // absent second leg: resolved constant
        zero1 = false;
    }
    bool allResolved = res0 && res1;
    bool terminalFalse = zero0 || zero1;
    bool msgValueZero = e.msg.value == 0;

    uint256 out = CombinatorialModule.getPayout@withrevert(e, positionId, amount);
    bool rev = lastReverted;

    assert rev <=> !(allResolved || terminalFalse) || !msgValueZero,
        "YES getPayout must revert iff not fully resolved and not terminally false";
    assert (!rev && terminalFalse) => out == 0, "terminally-false YES payout must be zero";
}

/// @title [COMBO-PAYOUT-GATE-01b] NO getPayout reverts unless fully resolved or terminally true.
rule payoutGateNo(env e, uint256 positionId, uint256 amount) {
    require positionId % 256 == 1;                          // NO
    uint256 condKey = setupBoundedWellFormed(positionId);
    uint256 cnt = CombinatorialModule.legCount(condKey);
    require cnt == 1 || cnt == 2;                           // prepared (legCount > 0), bounded

    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    bool res0 = legResolved(leg0);
    bool zero0 = res0 && legFactorNum(leg0) == 0;
    bool res1;
    bool zero1;
    if (cnt == 2) {
        uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
        res1 = legResolved(leg1);
        zero1 = res1 && legFactorNum(leg1) == 0;
    } else {
        res1 = true;                                       // absent second leg: resolved constant
        zero1 = false;
    }
    bool allResolved = res0 && res1;
    bool terminalTrue = zero0 || zero1;
    bool msgValueZero = e.msg.value == 0;

    uint256 out = CombinatorialModule.getPayout@withrevert(e, positionId, amount);
    bool rev = lastReverted;

    assert rev <=> !(allResolved || terminalTrue) || !msgValueZero,
        "NO getPayout must revert iff not fully resolved and not terminally true";
    assert (!rev && terminalTrue) => out == amount, "terminally-true NO payout must equal amount";
}

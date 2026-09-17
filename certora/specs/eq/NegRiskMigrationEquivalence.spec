// ============================================================
// Faithfulness of the two migration abstractions the NegRiskModule solvency proof 
// relies on:
//
//   #6  _redeemIfResolvedDuringMigrate  =>  the nondet {0, DENOM} over-approximation
//       (opted in via `_useMigrateRedeemModel => ALWAYS(true)`, `_nondetResolved => NONDET`,
//        `_nondetBinaryR0 => NONDET`, filtered to {0, D} by the real `_storeResult` guard).
//   #7  payoutNumerators                =>  legacyPayoutCVL / ghostLegacyPayout, the assumption
//       that the LEGACY CTF payout vector has one of the three canonical binary shapes
//       (0,0) / (1,0) / (0,1).
//
// The solvency proof runs the model (#6) and assumes the canonical legacy shape (#7). This spec
// discharges both against the real body:
// it does not opt into the model (so `_useMigrateRedeemModel` stays false and the override falls
// through to the production `_redeemIfResolved`), and it drives that real body through the harness
// wrapper `redeemIfResolvedDuringMigrateReal`, reading the same legacy-payout ghost the solvency
// spec reads.
//
// -------------------------------------------------------------------------------------------
// #6 — WHY "stored r0 in {0, D}" is the model-covers-real inclusion.
//
// The model and the real body share the entire `_finalizeMigrationResolution ->
// _finalizeNegriskResolution -> _storeResult` finalize pipeline; the only difference is the value
// of `result_[0]` handed to it (model: nondet `_nondetBinaryR0`; real: `p0 * D / (p0 + p1)`).
// The model's reachable, non-reverting post-states are therefore exactly:
//   * resolved == false                       -> return false, no store        (nondetResolved)
//   * resolved, result already non-empty       -> return true,  no store
//   * resolved, result empty, r0 in {0, D}     -> return true,  store [r0, D-r0]  (any r0 in {0,D};
//                                                 other r0 revert at the _storeResult guard)
// The real body's store-decision (`result empty`) and return value (`p0+p1 != 0`) are structurally
// identical to the model's (the model's nondet `resolved` covers `p0+p1 != 0`), so coverage reduces
// to: whenever the real body stores, its stored `result_[0]` lies in the model's reachable store set
// {0, D}. That is asserted directly below. It holds for arbitrary legacy payouts because the real
// `NegRiskModule._storeResult` reverts unless `result0 in {0, D}` — so every non-reverting real
// store already has the binary shape the model assumes. Hence the model soundly over-approximates.
//
// #7 — WHY the canonical legacy-payout assumption is sufficient.
//
// legacyPayoutCVL is the exact read the real `_redeemIfResolved` performs (routed through the same
// `payoutNumerators` wildcard). Under the canonical shape, the real division `p0 * D / (p0 + p1)`
// evaluates to: (0,0) -> denominator 0 -> returns false (no store); (1,0) -> D; (0,1) -> 0. So the
// real store never trips the `_storeResult` binary guard, and the stored r0 is the binary
// projection of the legacy payout. This certifies (a) legacyPayoutCVL feeds the real division, and
// (b) the canonical assumption is exactly what makes that division land on {0, D}.
// ============================================================

import "../summaries/Solady/ERC1155.spec";
import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";

using NegRiskModuleHarness as NegRiskModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;

links {
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;
}

methods {
    // ---- harness result / event views (envfree storage reads) ----
    function NegRiskModule.resultLen(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function NegRiskModule.realR0(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function NegRiskModule.realR1(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function NegRiskModule.resolutionPausedAtOf(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function NegRiskModule.eventOfCond(NegRiskModule.ConditionId) external returns (NegRiskModule.EventId) envfree;
    function NegRiskModule.condIndexOf(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function NegRiskModule.resultsSumOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function NegRiskModule.conditionsResolvedOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function NegRiskModule.yesSumOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function NegRiskModule.conditionCount(NegRiskModule.EventId) external returns (uint256) envfree;
    function NegRiskModule.condAt(NegRiskModule.EventId, uint256) external returns (NegRiskModule.ConditionId) envfree;

    // ---- legacy CTF payout read: route to the SAME ghost the solvency spec reads (#7 target) ----
    // Summarize the exact linked contract method, not a wildcard: `_legacyConditionalTokens()` returns
    // the linked `ConditionalTokens` instance, so the call resolves to its concrete array-getter and a
    // `_.payoutNumerators` wildcard is shadowed (the real, unconstrained CTF storage would be read).
    function ConditionalTokens.payoutNumerators(bytes32 cid, uint256 ix) external returns (uint256) =>
        legacyPayoutCVL(cid, ix);

    // ---- legacy plumbing: legacy-CTF-only side effects, out of scope for the V2 result store ----
    function _._redeemLegacyPositions(bytes32) internal => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;

    // ---- scene wiring: PositionManager / CollateralToken / ConditionalTokens are compiled WITH
    //      source (added to conf files) so their transforms don't crash the points-to analysis the
    //      way the previously auto-loaded, source-less contracts did ("No precise source code info").
    //      PM's ERC1155 keccak-slot assembly is tamed by ERC1155.spec (external mint/batchMint route
    //      through the summarized internal _mint/_batchMint). Immutable getters resolve to the scene
    //      instances. None of these are on the rules' redeem/store path.
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;
    function _._legacyConditionalTokens() external => ConditionalTokens expect address;

    // Raw-assembly ID libraries poison PTA across the whole migrate call graph — NONDET them
    // (same rationale as NegRisk-Solvency02.spec); partition() gets a clean CVL array.
    function CTFHelpers.partition() internal returns (uint256[] memory) => partitionCVL();
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;

    // Legacy CTF externals reached only by the migrate loop's complementary-merge bookkeeping —
    // legacy-side effects, out of scope for the V2 result store the rules read.
    function ConditionalTokens.balanceOf(address, uint256) external returns (uint256) => NONDET;
    function ConditionalTokens.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function ConditionalTokens.safeBatchTransferFrom(address, address, uint256[], uint256[], bytes) external => NONDET;

    // ---- OwnableRoles / handover taming (currentContract == NegRiskModuleHarness) ----
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal =>
        updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

/*--------------------------------------------------------------
                        DEFINITIONS / GHOSTS
--------------------------------------------------------------*/

// RESULT_DENOMINATOR (BaseModule): neg-risk results are numerators out of 1e6.
definition D() returns mathint = 1000000;

persistent ghost mapping(bytes32 => mapping(uint256 => uint256)) gLegacyPayout;

// The exact read the real _redeemIfResolved performs, wired to `payoutNumerators`.
function legacyPayoutCVL(bytes32 cid, uint256 ix) returns uint256 {
    return gLegacyPayout[cid][ix];
}

// CTFHelpers.partition() always returns the fixed binary partition [0b01, 0b10]; a clean CVL array
// avoids the raw-assembly free-memory-pointer bumps that poison PTA across the migrate call graph.
function partitionCVL() returns uint256[] {
    uint256[] p;
    require p.length == 2, "partition() always returns a 2-element array";
    require p[0] == 1, "partition()[0] is the YES index set 0b01";
    require p[1] == 2, "partition()[1] is the NO index set 0b10";
    return p;
}

// Reachability preconditions shared by both rules: a fresh, unpaused, valid neg-risk condition so
// the real body actually reaches (and does not spuriously revert before) the result store.
function requireStoreReachable(NegRiskModule.ConditionId cid) {
    require resultLen(cid) == 0;                    // fresh: exercises the len 0 -> 2 store
    require resolutionPausedAtOf(cid) == 0;         // not paused: passes the ResolutionIsPaused guard
    NegRiskModule.EventId ev = eventOfCond(cid);
    require conditionCount(ev) != 0;                // valid neg-risk event (InvalidEventId)
    require condIndexOf(cid) < conditionCount(ev);  // real leg: skips the bridge-role (== count) branch
    require resultsSumOf(ev) == 0;                  // no sibling YES yet (InvalidResults on r0 == D)
    require conditionsResolvedOf(ev) < conditionCount(ev); // headroom for the resolved-count bump
    // Fresh event => the harness YES-sum mirror is 0 (it tracks the sum of stored r0's, and nothing
    // is stored yet). Without this, the mirror's checked add `yesSumMirror += r0` in the `_storeResult`
    // override could overflow from an unconstrained initial value and spuriously revert the real body
    // — a harness artifact (production has no such mirror), not a faithfulness violation.
    require yesSumOf(ev) == 0;
}

/*--------------------------------------------------------------
   #6 — MODEL OVER-APPROXIMATION SOUNDNESS (model covers real)
--------------------------------------------------------------*/

/// @title The real migrate-loop redeem only ever stores a BINARY result.
/// @dev Arbitrary legacy payouts (gLegacyPayout unconstrained). On every non-reverting real store,
///      the stored r0 lies in {0, D} and r1 completes the pair. Since the model
///      (`_nondetBinaryR0 => NONDET` filtered by the shared `_storeResult` binary guard) can emit any
///      {0, D} result through the same finalize pipeline, and its store-decision / return value
///      match the real body structurally, this is exactly the model-covers-real inclusion.
rule migrateRedeemModelCoversReal(env e, NegRiskModule.ConditionId cid, bytes32 legacyId) {
    requireStoreReachable(cid);
    require e.msg.value == 0; // the wrapper is non-payable: msg.value != 0 is a spurious payable-check revert

    bool ret = redeemIfResolvedDuringMigrateReal@withrevert(e, cid, legacyId);
    bool reverted = lastReverted;

    // We reason only about non-reverting executions (a revert changes no state the solvency bound
    // reads, and the model likewise reverts on a non-{0,D} nondet r0 via the shared guard).
    bool stored = !reverted && ret && resultLen(cid) == 2;

    assert stored => (realR0(cid) == 0 || to_mathint(realR0(cid)) == D()),
        "over-approx (#6): a non-reverting real migrate store must have r0 in {0, D} (model's reachable set)";
    assert stored => to_mathint(realR1(cid)) == D() - to_mathint(realR0(cid)),
        "over-approx (#6): r1 must complete the binary pair to exactly D";

    // Non-vacuity: the binary store is actually reachable (else the assertions are trivially true).
    satisfy stored;
}

/*--------------------------------------------------------------
   #7 — CANONICAL LEGACY-PAYOUT ASSUMPTION IS SUFFICIENT / FAITHFUL
--------------------------------------------------------------*/

/// @title Under the canonical binary legacy shape, the real division yields exactly the binary
///        projection of the legacy payout and never trips the `_storeResult` guard.
/// @dev Constrains gLegacyPayout to the three canonical shapes (the ghostLegacyPayout axiom in
///      NegRisk-Solvency02.spec). This certifies (a) legacyPayoutCVL feeds the real
///      `p0 * D / (p0 + p1)` division, and (b) the assumption is sufficient: (0,0) short-circuits
///      to "not resolved" (no store), (1,0) -> r0 = D, (0,1) -> r0 = 0.
rule legacyPayoutCanonicalIsBinary(env e, NegRiskModule.ConditionId cid, bytes32 legacyId) {
    requireStoreReachable(cid);
    require e.msg.value == 0; // the wrapper is non-payable: msg.value != 0 is a spurious payable-check revert

    // Canonical binary legacy shape (the ghostLegacyPayout axiom, applied to the read leg).
    require (gLegacyPayout[legacyId][0] == 0 && gLegacyPayout[legacyId][1] == 0)
        || (gLegacyPayout[legacyId][0] == 1 && gLegacyPayout[legacyId][1] == 0)
        || (gLegacyPayout[legacyId][0] == 0 && gLegacyPayout[legacyId][1] == 1);

    NegRiskModule.EventId ev = eventOfCond(cid);
    uint256 countPre = conditionCount(ev);
    uint256 resolvedPre = conditionsResolvedOf(ev);
    uint256 synthLenPre = resultLen(condAt(ev, countPre));

    bool ret = redeemIfResolvedDuringMigrateReal@withrevert(e, cid, legacyId);
    bool reverted = lastReverted;

    // (0,0): denominator 0 -> the real body returns false and stores nothing.
    bool zeroPayout = gLegacyPayout[legacyId][0] == 0 && gLegacyPayout[legacyId][1] == 0;

    // (A) Every reachable revert is the event-level all-NO completion guard.
    assert reverted => (
        gLegacyPayout[legacyId][1] == 1
            && to_mathint(resolvedPre) + 1 == to_mathint(countPre)
            && synthLenPre != 0
    ), "faithfulness (#7): the only reachable revert is the all-NO completion guard, not the binary guard";

    // (B) A (0,0) legacy payout short-circuits on the zero denominator: total, and no store.
    assert zeroPayout => (!reverted && !ret && resultLen(cid) == 0),
        "faithfulness (#7): a (0,0) legacy payout is unresolved -> no revert, return false, no store";
    assert (!reverted && !zeroPayout) => (ret && resultLen(cid) == 2),
        "faithfulness (#7): a resolved canonical payout stores a length-2 result and returns true";

    // The stored r0 is the exact binary projection of the legacy payout: (1,0) -> D, (0,1) -> 0.
    assert (!reverted && !zeroPayout && gLegacyPayout[legacyId][0] == 1) => to_mathint(realR0(cid)) == D(),
        "faithfulness (#7): legacy YES (1,0) -> stored r0 == D";
    assert (!reverted && !zeroPayout && gLegacyPayout[legacyId][1] == 1) => realR0(cid) == 0,
        "faithfulness (#7): legacy NO (0,1) -> stored r0 == 0";

    satisfy !reverted && !zeroPayout && ret; // non-vacuity: a resolved canonical store is reachable
}

/*--------------------------------------------------------------
   #7b — Assertion (A) is not vacuous
--------------------------------------------------------------*/

/// @title The all-NO completion guard is reachable under a canonical legacy payout.
rule allNoCompletionGuardIsReachable(env e, NegRiskModule.ConditionId cid, bytes32 legacyId) {
    requireStoreReachable(cid);

    // Legacy NO (0,1): drives r0 == 0, so `resultsSum` stays 0 and the guard stays live.
    require gLegacyPayout[legacyId][0] == 0 && gLegacyPayout[legacyId][1] == 1;

    NegRiskModule.EventId ev = eventOfCond(cid);
    require to_mathint(conditionsResolvedOf(ev)) + 1 == to_mathint(conditionCount(ev));
    require resultLen(condAt(ev, conditionCount(ev))) != 0;

    redeemIfResolvedDuringMigrateReal@withrevert(e, cid, legacyId);

    satisfy lastReverted; // the all-NO completion guard actually fires
}

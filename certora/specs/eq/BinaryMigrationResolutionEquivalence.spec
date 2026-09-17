// ============================================================
// Binary-Solvency02 verifies the OVER-APPROXIMATING harness, which replaces two production hooks:
//
//   #4  _finalizeMigrationResolution
//         real  : stores [p0*D/(p0+p1), D - p0*D/(p0+p1)]  (the legacy-payout division)
//         model : ignores the input and stores [r0, D-r0] with r0 nondet-pinned to {0, D}
//                 (the two endpoints of the [0, D] interval the real result lives in)
//
//   #5  _redeemIfResolvedDuringMigrate
//         real  : reads legacy payouts; if denominator == 0 return false; else on a fresh
//                 condition store the division result (#4) then redeem the legacy positions; true
//         model : if !nondetResolved return false; else on a fresh condition store the {0,D}-pinned
//                 result (#4 model); true  — i.e. it drops the legacy payout read / division /
//                 `_redeemLegacyPositions` plumbing but keeps the resolution store
//
// This spec runs the real production body and the harness model, and proves:
//
//   #4a realStoreIsNormalizedBinaryInRange — the real store is exactly the documented division and
//       always lands in [0, D] with the pair summing to D.
//   #4-model modelStoreIsBinaryEndpoint    — the harness model store lands on an endpoint {0, D}.
//   #4b endpointDominatesInterval          — the solvency liability sYes*r0 + sNo*(D-r0) is linear
//       in r0, so its max over [0, D] is attained at an endpoint; proving the bound at the two
//       model endpoints {0, D} therefore proves it at the real interior r0. 
//   #5a realResolvedIffDenominator         — the real redeem returns resolved iff the legacy payout
//       denominator != 0, so the model's free `_nondetResolved` boolean over-approximates it.
//   #5b realStoreOnlyOnFreshResolved       — the real store fires only on a fresh, resolved
//       condition and never rewrites an already-resolved one, matching the model's store-set.
//
// Residual assumption:  the plumbing the #5 model drops — `_redeemLegacyPositions` (legacy CTF redeem) 
// and the later `_settleLegacyCollateralToVault` — only ever move legacy collateral into the vault 
// (increasing backing) and never mint/burn V2 PositionManager supply nor decrease module assets. 
// Eliding it is therefore conservative for the `assets >= pUSD + L` bound. In the solvency scene those 
// calls are NONDET-summarized, so this is an inherent scene assumption rather than a code-equivalence claim.
// ============================================================

import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";

using BinaryMigrationRealHarness as RealBin;
using BinaryModuleHarness as ModelBin;

methods {
    // ---- REAL production body under test ----
    function RealBin.redeemIfResolvedDuringMigrateReal(BinaryModule.ConditionId, bytes32) external returns (bool);
    function RealBin.finalizeMigrationResolutionReal(BinaryModule.ConditionId, uint256[]) external;
    function RealBin.resultLen(BinaryModule.ConditionId) external returns (uint256) envfree;
    function RealBin.realR0(BinaryModule.ConditionId) external returns (uint256) envfree;
    function RealBin.realR1(BinaryModule.ConditionId) external returns (uint256) envfree;

    // ---- MODEL (the harness over-approximation under certification) ----
    function ModelBin.finalizeMigrationResolutionModel(BinaryModule.ConditionId) external;
    function ModelBin.resultLen(BinaryModule.ConditionId) external returns (uint256) envfree;
    function ModelBin.realR0(BinaryModule.ConditionId) external returns (uint256) envfree;
    function ModelBin.realR1(BinaryModule.ConditionId) external returns (uint256) envfree;

    // ---- legacy CTF externals ----
    // Payout numerators: routed to a ghost so both index reads (0 and 1) are consistent and the
    // rules can name the exact (p0, p1) the real division reads.
    function _.payoutNumerators(bytes32 cid, uint256 ix) external => legacyPayoutCVL(cid, ix) expect uint256;
    // Legacy redeem only touches legacy-side state — the dropped plumbing (see RESIDUAL ASSUMPTION).
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;
    // CTFHelpers.partition() builds [1,2] in raw assembly; summarize to a clean array (PTA safety).
    function CTFHelpers.partition() internal returns (uint256[] memory) => partitionCVL();

    // The MODEL's nondet payout numerator (harness pins it to {0, D}); free here so the model store
    // ranges over both endpoints.
    function _._nondetPayoutNumerator() internal => NONDET;

    // CTHelpers keccak/assembly ID derivation (reached from the migrate loop analysed during scene
    // build). NONDET to keep the points-to analysis from choking on the raw assembly.
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;

    // OwnableRoles keccak-slot taming (see OwnableRoles.spec). No rule path uses roles; this only
    // stops the role-bitmap assembly from failing the points-to / hashing analysis at scene build.
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal =>
        updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

/*--------------------------------------------------------------
                    GHOSTS / CVL HELPERS
--------------------------------------------------------------*/

definition DENOM() returns mathint = 1000000; // RESULT_DENOMINATOR (BaseModule)

// Legacy payout numerators, keyed by (legacy conditionId, outcome index). Arbitrary uint256 values
// (the CTF's real payoutNumerators are unconstrained here — the range claim holds for all of them).
ghost mapping(bytes32 => mapping(uint256 => uint256)) gLegacyPayout;

function legacyPayoutCVL(bytes32 cid, uint256 ix) returns uint256 {
    return gLegacyPayout[cid][ix];
}

// CTFHelpers.partition() always returns the fixed binary partition [0b01, 0b10].
function partitionCVL() returns uint256[] {
    uint256[] result;
    require result.length == 2, "partition() always returns a 2-element array";
    require result[0] == 1, "partition()[0] is the YES index set 0b01";
    require result[1] == 2, "partition()[1] is the NO index set 0b10";
    return result;
}

/*--------------------------------------------------------------
   #4a — REAL finalize store is the division result, within [0, D]
--------------------------------------------------------------*/

/// @title The REAL migration store equals the documented legacy division and lands in [0, D].
/// @dev Runs the production `_redeemIfResolved` -> `_finalizeMigrationResolution` ->
///      `_storeResult`. On a fresh, resolved, unpaused, the stored [r0, r1] satisfies 
//       r0 == p0*D/(p0+p1), r0 in [0, D], and r0 + r1 == D — exactly the interval whose endpoints 
//       {0, D} the #4 model enumerates.
rule realStoreIsNormalizedBinaryInRange(env e, BinaryModule.ConditionId c, bytes32 lc) {
    require RealBin.resultLen(c) == 0; // fresh: exercise the division store path

    mathint p0 = to_mathint(gLegacyPayout[lc][0]);
    mathint p1 = to_mathint(gLegacyPayout[lc][1]);

    RealBin.redeemIfResolvedDuringMigrateReal(e, c, lc); 

    // Assert only when a result was actually stored (fresh -> resolved).
    if (RealBin.resultLen(c) == 2) {
        mathint r0 = to_mathint(RealBin.realR0(c));
        mathint r1 = to_mathint(RealBin.realR1(c));
        assert p0 + p1 != 0, "a store implies a non-zero legacy payout denominator";
        assert r0 == (p0 * DENOM()) / (p0 + p1), "real r0 equals the documented p0*D/(p0+p1) division";
        assert r0 >= 0 && r0 <= DENOM(), "real migration r0 lands in [0, D]";
        assert r0 + r1 == DENOM(), "real migration result sums to D";
    }
    satisfy RealBin.resultLen(c) == 2;
}

/*--------------------------------------------------------------
   #4-model — the harness MODEL store lands on a binary endpoint
--------------------------------------------------------------*/

/// @title The #4 harness model stores a valid binary result pinned to an endpoint {0, D}.
/// @dev Runs `BinaryModuleHarness._finalizeMigrationResolution` (via the model wrapper) with
///      `_nondetPayoutNumerator` free. The override's `require(r0 == 0 || r0 == D)` restricts the
///      stored r0 to the two endpoints, with r1 = D - r0.
rule modelStoreIsBinaryEndpoint(env e, BinaryModule.ConditionId c) {
    ModelBin.finalizeMigrationResolutionModel(e, c);

    mathint r0 = to_mathint(ModelBin.realR0(c));
    mathint r1 = to_mathint(ModelBin.realR1(c));
    assert ModelBin.resultLen(c) == 2, "model store resolves the condition (length 2)";
    assert r0 == 0 || r0 == DENOM(), "model r0 is a binary endpoint {0, D}";
    assert r0 + r1 == DENOM(), "model result sums to D";
}

/*--------------------------------------------------------------
   #4b — endpoints dominate the interval (pure linearity lemma)
--------------------------------------------------------------*/

/// @title The solvency liability is linear in r0, so proving it at {0, D} proves it on all of [0, D].
/// @dev For non-negative supplies sYes, sNo and any r0 in [0, D]:
///        sYes*r0 + sNo*(D - r0)  <=  max(sYes*D, sNo*D)
///      (= the liability at the model endpoints r0 = D and r0 = 0). Combined with #4a (the real r0
///      lies in [0, D]) this is the complete soundness argument for the #4 endpoint restriction.
rule endpointDominatesInterval(mathint sYes, mathint sNo, mathint r0) {
    require sYes >= 0 && sNo >= 0;
    require r0 >= 0 && r0 <= DENOM();

    mathint interior = sYes * r0 + sNo * (DENOM() - r0);
    mathint atFull = sYes * DENOM(); // r0 = D  (YES certain)
    mathint atZero = sNo * DENOM(); // r0 = 0  (NO certain)

    // `x <= a || x <= b` is exactly `x <= max(a, b)`.
    assert interior <= atFull || interior <= atZero,
        "liability is linear in r0 => dominated by an endpoint of [0, D]";
}

/*--------------------------------------------------------------
   #5a — real resolved-predicate == (legacy denominator != 0)
--------------------------------------------------------------*/

/// @title The REAL migrate redeem returns resolved iff the legacy payout denominator is non-zero.
/// @dev So the model's free `_nondetResolved` boolean soundly over-approximates the real predicate
///      (a free boolean covers any concrete one).
rule realResolvedIffDenominator(env e, BinaryModule.ConditionId c, bytes32 lc) {
    require e.msg.value == 0;
    mathint p0 = to_mathint(gLegacyPayout[lc][0]);
    mathint p1 = to_mathint(gLegacyPayout[lc][1]);

    bool ret = RealBin.redeemIfResolvedDuringMigrateReal@withrevert(e, c, lc);
    bool rev = lastReverted;

    assert !rev => (ret <=> (p0 + p1 != 0)),
        "real returns resolved iff the legacy payout denominator != 0";
}

/*--------------------------------------------------------------
   #5b — real store-set matches the model's (fresh & resolved only)
--------------------------------------------------------------*/

/// @title The REAL store fires only on a fresh, resolved condition and never rewrites a resolved one.
/// @dev Matches the model's store guard (`if result empty: store`). With #5a (model resolved ⊇ real
///      resolved) and #4 (each stored value is endpoint-dominated), the model store-set and its
///      liability over-approximate the real store.
rule realStoreOnlyOnFreshResolved(env e, BinaryModule.ConditionId c, bytes32 lc) {
    require e.msg.value == 0;
    mathint p0 = to_mathint(gLegacyPayout[lc][0]);
    mathint p1 = to_mathint(gLegacyPayout[lc][1]);

    uint256 lenPre = RealBin.resultLen(c);
    uint256 pre0 = RealBin.realR0(c);
    uint256 pre1 = RealBin.realR1(c);

    RealBin.redeemIfResolvedDuringMigrateReal@withrevert(e, c, lc);
    bool rev = lastReverted;

    uint256 lenPost = RealBin.resultLen(c);

    // (i) a store (len 0 -> 2) happens only on a resolved legacy condition.
    assert (!rev && lenPre == 0 && lenPost == 2) => (p0 + p1 != 0),
        "real stores a migration result only when the legacy condition is resolved";
    // (ii) an already-resolved condition is left untouched (idempotent store set).
    assert (!rev && lenPre == 2) => (RealBin.realR0(c) == pre0 && RealBin.realR1(c) == pre1 && lenPost == 2),
        "real leaves an already-resolved condition unchanged";
}

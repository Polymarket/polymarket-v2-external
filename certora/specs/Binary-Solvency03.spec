/* =============================================================================
 * SOLVENCY-03 — For any resolved binary condition c and any amount a: 
 *        getPayout(YES(c), a) + getPayout(NO(c), a) == a
 * ============================================================================= */

/*
 * MODULE
 * @module BinaryModule Global Solvency
 * @contract BinaryModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 *
 * PROPERTIES
 * @property BINARY-SOLVENCY-03 a resolved YES and NO pair redeems for the amount that funded it, up to one unit of floor rounding.
 */


import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using BinaryModuleHarness as BinaryModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- harness pure/view helpers ---- */
    function pidObj(BinaryModule.ConditionId, uint256) external returns (BinaryModule.PositionId) envfree;
    function resultLen(BinaryModule.ConditionId) external returns (uint256) envfree;
    function resultAt(BinaryModule.ConditionId, uint256) external returns (uint256) envfree;

    function BinaryModule.getPayout(BinaryModule.PositionId, uint256) external returns (uint256) envfree;

    /* ---- module identity + immutable wiring. ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    // NONDET: prevent havocing of the collectionId ghost.
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;

    // CollateralToken (pUSD) mint/burn -> collateral-flow ghosts (the LHS/RHS of the bound).
    function _.mint(address, uint256 amount) external => ctMintCVL(amount) expect void;
    function _.burn(uint256 amount) external => ctBurnCVL(amount) expect void;

    // PositionManager ERC1155 position mint/burn -> NONDET.
    function _.mint(address, uint256, uint256) external => NONDET;
    function _.burn(uint256, uint256) external => NONDET;
    function _.batchMint(address, uint256[], uint256[]) external => NONDET;
    function _.batchBurn(uint256[], uint256[]) external => NONDET;

    /* ---- OwnableRoles wiring for the harness (write-side; split/redeem need no role read). ---- */
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// CONDITIONAL_TOKENS linked so its calls resolve; PositionManager/CollateralToken intentionally
// NOT linked to preserve the external mint/burn ghost summaries.
links {
    BinaryModule.CONDITIONAL_TOKENS => ConditionalTokens;
}

definition DENOM() returns mathint = 1000000;

// Ownership-handover methods are excluded from the invariant's preservation
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:BinaryModule.requestOwnershipHandover().selector
    || f.selector == sig:BinaryModule.cancelOwnershipHandover().selector
    || f.selector == sig:BinaryModule.completeOwnershipHandover(address).selector
    // not a production entry point
    || f.selector == sig:BinaryModule.finalizeMigrationResolutionModel(BinaryModule.ConditionId).selector;

/* -----------------------------------------------------------------------------
 * Collateral-flow ghosts (the two sides of the conservation bound)
 * --------------------------------------------------------------------------- */

// Collateral burned INTO the module (split funds the position pair).
ghost mathint gFunded {
    init_state axiom gFunded == 0;
}
// Collateral minted OUT of the module (redeem pays a leg's holder).
ghost mathint gRecovered {
    init_state axiom gRecovered == 0;
}

function ctBurnCVL(uint256 amount) {
    gFunded = gFunded + to_mathint(amount);
}

function ctMintCVL(uint256 amount) {
    gRecovered = gRecovered + to_mathint(amount);
}

/* =============================================================================
 * SUPPORTING INVARIANT — stored resolution is normalized (proven locally).
 * ============================================================================= */

/**
 * @ignore
 */
strong invariant resolvedMeansNormalized(BinaryModule.ConditionId c)
    resultLen(c) == 2 => resultAt(c, 0) + resultAt(c, 1) == DENOM()
    filtered { f -> !OUT_OF_SCOPE(f) }


/* =============================================================================
 * LAYER 1 — PER-CALL getPayout ARITHMETIC LEMMA
 * ============================================================================= */

/**
 * @title redemption never overpays
 * @description A YES and NO pair never redeems for more than the collateral that funded it.
 * @link_property BINARY-SOLVENCY-03
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0a95c064874442ecb343896b55fb9a62?anonymousKey=f11f615ca33ca2b630e8c1a5cf859c43ffeb1622
 */
rule redemptionDoesNotOverpay(BinaryModule.ConditionId c, uint256 amount) {
    requireInvariant resolvedMeansNormalized(c);

    mathint payoutYes = to_mathint(BinaryModule.getPayout(pidObj(c, 0), amount));
    mathint payoutNo = to_mathint(BinaryModule.getPayout(pidObj(c, 1), amount));

    assert payoutYes + payoutNo <= to_mathint(amount);
}

/**
 * @title redemption loses at most one unit
 * @description Floor rounding drops at most one unit of collateral from a redeemed pair.
 * @link_property BINARY-SOLVENCY-03
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0a95c064874442ecb343896b55fb9a62?anonymousKey=f11f615ca33ca2b630e8c1a5cf859c43ffeb1622
 */
rule redemptionLosesAtMostOneUnit(BinaryModule.ConditionId c, uint256 amount) {
    requireInvariant resolvedMeansNormalized(c);

    mathint payoutYes = to_mathint(BinaryModule.getPayout(pidObj(c, 0), amount));
    mathint payoutNo = to_mathint(BinaryModule.getPayout(pidObj(c, 1), amount));

    assert payoutYes + payoutNo >= to_mathint(amount) - 1;
}

/**
 * @title redemption is exact when divisible
 * @description When the YES leg divides evenly, redeeming the pair returns exactly the funding amount.
 * @link_property BINARY-SOLVENCY-03
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0a95c064874442ecb343896b55fb9a62?anonymousKey=f11f615ca33ca2b630e8c1a5cf859c43ffeb1622
 */
rule redemptionIsExactWhenDivisible(BinaryModule.ConditionId c, uint256 amount) {
    mathint r0 = to_mathint(resultAt(c, 0));
    requireInvariant resolvedMeansNormalized(c);

    // No remainder on the YES leg => neither floor drops a unit (rem0 == rem1 == 0).
    require (to_mathint(amount) * r0) % DENOM() == 0, "YES leg divides evenly (no rounding)";

    mathint payoutYes = to_mathint(BinaryModule.getPayout(pidObj(c, 0), amount));
    mathint payoutNo = to_mathint(BinaryModule.getPayout(pidObj(c, 1), amount));

    assert payoutYes + payoutNo == to_mathint(amount);
}

/* =============================================================================
 * Lemma End to End 
 * ============================================================================= */

/**
 * @title split, resolve and redeem end to end
 * @description Splitting collateral, reporting an arbitrary valid resolution, then redeeming both legs returns the funding amount up to one unit.
 * @link_property BINARY-SOLVENCY-03
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0a95c064874442ecb343896b55fb9a62?anonymousKey=f11f615ca33ca2b630e8c1a5cf859c43ffeb1622
 */
rule endToEndSplitResolveRedeem(BinaryModule.ConditionId c, uint256 a, uint256 r0, uint256 r1,env e) {
    
    require gFunded == 0 && gRecovered == 0, "Sastisfying start";
    require resultLen(c) == 0, "condition is unresolved before the split";

    address[] to;
    address userYes;
    address userNo;
    uint256[] payout;

    // Native (non-migration) path: a bridge reporting a non-migration condition calls `_storeResult` directly.
    // `_isMigrationCondition(c)` reads the condition's reserved bits, require it to be false so we exercise
    // the native (non-legacy) resolution path.
    require !BinaryModule.isMigration(e, c);

    env eFunder;
    // 1. Fund: split `a` collateral into `a` YES + `a` NO. Burns `a` collateral => gFunded == a.
    split(eFunder, to, c, a);

    env eReport;
    // 2. Resolve: reportResult([r0, r1]) stores the random valid payout. 
    reportResult(eReport, c, payout);

    // make sure condition c is resolved
    assert resultLen(c) == 2;

    env envYes;
    env envNo;
    // 3. + 4. Redeem each leg for the full `a` minted on split. Each mints getPayout(leg, a)
    //          collateral => gRecovered == payoutYes + payoutNo == floor(a*r0/D) + floor(a*r1/D).
    redeem(envYes, userYes, pidObj(c, 0), a);
    redeem(envNo, userNo, pidObj(c, 1), a);

    // UPPER (solvency): the user never recovers more collateral than they funded.
    assert gRecovered <= gFunded, "redeem of YES+NO never exceeds the split funding";
    // LOWER (tightness): floor rounding across the two legs costs at most one unit.
    assert gRecovered >= gFunded - 1, "redeem of YES+NO recovers at least funding - 1";
}

/* =============================================================================
 * Lemma End to End (multi-op): split -> split -> merge -> reportResult([r0,r1]) -> redeem x2
 * ============================================================================= */
/**
 * @title split, merge, resolve and redeem end to end
 * @description A sequence of splits and merges followed by resolution and redemption still returns no more than the collateral committed.
 * @link_property BINARY-SOLVENCY-03
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0a95c064874442ecb343896b55fb9a62?anonymousKey=f11f615ca33ca2b630e8c1a5cf859c43ffeb1622
 */
rule endToEndMultiOperationSplitMergeResolveRedeem(
    BinaryModule.ConditionId c, uint256 a1, uint256 a2, uint256 m, uint256 r0, uint256 r1, env e
) {
    require gFunded == 0 && gRecovered == 0, "clean collateral-flow start";
    require resultLen(c) == 0, "condition is unresolved before the ops";

    mathint net = to_mathint(a1) + to_mathint(a2) - to_mathint(m);

    // Native (non-migration) resolution path, mirrors endToEndSplitResolveRedeem.
    require !BinaryModule.isMigration(e, c);

    address[] to1;
    address[] to2;
    address userMerge;
    address userYes;
    address userNo;
    uint256[] payout;

    uint256 netRedeem = require_uint256(net);

    // 1. + 2. Two funding splits on c. Each burns its `_amount` collateral => gFunded == a1 + a2.
    env e1;
    split(e1, to1, c, a1);
    env e2;
    split(e2, to2, c, a2);

    // 3. Merge `m` back at par: burns m of each leg, mints m collateral => gRecovered += m.
    env eM;
    merge(eM, userMerge, c, m);

    // 4. Resolve: reportResult([r0, r1]) stores the random valid payout.
    env eR;
    reportResult(eR, c, payout);

    assert resultLen(c) == 2;

    // 5. + 6. Redeem the net minted amount of each leg. Each mints getPayout(leg, net) collateral.
    env eY;
    redeem(eY, userYes, pidObj(c, 0), netRedeem);
    env eN;
    redeem(eN, userNo, pidObj(c, 1), netRedeem);

    // UPPER (solvency): total collateral out never exceeds total collateral in, across two splits + a merge + two redeems.
    assert gRecovered <= gFunded, "multi-op redeem never exceeds total funding";
    // LOWER (tightness): the merge is exact (par); only the final redeem pair floors, so the whole sequence loses at most one unit.
    assert gRecovered >= gFunded - 1, "multi-op recovers at least total funding - 1";
}

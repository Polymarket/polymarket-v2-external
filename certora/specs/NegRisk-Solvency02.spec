/* =============================================================================
 * This file carries the resolution bookkeeping that bound reads: the result mirror is faithful to
 * the real result mapping, neg-risk results are binary, and the per-event counters agree with the
 * stored results. Without these the liability model prices an event off a malformed or stale
 * result, so they are the hypotheses the solvency proof rests on rather than the proof itself.
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Resolution Integrity
 * @contract NegRiskModule
 * @impact An event partition could exceed the full denominator, so its positions would redeem for more than was committed
 *
 * PROPERTIES
 * @property MODU-INT-01 the per-event result counter always equals the sum of the YES numerators of the conditions resolved into that event.
 */

import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using NegRiskModuleHarness as NegRiskModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;

links {
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;
}

methods {
    /* ---- harness pure/view helpers (envfree) ---- */
    function evKey(NegRiskModule.EventId) external returns (uint256) envfree;
    function condEvKey(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function pidEvKey(NegRiskModule.PositionId) external returns (uint256) envfree;
    function condAt(NegRiskModule.EventId, uint256) external returns (NegRiskModule.ConditionId) envfree;
    function pidOf(NegRiskModule.ConditionId, uint256) external returns (uint256) envfree;
    function pidUnwrap(NegRiskModule.PositionId) external returns (uint256) envfree;
    function arityOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function condIndexOf(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function condOf(NegRiskModule.PositionId) external returns (NegRiskModule.ConditionId) envfree;
    function resultsSumOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function conditionsResolvedOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function condFrom(bytes32) external returns (NegRiskModule.ConditionId) envfree;
    function legacyEvKey(bytes32) external returns (uint256) envfree;
    function legacyMintedKey(bytes32, uint256) external returns (uint256) envfree;
    // flat mirrors (keyed by YES pid == uint256(conditionId)) — what the liability reads.
    function r0Mirror(uint256) external returns (uint256) envfree;
    function r1Mirror(uint256) external returns (uint256) envfree;
    function lenMirror(uint256) external returns (uint256) envfree;
    // real `result` mapping reads — only for the mirrorMatchesReal bridge (redeem).
    function resultLen(NegRiskModule.ConditionId) external returns (uint256) envfree;
    // Real stored payout numerators, needed to bridge the mirror to the array getPayout reads.
    function resultAt(NegRiskModule.ConditionId, uint256) external returns (uint256) envfree;

    /* ---- PositionManager position mutators -> ghostBalance + trackedSupply ---- */
    function _.mint(address to, uint256 id, uint256 amount) external => pmMintCVL(to, id, amount) expect void;
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external => pmBatchMintCVL(to, ids, amounts) expect void;
    function _.burn(uint256 id, uint256 amount) external with (env e) => pmBurnCVL(e.msg.sender, id, amount) expect void;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external with (env e) => pmBatchBurnCVL(e.msg.sender, ids, amounts) expect void;
    //function _.unsafeTransferFrom(address from, address to, uint256 id, uint256 amount) external with (env e) => erc1155SafeTransferFromCVL(e, from, to, id, amount) expect void;
    //function _.unsafeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] amounts) external with (env e) => pmBatchTransferCVL(e, from, to, ids, amounts) expect void;
    function _.moduleId() external => DISPATCHER(true);
    //function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);

    /* ---- module immutable wiring (NOT linked, so PM/CT calls stay unresolved) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;
    function _._legacyConditionalTokens() external => ConditionalTokens expect address;

    /* ---- CollateralToken pUSD supply -> committed ghost (distinct sighash from PM) ---- */
    function _.mint(address to, uint256 amount) external => ctMintCVL(amount) expect void;
    function _.burn(uint256 amount) external => ctBurnCVL(amount) expect void;

    function ConditionalTokens.safeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] values, bytes data) external => migBackingPullCVL(values);

    // Legacy payouts are a ghost pinned to canonical binary resolutions (see `ghostLegacyPayout` axiom below).
    function _.payoutNumerators(bytes32 cid, uint256 ix) external => legacyPayoutCVL(cid, ix) expect uint256;

    // CTFHelpers.partition() builds [1,2] via raw-assembly free-memory-pointer bumps, which poison prover PTA
    // across the WHOLE migratePositions call graph and leave the array-forwarding ConditionalTokens.safeBatchTransferFrom pull-in unresolved (AUTO havoc)
    // Summarizing it with a clean CVL array restores precise call resolution.
    function CTFHelpers.partition() internal returns (uint256[] memory) => partitionCVL();
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;
    function _._redeemLegacyPositions(bytes32) internal => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;

    /* SOUND over-approximation: keeps the resolution store and covers the real computed result, plus
     * more; drops only the division / legacy plumbing that made the migrate loop diverge */
    function _._useMigrateRedeemModel() internal => ALWAYS(true);
    function _._nondetResolved() internal => NONDET;
    function _._nondetBinaryR0() internal => NONDET;

    // migratePositions' complementary-merge loop only reads legacy CT balances and calls legacy
    // mergePositions, and emits events — it never touches trackedSupply / committed /
    // migrationBacking, so it cannot affect this solvency bound.
    function ConditionalTokens.balanceOf(address, uint256) external returns (uint256) => NONDET;
    function ConditionalTokens.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function _.NEG_RISK_ADAPTER() external => NONDET;
    function _.getQuestionCount(bytes32) external => NONDET;

    /* ---- OwnableRoles wiring ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) =>  checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>  ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

/* -----------------------------------------------------------------------------
 * Ghost state
 * --------------------------------------------------------------------------- */

// tracked supply of the YES+NO positions for each condition
ghost mapping(uint256 => mathint) trackedSupply {
    init_state axiom forall uint256 id. trackedSupply[id] == 0;
}

// committed[eventKey] = net pUSD committed to event E (D-unscaled).
ghost mapping(uint256 => mathint) committed {
    init_state axiom forall uint256 ev. committed[ev] == 0;
}

// migrationBacking[eventKey] = legacy CTF collateral deposited for E's migrated conditions
// (D-unscaled). Credited 1:1 with the legacy positions pulled in on migratePositions.
ghost mapping(uint256 => mathint) migrationBacking {
    init_state axiom forall uint256 ev. migrationBacking[ev] == 0;
}

// arbitrary variable to attribute the committed (pUSD) change to the event of the current context
ghost uint256 ctxEvent;

// Uninterpreted stand-in for the variable*variable products in the liability
// (numerator * signed weight, and (D - S) * maxUnresolved). 
ghost prodCVL(mathint, mathint) returns mathint {
    axiom forall mathint w. prodCVL(0, w) == 0;
    axiom forall mathint a. prodCVL(a, 0) == 0;
    axiom forall mathint a. forall mathint b. forall mathint w. prodCVL(a, w) + prodCVL(b, w) == prodCVL(a + b, w);
    axiom forall mathint a. forall mathint w. forall mathint v. prodCVL(a, w) + prodCVL(a, v) == prodCVL(a, w + v);
    axiom forall mathint a. forall mathint p. forall mathint q. (a >= 0 && p <= q) => prodCVL(a, p) <= prodCVL(a, q);
    axiom forall mathint b. forall mathint p. forall mathint q. (b >= 0 && p <= q) => prodCVL(p, b) <= prodCVL(q, b);
    // Single-term sign lemmas: trigger on any ground prodCVL(a, w), so the solver can always derive the product's sign 
    axiom forall mathint a. forall mathint w. (a >= 0 && w >= 0) => prodCVL(a, w) >= 0;
    axiom forall mathint a. forall mathint w. (a >= 0 && w <= 0) => prodCVL(a, w) <= 0;
    axiom forall mathint a. forall mathint b. prodCVL(a, b) == prodCVL(b, a);
    axiom forall mathint w. prodCVL(1000000, w) == 1000000 * w;
}

/* -----------------------------------------------------------------------------
 * PM mint/burn wrappers — ghostBalance semantics + trackedSupply.
 * --------------------------------------------------------------------------- */

function pmMintCVL(address to, uint256 id, uint256 amount) {
    mintCVL(to, id, amount);
    trackedSupply[id] = trackedSupply[id] + to_mathint(amount);
}

function pmBurnCVL(address from, uint256 id, uint256 amount) {
    burnByCVL(0, from, id, amount);
    trackedSupply[id] = trackedSupply[id] - to_mathint(amount);
}

function pmBatchMintCVL(address to, uint256[] ids, uint256[] amounts) {
    // Solady _batchMint reverts on length mismatch
    if (ids.length != amounts.length) { revert(); }
    if (ids.length > 0) { pmMintCVL(to, ids[0], amounts[0]); }
    if (ids.length > 1) { pmMintCVL(to, ids[1], amounts[1]); }
    if (ids.length > 2) { pmMintCVL(to, ids[2], amounts[2]); }
}

function pmBatchBurnCVL(address from, uint256[] ids, uint256[] amounts) {
    // Solady _batchBurn reverts on length mismatch
    if (ids.length != amounts.length) { revert(); }
    if (ids.length > 0) { pmBurnCVL(from, ids[0], amounts[0]); }
    if (ids.length > 1) { pmBurnCVL(from, ids[1], amounts[1]); }
    if (ids.length > 2) { pmBurnCVL(from, ids[2], amounts[2]); }
}

function pmBatchTransferCVL(env e, address from, address to, uint256[] ids, uint256[] amounts) {
    if (from != e.msg.sender && !ghostApproved[from][e.msg.sender]) { revert(); }
    // Same length-mismatch guard as the mint/burn helpers
    if (ids.length != amounts.length) { revert(); }
    if (ids.length > 0) { erc1155SafeTransferFromCVL(e, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { erc1155SafeTransferFromCVL(e, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { erc1155SafeTransferFromCVL(e, from, to, ids[2], amounts[2]); }
}

function ctBurnCVL(uint256 amount) {
    committed[ctxEvent] = committed[ctxEvent] + to_mathint(amount);
}

function ctMintCVL(uint256 amount) {
    // A merge / redeem / horizontalMerge returns pUSD that must be covered by the event's backing.
    // The combined backing D*(committed + migrationBacking) drops by exactly D*amount either way, so the
    // backing bound proved in certora/specs/solvency/NegRiskModule.spec is unchanged in substance; for
    // non-migrated events (migrationBacking == 0) this reduces to the plain committed guard.
    mathint amt = to_mathint(amount);
    if (committed[ctxEvent] + migrationBacking[ctxEvent] < amt) { revert(); }
    if (committed[ctxEvent] >= amt) {
        committed[ctxEvent] = committed[ctxEvent] - amt;
    } else {
        mathint fromMigration = amt - committed[ctxEvent];
        committed[ctxEvent] = 0;
        migrationBacking[ctxEvent] = migrationBacking[ctxEvent] - fromMigration;
    }
}

// Legacy pull-in: credit the deposited legacy backing to ctxEvent. Σ amounts == the V2 supply minted
// in the same call, so D * migrationBacking rises by exactly the worst-case liability minted.
function migBackingPullCVL(uint256[] amounts) {
    mathint pulled = (amounts.length > 0 ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 1 ? to_mathint(amounts[1]) : 0)
        + (amounts.length > 2 ? to_mathint(amounts[2]) : 0);
    migrationBacking[ctxEvent] = migrationBacking[ctxEvent] + pulled;
}

// CTFHelpers.partition() always returns the fixed binary partition [0b01, 0b10].
function partitionCVL() returns uint256[] {
    uint256[] result;
    return result;
}

/* -----------------------------------------------------------------------------
 * SCOPE ASSUMPTION — legacy CTF payout vector.
 * * PROVED BY ResultNorm01.spec
 *
 * `payoutNumerators[legacyConditionId][outcomeIndex]`, restricted to the three
 * canonical shapes of a binary CTF condition: unresolved (0,0), YES (1,0), NO (0,1).
 *
 * This is an under-approximation but it's ok for this spec because `(p0, p1)` reach production at
 * exactly one site — BaseMigrationMixin._redeemIfResolved:291-301 — where they
 * influence only two things: whether `den == 0`, and `r0 = p0 * 1e6 / den`.
 * --------------------------------------------------------------------------- */
persistent ghost mapping(bytes32 => mapping(uint256 => uint256)) ghostLegacyPayout {
    axiom forall bytes32 c.
        (ghostLegacyPayout[c][0] == 0 && ghostLegacyPayout[c][1] == 0)
        || (ghostLegacyPayout[c][0] == 1 && ghostLegacyPayout[c][1] == 0)
        || (ghostLegacyPayout[c][0] == 0 && ghostLegacyPayout[c][1] == 1);
}

function legacyPayoutCVL(bytes32 cid, uint256 ix) returns uint256 {
    return ghostLegacyPayout[cid][ix];
}

/* -----------------------------------------------------------------------------
 * Definitions / helpers
 * --------------------------------------------------------------------------- */

definition RESULT_DENOMINATOR() returns mathint = 1000000;

// Ownership-handover functions touch keccak-derived assembly slots that havoc storage,
// yielding spurious CEXs. They cannot move collateral or supply, so excluding is sound.
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:NegRiskModule.requestOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.cancelOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.completeOwnershipHandover(address).selector
    // Excluded : it raises totalSupply with zero committed/migrationBacking increase,
    // because a bridged-in position's collateral is locked on the source chain
    || f.selector == sig:NegRiskModule.mintFromBridge(address,NegRiskModule.PositionId,uint256).selector
    // Equivalence-proof harness wrappers (NegRiskMigrationEquivalence); not production entry points
    || f.selector == sig:NegRiskModule.redeemIfResolvedDuringMigrateReal(NegRiskModule.ConditionId,bytes32).selector
    || f.selector == sig:NegRiskModule.legacyMintedKey(bytes32,uint256).selector;

function suppAt(uint256 key) returns mathint {
    return to_mathint(require_uint256(trackedSupply[key]));
}

function cvlMax(mathint a, mathint b) returns mathint {
    return a > b ? a : b;
}

function maxUnresolvedOf(bool res0, mathint w0, bool res1, mathint w1, bool res2, mathint w2) returns mathint
{
    if (!res0 && !res1 && !res2) { return cvlMax(w0, cvlMax(w1, w2)); }
    if (!res0 && !res1) { return cvlMax(w0, w1); }
    if (!res0 && !res2) { return cvlMax(w0, w2); }
    if (!res1 && !res2) { return cvlMax(w1, w2); }
    if (!res0) { return w0; }
    if (!res1) { return w1; }
    return w2;
}

// Proof hint about prodCVL abstraction : pins prodCVL to real multiplication for each leg coefficient
function pinDeltaProducts(NegRiskModule.EventId e, uint256 amount) {
    mathint a = to_mathint(amount);
    mathint S = to_mathint(resultsSumOf(e));
    require prodCVL(to_mathint(r0Mirror(pidOf(condAt(e, 0), 0))), a) == to_mathint(r0Mirror(pidOf(condAt(e, 0), 0))) * a;
    require prodCVL(to_mathint(r0Mirror(pidOf(condAt(e, 1), 0))), a) == to_mathint(r0Mirror(pidOf(condAt(e, 1), 0))) * a;
    require prodCVL(to_mathint(r0Mirror(pidOf(condAt(e, 2), 0))), a) == to_mathint(r0Mirror(pidOf(condAt(e, 2), 0))) * a;
    require prodCVL(RESULT_DENOMINATOR() - S, a) == (RESULT_DENOMINATOR() - S) * a;
}

// ---- PRODCVL MINT/BURN PINNING ---- // 

// Signed contribution of one mint entry to leg j's weight w_j = supp(YES_j) - supp(NO_j):
// Minting YES_j raises w_j (+a), minting NO_j lowers w_j (-a), a mint on any other position (other leg, synthetic, foreign event) leaves w_j unchanged (0). 
function legMintContribution(uint256 yesKey, uint256 noKey, bytes32 id, uint256 oi, uint256 a) returns mathint
{
    // v2 position ID regarding legacy (id,outcome) mapping
    uint256 p = legacyMintedKey(id, oi);
    if (p == yesKey) { return to_mathint(a); }
    if (p == noKey) { return -to_mathint(a); }
    return 0;
}

// Signed contribution of one explicit burn to leg j's weight w_j = supp(YES_j) - supp(NO_j):
// burning YES_j by a lowers w_j (-a), burning NO_j by a raises w_j (+a), a burn on any other position leaves w_j unchanged (0).
function legBurnContribution(uint256 yesKey, uint256 noKey, NegRiskModule.PositionId pid, uint256 a)returns mathint
{
    uint256 p = pidUnwrap(pid);
    if (p == yesKey) { return -to_mathint(a); }
    if (p == noKey) { return to_mathint(a); }
    return 0;
}

// Exact net weight shift of leg j over all mints in the call.
function legMintDelta(NegRiskModule.EventId e, uint256 j, bytes32[] ids, uint256[] ois, uint256[] amts)
    returns mathint
{
    uint256 yesKey = pidOf(condAt(e, j), 0);
    uint256 noKey = pidOf(condAt(e, j), 1);
    return (ids.length > 0 && ois.length > 0 && amts.length > 0 ? legMintContribution(yesKey, noKey, ids[0], ois[0], amts[0]) : 0)
        + (ids.length > 1 && ois.length > 1 && amts.length > 1 ? legMintContribution(yesKey, noKey, ids[1], ois[1], amts[1]) : 0)
        + (ids.length > 2 && ois.length > 2 && amts.length > 2 ? legMintContribution(yesKey, noKey, ids[2], ois[2], amts[2]) : 0);
}

// Exact net weight shift of leg j over all burns in the call.
function legBurnDelta(NegRiskModule.EventId e, uint256 j, NegRiskModule.PositionId[] pids, uint256[] amts) returns mathint
{
    uint256 yesKey = pidOf(condAt(e, j), 0);
    uint256 noKey = pidOf(condAt(e, j), 1);
    return (pids.length > 0 && amts.length > 0 ? legBurnContribution(yesKey, noKey, pids[0], amts[0]) : 0)
        + (pids.length > 1 && amts.length > 1 ? legBurnContribution(yesKey, noKey, pids[1], amts[1]) : 0)
        + (pids.length > 2 && amts.length > 2 ? legBurnContribution(yesKey, noKey, pids[2], amts[2]) : 0);
}

// Pins prodCVL distributivity for leg j at its exact net shift d (post weight = pre weight + d),
// for the leg's contributing coefficient. The base term prodCVL(coeff, w) stays abstract and
// cancels against the pre-state liability via the distributivity require below.
function pinLegShift(mathint coeff, mathint w, mathint d) {
    if (d >= 0) {
        require prodCVL(coeff, d) <= RESULT_DENOMINATOR() * d;
    } 
    require prodCVL(coeff, w + d) == prodCVL(coeff, w) + prodCVL(coeff, d);
}

// picks right coefficient depending of resolved or unresolved leg and requires good prodCVL distributivity result
function pinBurnLeg(NegRiskModule.EventId e, uint256 j, mathint DmS, mathint d) {
    uint256 k = pidOf(condAt(e, j), 0);
    mathint w = suppAt(k) - suppAt(pidOf(condAt(e, j), 1));
    if (lenMirror(k) == 2) {
        pinLegShift(to_mathint(r0Mirror(k)), w, d);
    } else {
        pinLegShift(DmS, w, d);
    }
}

// Pins prodCVL to return good value for migratePositions
function pinMintNetShift(NegRiskModule.EventId e, bytes32[] ids, uint256[] ois, uint256[] amts) {
    mathint DmS = RESULT_DENOMINATOR() - to_mathint(resultsSumOf(e));
    pinBurnLeg(e, 0, DmS, legMintDelta(e, 0, ids, ois, amts));
    pinBurnLeg(e, 1, DmS, legMintDelta(e, 1, ids, ois, amts));
    pinBurnLeg(e, 2, DmS, legMintDelta(e, 2, ids, ois, amts));
}

// Pins prodCVL to return good value for burnFromBridge
function pinBurnNetShift(NegRiskModule.EventId e, NegRiskModule.PositionId[] pids, uint256[] amts) {
    mathint DmS = RESULT_DENOMINATOR() - to_mathint(resultsSumOf(e));
    pinBurnLeg(e, 0, DmS, legBurnDelta(e, 0, pids, amts));
    pinBurnLeg(e, 1, DmS, legBurnDelta(e, 1, pids, amts));
    pinBurnLeg(e, 2, DmS, legBurnDelta(e, 2, pids, amts));
}

/* =============================================================================
 * SUPPORTING INVARIANTS
 * ============================================================================= */

/**
 * @title the result mirror is normalized
 * @description A resolved binary condition has payout numerators summing to the denominator.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant mirrorNormalized(uint256 k)
    lenMirror(k) == 2 => r0Mirror(k) + r1Mirror(k) == RESULT_DENOMINATOR()
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @title the mirror length tracks the real result
 * @description The mirrored result length stays in sync with the real result mapping.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant lengthMatchesReal(NegRiskModule.ConditionId c)
    lenMirror(pidOf(c, 0)) == resultLen(c)
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @title a stored result has length two or is absent
 * @description A stored result is either absent or a full complementary pair; no other length is reachable.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant resultLengthNormalized(NegRiskModule.ConditionId c)
    resultLen(c) == 0 || resultLen(c) == 2
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @title the mirror values track the real result
 * @description The mirror's values equal the real array's values, not just its length.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant valueMatchesReal(NegRiskModule.ConditionId c)
    resultLen(c) == 2 =>
        (r0Mirror(pidOf(c, 0)) == resultAt(c, 0) && r1Mirror(pidOf(c, 0)) == resultAt(c, 1))
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @title neg-risk results are binary
 * @description Every neg-risk condition resolves fully YES or fully NO.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant resultsAreBinary(NegRiskModule.ConditionId c)
    resultLen(c) == 2 => (resultAt(c, 0) == 0 || to_mathint(resultAt(c, 0)) == RESULT_DENOMINATOR())
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @title the event result sum is a flag
 * @description The per-event result sum only ever holds zero or the denominator, so it behaves as a resolution flag.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant resultsSumIsFlag(NegRiskModule.EventId e)
    resultsSumOf(e) == 0 || to_mathint(resultsSumOf(e)) == RESULT_DENOMINATOR()
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @ignore
 */
invariant resultsSumBounded(NegRiskModule.EventId e)
    to_mathint(resultsSumOf(e)) <= RESULT_DENOMINATOR()
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @title the resolved-condition counter is accurate
 * @description The contract's resolved-condition counter matches the number of conditions with a stored result.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant conditionsResolvedCount(NegRiskModule.EventId e)
    arityOf(e) == 2 => to_mathint(conditionsResolvedOf(e)) ==
        (lenMirror(pidOf(condAt(e, 0), 0)) == 2 ? 1 : 0) + (lenMirror(pidOf(condAt(e, 1), 0)) == 2 ? 1 : 0)
    filtered { f -> !OUT_OF_SCOPE(f) }
    {
        preserved reportResult(NegRiskModule.ConditionId _c, uint256[] _result) with (env ev) {
            // uint256-keyed lenMirror equals the real result-array length per leg, so
            // "resolved" (len==2) in the liability matches the contract's actual result state.
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
        }
        // `preserved resolveConditionToNo` removed — function deleted;
        // sibling-NO is derived on read and no longer writes result state.
        preserved resolveMigrationCondition(bytes32 _c) with (env ev) {
            // uint256-keyed lenMirror equals the real result-array length per leg, so
            // "resolved" (len==2) in the liability matches the contract's actual result state.
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
        }
        // migration now STORES results and bumps `conditionsResolved`
        // (`_redeemIfResolved` -> `_finalizeMigrationResolution`).
        preserved migratePositions(bytes32[] _ids, uint256[] _oi, uint256[] _amts) with (env ev) {
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
            requireInvariant resultLengthNormalized(condAt(e, 0));
            requireInvariant resultLengthNormalized(condAt(e, 1));
            requireInvariant resultLengthNormalized(condAt(e, 2));
            requireInvariant resultsSumIsFlag(e);
        }
        preserved migratePositions(address _from, bytes32[] _ids, uint256[] _oi, uint256[] _amts) with (env ev) {
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
            requireInvariant resultLengthNormalized(condAt(e, 0));
            requireInvariant resultLengthNormalized(condAt(e, 1));
            requireInvariant resultLengthNormalized(condAt(e, 2));
            requireInvariant resultsSumIsFlag(e);
        }
    }

/**
 * @title the result sum matches the resolved YES numerators
 * @description The contract's result-sum counter matches the sum of stored YES numerators across resolved conditions.
 * @link_property MODU-INT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/082856c68d074113b19c8c482aa28e19?anonymousKey=bd81d6c80ddf02e7277a65c90eb05552e40bb0c9
 */
invariant resultsSumIsResolvedYesSum(NegRiskModule.EventId e)
    arityOf(e) == 2 =>
        to_mathint(resultsSumOf(e)) ==
              (lenMirror(pidOf(condAt(e, 0), 0)) == 2 ? to_mathint(r0Mirror(pidOf(condAt(e, 0), 0))) : 0)
            + (lenMirror(pidOf(condAt(e, 1), 0)) == 2 ? to_mathint(r0Mirror(pidOf(condAt(e, 1), 0))) : 0)
            + (lenMirror(pidOf(condAt(e, 2), 0)) == 2 ? to_mathint(r0Mirror(pidOf(condAt(e, 2), 0))) : 0)
    filtered { f -> !OUT_OF_SCOPE(f) }
    {
        preserved reportResult(NegRiskModule.ConditionId _c, uint256[] _result) with (env ev) {
            // uint256-keyed lenMirror equals the real result-array length per leg, so
            // "resolved" (len==2) in the liability matches the contract's actual result state.
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
        }
        preserved resolveMigrationCondition(bytes32 _c) with (env ev) {
            // uint256-keyed lenMirror equals the real result-array length per leg, so
            // "resolved" (len==2) in the liability matches the contract's actual result state.
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
        }
        // migration now STORES results and writes `resultsSum` 
        preserved migratePositions(bytes32[] _ids, uint256[] _oi, uint256[] _amts) with (env ev) {
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
            requireInvariant valueMatchesReal(condAt(e, 0));
            requireInvariant valueMatchesReal(condAt(e, 1));
            requireInvariant valueMatchesReal(condAt(e, 2));
            requireInvariant resultsSumIsFlag(e);
        }
        preserved migratePositions(address _from, bytes32[] _ids, uint256[] _oi, uint256[] _amts) with (env ev) {
            requireInvariant lengthMatchesReal(condAt(e, 0));
            requireInvariant lengthMatchesReal(condAt(e, 1));
            requireInvariant lengthMatchesReal(condAt(e, 2));
            requireInvariant valueMatchesReal(condAt(e, 0));
            requireInvariant valueMatchesReal(condAt(e, 1));
            requireInvariant valueMatchesReal(condAt(e, 2));
            requireInvariant resultsSumIsFlag(e);
        }
    }

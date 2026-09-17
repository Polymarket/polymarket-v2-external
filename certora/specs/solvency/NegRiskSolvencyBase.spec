// Shared code for the NegRiskModule solvency scene
import "../summaries/PositionManager_full_summaries.spec";
import "../summaries/NegRiskModule_solvency_call_resolution.spec";
import "../summaries/NegRiskModule_base_summaries.spec";
import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";
import "../summaries/Solady/SafeTransferLib.spec";
import "../summaries/CTFHelpers_summaries.spec";
import "../summaries/LegacyCTF_migration_summaries.spec";

links {
    NegRiskModule.USDCE => USDCe;
    CollateralToken.USDCE => USDCe;
}

methods {
    // ---- envfree ----
    function CollateralToken.USDC() external returns (address) envfree;
    function CollateralToken.USDCE() external returns (address) envfree;
    function CollateralToken.VAULT() external returns (address) envfree;

    // Approvals answer from the ghost model
    function _.isApprovedForAll(address owner, address operator) internal =>
        isApprovedForAllCVL(owner, operator) expect bool;

    // The `result` mapping is fully abstracted into CVL ghosts. The munge routes every read through getResult
    // and the write through _storeResult; both are summarized below to the ghost.
    function NegRiskModule.condKeyOf(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function NegRiskModule.isMigrationCondition(uint256) external returns (bool) envfree;
    function _.getResult(NegRiskModule.ConditionId cid) internal => getResultCVL(cid) expect uint256[] memory;
    function _._storeResult(NegRiskModule.ConditionId cid, uint256[] memory res) internal =>
        storeResultCVL(cid, res) expect void;

    // Migration-resolution finalize, summarized to a ghost write of a nondet (r0, D − r0)
    // pair. SOUND over-approximation for the >= rule: (a) the real stored pair is always of
    // this exact form (legacyPayout0·D/(p0+p1) <= D, second component D − first), so real
    // behavior is included — and reportResult can store any such pair anyway; (b) the dropped
    // resultsSum/conditionsResolved bookkeeping is read by NnothingOTHING in the model; (c) the
    // dropped requires only WIDEN the surviving path set. 
    function _._finalizeMigrationResolution(NegRiskModule.ConditionId cid, uint256[] memory res) internal =>
        finalizeMigrationResolutionCVL(cid) expect void;

    // ---- PositionManager summaries with liabilities ----
    function PositionManager.mint(address _to, PositionManager.PositionId _positionId, uint256 _amount)
        external with (env e) => liabAwareMint(e, _to, _positionId, _amount);
    function PositionManager.batchMint(address _to, PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external with (env e) => liabAwareBatchMint(e, _to, _positionIds, _amounts);
    function PositionManager.burn(PositionManager.PositionId _positionId, uint256 _amount)
        external with (env e) => liabAwareBurn(e, _positionId, _amount);
    function PositionManager.batchBurn(PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external with (env e) => liabAwareBatchBurn(e, _positionIds, _amounts);
    function PositionManager.unsafeTransferFrom(address from, address to, PositionManager.PositionId id, uint256 amount)
        external with (env e) => transferWithAuthCVL(e, from, to, id, amount);
    function PositionManager.unsafeBatchTransferFrom(
        address from, address to, PositionManager.PositionId[] ids, uint256[] amounts
    ) external with (env e) => batchTransferWithAuthCVL(e, from, to, ids, amounts);
    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);

    // ---- CollateralToken pUSD supply ----
    function CollateralToken.mint(address _to, uint256 _amount) external => pusdMintCVL(_amount);
    function CollateralToken.burn(uint256 _amount) external => pusdBurnCVL(_amount);

    // ---- OwnableRoles ----
    function _.hasAnyRole(address user, uint256 roles) internal =>
        hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal =>
        hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal =>
        rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) =>
        checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal =>
        setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal =>
        updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;

    function _.transfer(address, uint256) external => DISPATCHER(true);
}

// ============================================================
// Solvency accounting for neg-risk 
//
// Headline invariant (same shape as the BinaryModule solvency spec):
//   USDC.bal(VAULT) + USDCe.bal(VAULT) + USDCe.bal(ConditionalTokens)
//     >= pUSD.totalSupply() + Σ_events eventLiability(E)
//
// For an arity=2 event (conditions i in {0,1,2}: two real + synthetic Other), with
// w_i = YES_i − NO_i, resolved conditions contributing fixed r0_i and S = Σ_resolved r0_i:
//   eventLiability(E) = Σ_i NO_i
//                     + ( Σ_resolved r0_i·w_i + (D − S)·max_unresolved w_i ) / D
// (the (D−S)·max term is dropped when all three are resolved, where S = D). The first
// part is the forced NO baseline; the bracketed part is the best (max) the adversary can
// do by allocating the remaining YES budget (D − S) to the single most-valuable
// unresolved condition. For a resolved condition the term is exactly its redeem payout.
// ============================================================

// Mirrors pUSD.totalSupply (real supply is not read; mint/burn are summarized).
ghost mathint ghostPusdSupply;

// liabilityScaled = Σ_events eventScaled(E) = D · Σ_events eventLiability(E).
ghost mathint liabilityScaled;

// RESULT_DENOMINATOR: results are numerators out of 1e6.
definition RESULT_DENOMINATOR() returns mathint = 1000000;

// Sentinel strictly below any real w_i = y_i - n_i. supplyOverride pins y_i, n_i to
// [0, 2^256) (require_uint256), so w_i >= -(2^256 - 1) > NEG_INF. Masking resolved
// conditions to NEG_INF turns "max over UNRESOLVED w_i" into a single branch-free max
// chain, removing the control-flow case split on the resolved-combination.
definition NEG_INF() returns mathint = -(2 ^ 257);

// Module id = top 8 bits; arity = bits [104,120); event base = bottom 24 bits (conditionIndex
// + outcome) cleared. Division/modulo (not shifts) keep the prover in integer reasoning.
definition arityOf(uint256 positionId) returns mathint = (positionId / 2 ^ 104) % (2 ^ 16);
definition conditionIndexOf(uint256 positionId) returns mathint = (positionId / 2 ^ 8) % (2 ^ 16);
definition eventBaseOf(uint256 positionId) returns mathint = (positionId / 2 ^ 24) * 2 ^ 24;

// pUSD minted (merge/redeem): supply up. pUSD burned (split): supply down.
function pusdMintCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply + to_mathint(amount);
}

function pusdBurnCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply - to_mathint(amount);
}

function cvlMax(mathint a, mathint b) returns mathint {
    return a > b ? a : b;
}

// ------------------------------------------------------------
// `result` mapping abstracted into ghosts
// ------------------------------------------------------------
ghost mapping(uint256 => bool) ghostResultSet {
    init_state axiom forall uint256 c. !ghostResultSet[c];
}
ghost mapping(uint256 => uint256) ghostResultR0 {
    axiom forall uint256 c. ghostResultSet[c] =>
        to_mathint(ghostResultR0[c]) + to_mathint(ghostResultR1[c]) == RESULT_DENOMINATOR();
}
ghost mapping(uint256 => uint256) ghostResultR1;

// Spec-side reads of a condition's stored result (replace the old harness views; condKey is
// the YES position id). Mirror the views' semantics exactly: false / 0 when unresolved.
function cvlResolved(uint256 condKey) returns bool {
    return ghostResultSet[condKey];
}

function cvlR0(uint256 condKey) returns uint256 {
    return ghostResultSet[condKey] ? ghostResultR0[condKey] : 0;
}

function cvlR1(uint256 condKey) returns uint256 {
    return ghostResultSet[condKey] ? ghostResultR1[condKey] : 0;
}

// _storeResult summary
function storeResultCVL(NegRiskModule.ConditionId cid, uint256[] res) {
    if (res.length != 2) { revert(); }                                                  // InvalidArrayLength()
    if (to_mathint(res[0]) + to_mathint(res[1]) != RESULT_DENOMINATOR()) { revert(); }  // InvalidResults()
    uint256 condKey = NegRiskModule.condKeyOf(cid);
    ghostResultSet[condKey] = true;
    ghostResultR0[condKey] = res[0];
    ghostResultR1[condKey] = res[1];
}

// getResult summary: rebuild the length-2/0 result array from the ghost (length 2 = [r0, r1]
// when set, length 0 otherwise) so every munged read (.length, [0], [1]) observes the ghost.
function getResultCVL(NegRiskModule.ConditionId cid) returns uint256[] {
    uint256 condKey = NegRiskModule.condKeyOf(cid);
    uint256[] res;
    if (ghostResultSet[condKey]) {
        require res.length == 2;
        require res[0] == ghostResultR0[condKey];
        require res[1] == ghostResultR1[condKey];
    } else {
        require res.length == 0;
    }
    return res;
}

// _finalizeMigrationResolution summary: resolve the
// condition to a nondeterministic sum-to-D pair, ignoring the division-derived argument.
// Writing the pair directly keeps the ghostResultR0/R1 sum-to-D axiom satisfied.
function finalizeMigrationResolutionCVL(NegRiskModule.ConditionId cid) {
    uint256 condKey = NegRiskModule.condKeyOf(cid);
    uint256 r0;
    require to_mathint(r0) <= RESULT_DENOMINATOR(), "YES numerator is a fraction of D";
    ghostResultSet[condKey] = true;
    ghostResultR0[condKey] = r0;
    ghostResultR1[condKey] = assert_uint256(RESULT_DENOMINATOR() - r0);
}

// ------------------------------------------------------------
// Event-level scaled liability (D · eventLiability), arity=2
// ------------------------------------------------------------

// ghostSupply for `id`, except `overrideId` is taken as `overrideVal`. Used to recompute
// the pre-change event liability by reverting just the touched position's delta.
//
// require_uint256 pins the result to [0, max_uint256]: ghostSupply models a uint256 ERC1155
// token supply, so any value outside that range is unreachable.
// Pinning it is what keeps w_i = y_i - n_i within uint256 magnitude and keeps the nonlinear 
// result*supply products small enough for the prover.
function supplyOverride(uint256 id, uint256 overrideId, mathint overrideVal) returns mathint {
    mathint v = id == overrideId ? overrideVal : ghostSupply[id];
    return to_mathint(require_uint256(v));
}

// PIECEWISE part of D·eventLiability for the arity=2 event rooted at `eventBase`: the
// (D − S)·max_unresolved w_i term (0 when all resolved). The LINEAR part (D·ΣN + Σ resolved
// r0_i·w_i) is linear in supplies, so onSupplyChange folds it in via a closed-form delta and
// it is deliberately NOT computed here. YES_i id = eventBase + i·256; NO_i = +1.
// RETAINED AS THE REFERENCE FORM ONLY: onSupplyChange now uses negRiskMaxScaledDelta (below),
// and this function's sole caller is the negRiskMaxScaledDeltaEquivalence lemma tying the two.
function negRiskMaxScaled(uint256 eventBase, uint256 overrideId, mathint overrideVal) returns mathint {
    uint256 k0 = eventBase;
    uint256 k1 = require_uint256(eventBase + 256);
    uint256 k2 = require_uint256(eventBase + 512);

    mathint y0 = supplyOverride(k0, overrideId, overrideVal);
    mathint n0 = supplyOverride(require_uint256(k0 + 1), overrideId, overrideVal);
    mathint y1 = supplyOverride(k1, overrideId, overrideVal);
    mathint n1 = supplyOverride(require_uint256(k1 + 1), overrideId, overrideVal);
    mathint y2 = supplyOverride(k2, overrideId, overrideVal);
    mathint n2 = supplyOverride(require_uint256(k2 + 1), overrideId, overrideVal);

    // Supplies are already pinned to [0, max_uint256] by supplyOverride's require_uint256,
    // so each w_i = y_i - n_i is within uint256 magnitude and the unresolved-max is sound.
    mathint w0 = y0 - n0;
    mathint w1 = y1 - n1;
    mathint w2 = y2 - n2;

    bool res0 = cvlResolved(k0);
    bool res1 = cvlResolved(k1);
    bool res2 = cvlResolved(k2);

    mathint r0_0 = to_mathint(cvlR0(k0));
    mathint r1_0 = to_mathint(cvlR1(k0));
    mathint r0_1 = to_mathint(cvlR0(k1));
    mathint r1_1 = to_mathint(cvlR1(k1));
    mathint r0_2 = to_mathint(cvlR0(k2));
    mathint r1_2 = to_mathint(cvlR1(k2));

    // _storeResult invariant. Restates the ghostResultR0 axiom above; kept as a solver hint.
    require res0 => r0_0 + r1_0 == RESULT_DENOMINATOR();
    require res1 => r0_1 + r1_1 == RESULT_DENOMINATOR();
    require res2 => r0_2 + r1_2 == RESULT_DENOMINATOR();

    mathint sumResolvedR0 = (res0 ? r0_0 : 0) + (res1 ? r0_1 : 0) + (res2 ? r0_2 : 0);

    // Neg-risk aggregate invariant: Σ resolved YES numerators <= D (resultsSum <= D), so
    // the remaining YES budget (D − S) for the unresolved conditions is non-negative.
    // Proved by resultsSumBounded / resultsSumTracksYesNumerators (NegRisk-Partition01.spec);
    // not derivable in this file's model, hence a require.
    require sumResolvedR0 <= RESULT_DENOMINATOR();

    bool allResolved = res0 && res1 && res2;

    // When every condition is resolved the YES budget is fully allocated, so the neg-risk
    // coupling forces Σ r0 == D exactly. Without it, a havoc'd fully-resolved state with Σ r0 < D 
    // makes a complete-set merge return `amount` collateral while liability drops by only (Σ r0)·amount < D·amount.
    // (In partial resolution the (D − S)·max term carries the remainder, so S < D is fine there.)
    require !allResolved || sumResolvedR0 == RESULT_DENOMINATOR();

    // Best the adversary can do with the remaining (D − S) YES budget: give it to the most
    // valuable unresolvec condition, i.e. max{ w_i : i unresolved }. Computed branch-free by
    // masking resolved conditions to NEG_INF (safe: w_i >= -(2^256-1) > NEG_INF since supplies
    // are pinned to uint256), so the prover never case-splits on the resolved combination.
    // When allResolved every t_i = NEG_INF, but unresolvedTerm drops it, so it never leaks.
    mathint t0 = res0 ? NEG_INF() : w0;
    mathint t1 = res1 ? NEG_INF() : w1;
    mathint t2 = res2 ? NEG_INF() : w2;
    mathint maxUnresolved = cvlMax(t0, cvlMax(t1, t2));

    // (D − S)·max over unresolved conditions; the linear part is added by onSupplyChange.
    return allResolved ? 0 : (RESULT_DENOMINATOR() - sumResolvedR0) * maxUnresolved;
}

// Delta form of the piecewise term: negRiskMaxScaled(new) − negRiskMaxScaled(old) computed
// directly, exploiting two facts a supply change guarantees by construction:
//   (1) results are untouched, so S, allResolved and every NEG_INF mask coincide in both
//       evaluations — the common (D − S) factor is factored out by hand instead of asking
//       the solver for a distributivity step over two large ite-trees;
//   (2) only the touched condition's w_j moves, so both max chains share `rest` (the max
//       over the untouched conditions) and differ in a single leaf.
// The recompute-twice pattern's TWO large (D − S)·max products become ONE product whose
// right factor, max(w_j_new, rest) − max(w_j_old, rest), is syntactically 0 whenever the
// touched leg is not the argmax on either side, and is bounded by |delta| (max is
// 1-Lipschitz per leaf) — the shape the solvency bound liability delta <= D·|delta| needs.
// Early-outs return 0 where the two evaluations coincide by construction (allResolved: both
// return 0; positionId's condition outside the event: the override id is never read; touched
// condition resolved: t_j = NEG_INF on both sides).
// The condKey derivation below truncates positionId's outcome byte, so it assumes the event's
// legs sit on a 256-aligned grid under a 2^24-aligned eventBase — true for every eventBaseOf
// output, which is the only way onSupplyChange derives eventBase.
function negRiskMaxScaledDelta(uint256 eventBase, uint256 positionId, mathint delta) returns mathint {
    uint256 k0 = eventBase;
    uint256 k1 = require_uint256(eventBase + 256);
    uint256 k2 = require_uint256(eventBase + 512);

    bool res0 = cvlResolved(k0);
    bool res1 = cvlResolved(k1);
    bool res2 = cvlResolved(k2);

    mathint r0_0 = to_mathint(cvlR0(k0));
    mathint r1_0 = to_mathint(cvlR1(k0));
    mathint r0_1 = to_mathint(cvlR0(k1));
    mathint r1_1 = to_mathint(cvlR1(k1));
    mathint r0_2 = to_mathint(cvlR0(k2));
    mathint r1_2 = to_mathint(cvlR1(k2));

    // _storeResult invariant
    require res0 => r0_0 + r1_0 == RESULT_DENOMINATOR(), "Result must sum to RESULT_DENOMINATOR()";
    require res1 => r0_1 + r1_1 == RESULT_DENOMINATOR(), "Result must sum to RESULT_DENOMINATOR()";
    require res2 => r0_2 + r1_2 == RESULT_DENOMINATOR(), "Result must sum to RESULT_DENOMINATOR()";

    mathint sumResolvedR0 = (res0 ? r0_0 : 0) + (res1 ? r0_1 : 0) + (res2 ? r0_2 : 0);
    require sumResolvedR0 <= RESULT_DENOMINATOR(), "Result must sum to RESULT_DENOMINATOR()";

    bool allResolved = res0 && res1 && res2;
    require !allResolved || sumResolvedR0 == RESULT_DENOMINATOR();

    // Every condition resolved: both evaluations return 0.
    if (allResolved) { return 0; }

    // The touched condition's YES id, obtained by truncating positionId's outcome byte. Unless
    // that condition is one of the event's three, the override id is never read and the two
    // evaluations are identical.
    uint256 condKey = require_uint256((positionId / 2 ^ 8) * 2 ^ 8);
    uint256 noLeg = require_uint256(condKey + 1);
    if (condKey != k0 && condKey != k1 && condKey != k2) { return 0; }
    // if (positionId != condKey && positionId != noLeg) { return 0; }

    // Touched condition resolved: masked to NEG_INF on both sides.
    bool resj = condKey == k0 ? res0 : (condKey == k1 ? res1 : res2);
    if (resj) { return 0; }

    // All six legs pinned to uint256
    mathint y0 = require_uint256(ghostSupply[k0]);
    mathint n0 = require_uint256(ghostSupply[require_uint256(k0 + 1)]);
    mathint y1 = require_uint256(ghostSupply[k1]);
    mathint n1 = require_uint256(ghostSupply[require_uint256(k1 + 1)]);
    mathint y2 = require_uint256(ghostSupply[k2]);
    mathint n2 = require_uint256(ghostSupply[require_uint256(k2 + 1)]);

    mathint t0 = res0 ? NEG_INF() : y0 - n0;
    mathint t1 = res1 ? NEG_INF() : y1 - n1;
    mathint t2 = res2 ? NEG_INF() : y2 - n2;

    // Identical in both evaluations: the max over the two untouched conditions.
    mathint rest = condKey == k0 ? cvlMax(t1, t2) : (condKey == k1 ? cvlMax(t0, t2) : cvlMax(t0, t1));

    // w_j on both sides: only positionId's own supply differs, by delta. For a YES leg
    // w_j = touched − sibling, for a NO leg w_j = sibling − touched, so reverting the
    // touched read swaps in as +/−(old − new) without re-branching on the condition index.
    mathint wjNew = condKey == k0 ? y0 - n0 : (condKey == k1 ? y1 - n1 : y2 - n2);
    mathint touchedNew = require_uint256(ghostSupply[positionId]);
    mathint touchedOld = require_uint256(ghostSupply[positionId] - delta);
    mathint wjOld = positionId == condKey ? wjNew - touchedNew + touchedOld : wjNew + touchedNew - touchedOld;

    return (RESULT_DENOMINATOR() - sumResolvedR0) * (cvlMax(wjNew, rest) - cvlMax(wjOld, rest));
}

// Maintain liabilityScaled after a supply change of `delta` at `positionId`. ghostSupply
// already reflects the post-change value, so new = current, old = revert this id by delta.
function onSupplyChange(uint256 positionId, mathint delta) {
    require moduleIdOf(positionId) == 2, "NegRisk solvency scene: positions are NegRisk (moduleId 2)";
    require arityOf(positionId) == 2, "bounded proof: arity = 2 (fits loop_iter = 3)";
    // An arity=2 event only has conditions 0,1 (real) and 2 (synthetic Other). A position at
    // conditionIndex >= 3 is unreachable.
    require conditionIndexOf(positionId) <= 2, "arity=2 event: conditions are 0, 1, and Other(2)";

    uint256 eventBase = require_uint256(eventBaseOf(positionId));

    // The event-scaled liability splits into a LINEAR part (D·ΣN + Σ resolved r0_i·w_i) and a
    // PIECEWISE max part. The linear part is linear in supplies, so a one-position change has
    // an EXACT closed-form delta needing only the TOUCHED condition's result — this is what
    // drops the redundant per-condition r0_i·w_i products of recomputing the whole event twice.
    //
    // condKey = the touched condition's YES id (outcome byte cleared); positionId == condKey
    // iff the touched leg is YES. For a YES change w_j moves by +delta ⇒ dLinear = coeff·delta;
    // for a NO change the D·NO baseline moves by +delta and w_j by −delta ⇒ (D − coeff)·delta.
    // coeff = (resolved ? r0_j : 0); D − coeff models r1_j (= D − r0_j by the sum-to-D require).
    uint256 condKey = require_uint256((positionId / 2 ^ 8) * 2 ^ 8);
    mathint coeff = cvlResolved(condKey)
        ? to_mathint(cvlR0(condKey)) : 0;
    require coeff <= RESULT_DENOMINATOR(), "Factors are limited to RESULT_DENOMINATOR";
    mathint linearDelta = positionId == condKey
        ? coeff * delta // YES
        : (RESULT_DENOMINATOR() - coeff) * delta; // NO

    // Piecewise max part in DELTA form (one nonlinear product instead of the two the
    // recompute-twice pattern needs); equivalence with negRiskMaxScaled(new) − (old) is
    // proven by negRiskMaxScaledDeltaEquivalence.
    liabilityScaled = liabilityScaled + linearDelta + negRiskMaxScaledDelta(eventBase, positionId, delta);
}

// ------------------------------------------------------------
// liability-aware PM mint/burn wrappers
// ------------------------------------------------------------

function liabAwareMint(env e, address to, uint256 id, uint256 amount) {
    mintWithAuthCVL(e, to, id, amount);
    onSupplyChange(id, to_mathint(amount));
}

function liabAwareBurn(env e, uint256 id, uint256 amount) {
    burnWithAuthCVL(e, id, amount);
    onSupplyChange(id, -to_mathint(amount));
}

function liabAwareBatchMint(env e, address to, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (to == 0) { revert(); }
    if (ids.length > 0) { liabAwareMintElem(to, ids[0], amounts[0]); }
    if (ids.length > 1) { liabAwareMintElem(to, ids[1], amounts[1]); }
    if (ids.length > 2) { liabAwareMintElem(to, ids[2], amounts[2]); }
}

function liabAwareMintElem(address to, uint256 id, uint256 amount) {
    if (ghostBalance[to][id] + to_mathint(amount) > max_uint256) { revert(); }
    mintCVL(to, id, amount);
    onSupplyChange(id, to_mathint(amount));
}

function liabAwareBatchBurn(env e, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (ids.length > 0) { liabAwareBurnElem(e.msg.sender, ids[0], amounts[0]); }
    if (ids.length > 1) { liabAwareBurnElem(e.msg.sender, ids[1], amounts[1]); }
    if (ids.length > 2) { liabAwareBurnElem(e.msg.sender, ids[2], amounts[2]); }
}

function liabAwareBurnElem(address from, uint256 id, uint256 amount) {
    burnByCVL(0, from, id, amount);
    onSupplyChange(id, -to_mathint(amount));
}

// ------------------------------------------------------------
// Shared solvency helpers (used by the parametric and dedicated rules)
// ------------------------------------------------------------

// The counted asset side of the solvency inequality:
// vault_USDC + vault_USDCe + USDCe.bal(ConditionalTokens).
function countedAssets() returns mathint {
    address usdc = CollateralToken.USDC();
    address usdce = CollateralToken.USDCE();
    address vault = CollateralToken.VAULT();
    return balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
}

// The headline inequality, scaled by D (see the Solvency header comment):
// D·(vault + CT reserve) >= D·pUSD totalSupply + liabilityScaled.
function solvencyScaledHolds() returns bool {
    return RESULT_DENOMINATOR() * countedAssets()
        >= RESULT_DENOMINATOR() * ghostPusdSupply + liabilityScaled;
}

// Deployment separation: the collateral vault is a dedicated deposit wallet, never a
// scene contract. Without these, the prover aliases VAULT() to a counted-ledger holder
// and fabricates spurious CEXes (seen on job 8b021731): vault == ConditionalTokens
// double-counts the CT reserve inside countedAssets(), so a real CT -> module payout
// looks like an asset loss; vault == NegRiskModule turns the settle sweep into a
// self-transfer that "leaves" the module balance nonzero. Reachable-state facts only.
function requireVaultSeparation() {
    require CollateralToken.VAULT() != NegRiskModule,
        "deployment: the collateral vault is not the module";
    require CollateralToken.VAULT() != ConditionalTokens,
        "deployment: the collateral vault is not the legacy ConditionalTokens";
}

/* =============================================================================
 * NEGRISK-PARTITION-02 — conditionsResolved is monotone and bounded by arity+1
 *
 * conditionsResolved[e] never decreases and never exceeds arity+1 across all
 * reachable transitions, because each condition resolves at most once.
 *
 *  [02a] conditionsResolvedMonotone — parametric, ANY arity: no method decreases conditionsResolved[e].
 *  [02b] resolvedConditionImmutable — "each condition resolves at most once":
 *        once result[c] is stored (length 2), its length and both numerators never change.
 *  [02c] counterMatchesResolvedCount — the inductive strengthening:
 *        conditionsResolved[e] equals the ground-truth number of resolved
 *        conditions of e over indexes [0, arity - 1].
 *  [02d] conditionsResolvedBounded — the headline bound: with [02c] in the
 *        pre-state the counter equals a sum of arity+1 zero/one indicators, so
 *        no transition can push it past arity+1. [02a] + [02d] = the property.
 *
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Resolution Integrity
 * @contract NegRiskModule
 * @impact An event partition could exceed the full denominator, so its positions would redeem for more than was committed
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 *
 * PROPERTIES
 * @property NEGRISK-PARTITION-02 The resolved-condition counter of an event is monotone and never exceeds the number of conditions it has.
 */


import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using NegRiskModuleHarness as NegRiskModule;
using PositionManager as PositionManager;
using DummyERC20Impl as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- harness pure/view helpers (envfree) ---- */
    function conditionsResolvedOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function arityOf(NegRiskModule.EventId) external returns (uint256) envfree;
    // Ground-truth resolved count over indexes [0, arity - 1], read directly from result
    // lengths. Excludes the synthetic Other at index `arity`.
    function realResolvedCountOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function resultLen(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR0(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR1(NegRiskModule.ConditionId) external returns (uint256) envfree;

    /* ---- PositionManager / CollateralToken: irrelevant to resolution state, summarize away ---- */
    function _.moduleId() external => DISPATCHER(true);

    // This exact entry takes precedence over the wildcard and pins it to the real code.
    function NegRiskModule.getResult(NegRiskModule.ConditionId) external returns (uint256[]) envfree;

    /* ---- module immutable wiring (NOT linked, so PM/CT calls stay unresolved) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;
    // Sound: allow the prover to match the receiver to `ConditionalTokens`
    function _._legacyConditionalTokens() external => ConditionalTokens expect address;

    /* ---- remaining legacy CTF backing reads ---- */
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;

    // They only touch legacy-side balances/collateral, never conditionsResolved 
    // result state, so NONDET is sound for these rules.
    function ConditionalTokens.balanceOf(address, uint256) external returns (uint256) => NONDET;
    function ConditionalTokens.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function ConditionalTokens.safeBatchTransferFrom(address, address, uint256[], uint256[], bytes) external => NONDET;
    // Sound over approximation: payoutNumerators feeds the nonlinear `x * RESULT_DENOMINATOR / denom`.
    function ConditionalTokens.payoutNumerators(bytes32, uint256) external returns (uint256) => NONDET;
    // Heavy legacy-only helpers: redeem + vault settle move only legacy balances/collateral.
    function _._redeemLegacyPositions(bytes32) internal => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;
    function CTFHelpers.partition() internal returns (uint256[] memory) => partitionCVL();
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;

    /* ---- OwnableRoles wiring ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// CTFHelpers.partition() builds [1,2] via raw-assembly free-memory-pointer bumps, which
// poison prover PTA across the migratePositions call graph; a clean CVL array restores
// precise call resolution.
function partitionCVL() returns uint256[] {
    uint256[] result;
    require result.length == 2, "partition() always returns a 2-element array";
    require result[0] == 1, "partition()[0] is the YES index set 0b01";
    require result[1] == 2, "partition()[1] is the NO index set 0b10";
    return result;
}

// realResolvedCountOf enumerates indexes 0..4 hand-unrolled (no `for`), so it is exact at any
// --loop_iter. the conf runs at loop_iter 3 to bound the migratePositions resolution loop.
definition ARITY_SCOPE() returns mathint = 4;

// Ownership-handover functions touch keccak-derived assembly slots
// that the prover cannot separate from the `result` dynamic-array slots, 
// so the write havocs `result[c]` and yields spurious CEXs.
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:NegRiskModule.requestOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.cancelOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.completeOwnershipHandover(address).selector
    // Equivalence-proof harness wrappers (NegRiskMigrationEquivalence); not production entry points
    || f.selector == sig:NegRiskModule.redeemIfResolvedDuringMigrateReal(NegRiskModule.ConditionId,bytes32).selector
    || f.selector == sig:NegRiskModule.legacyMintedKey(bytes32,uint256).selector;

// view/pure methods cannot move `conditionsResolved` or `result`, so they discharge trivially.
definition NO_STATE_CHANGE(method f) returns bool = f.isView || f.isPure;

/* =============================================================================
 * [NEGRISK-PARTITION-02a] conditionsResolved never decreases (any arity)
 * ============================================================================= */
/**
 * @title the resolved counter is monotone
 * @description No method decreases the resolved-condition counter of an event.
 * @link_property NEGRISK-PARTITION-02
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/effca1798b7b441dbdac7836d607b7f4?anonymousKey=f168a0e9aa4b7e11e7ac04f31dc0ae9698af93e6
 */
rule conditionsResolvedMonotone(NegRiskModule.EventId e, method f)
filtered { f -> !OUT_OF_SCOPE(f) && !NO_STATE_CHANGE(f) } {
    uint256 before = conditionsResolvedOf(e);

    env ev;
    calldataarg args;
    f(ev, args);

    assert conditionsResolvedOf(e) >= before, "conditionsResolved[e] must be monotone non-decreasing";
}

/* =============================================================================
 * [NEGRISK-PARTITION-02b] each condition resolves at most once (any arity)
 *
 * Once a result is stored, neither its length nor its numerators ever change —
 * the mechanism that makes the +1 counter honest.
 * ============================================================================= */
/**
 * @title a resolved condition stays resolved
 * @description Each condition resolves at most once and never returns to unresolved.
 * @link_property NEGRISK-PARTITION-02
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/effca1798b7b441dbdac7836d607b7f4?anonymousKey=f168a0e9aa4b7e11e7ac04f31dc0ae9698af93e6
 */
rule resolvedConditionImmutable(NegRiskModule.ConditionId c, method f)
filtered { f -> !OUT_OF_SCOPE(f) && !NO_STATE_CHANGE(f) } {
    require resultLen(c) == 2,"Condition has 2 possible results";
    uint256 r0Before = realR0(c);
    uint256 r1Before = realR1(c);

    env ev;
    calldataarg args;
    f(ev, args);

    assert resultLen(c) == 2 && realR0(c) == r0Before && realR1(c) == r1Before,"a stored result must never be overwritten or deleted";
}

/* =============================================================================
 * [NEGRISK-PARTITION-02c] counter == ground-truth resolved count (arity <= 4)
 *
 * Inductive strengthening for 02d: every +1 of conditionsResolved[e] is paired
 * with exactly one 0->2 result-length flip of a condition of e at index < arity,
 * and results are never deleted, so the counter tracks the indicator sum exactly.
 * ============================================================================= */
/**
 * @title the counter matches the resolved conditions
 * @description The resolved-condition counter equals the number of conditions of the event that carry a stored result.
 * @link_property NEGRISK-PARTITION-02
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/6340fe52883e49c1902b95fb761d88bd?anonymousKey=5d68be0547e8165c1bb8c7a9188bea51fb661869
 */
invariant counterMatchesResolvedCount(NegRiskModule.EventId e)
    to_mathint(arityOf(e)) <= ARITY_SCOPE() => to_mathint(conditionsResolvedOf(e)) == to_mathint(realResolvedCountOf(e))
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * [NEGRISK-PARTITION-02d] conditionsResolved <= arity + 1 (arity <= 4)
 *
 * With 02c in the pre-state, the counter equals a sum of arity+1 zero/one
 * indicators, so no transition can push it past arity+1. Double-counting a
 * resolved condition would break 02c before it could break this bound.
 * ============================================================================= */
/**
 * @title the resolved counter is bounded
 * @description The resolved-condition counter never exceeds the number of conditions of the event.
 * @link_property NEGRISK-PARTITION-02
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af9102b21dde48afa50b50c6536758b7?anonymousKey=70c2a4e0002db2dfd9b16c9e7e4508baa5ba0a12
 */
invariant conditionsResolvedBounded(NegRiskModule.EventId e)
    to_mathint(arityOf(e)) <= ARITY_SCOPE() => to_mathint(conditionsResolvedOf(e)) <= to_mathint(arityOf(e)) + 1
    filtered { f -> !OUT_OF_SCOPE(f) }
    {
        preserved {
            // We need it because of inductivity
            requireInvariant counterMatchesResolvedCount(e);
        }
    }

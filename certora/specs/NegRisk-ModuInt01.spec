/* =============================================================================
 * MODU-INT-01 — NegRiskModule result tracking integrity
 *
 * Property: for every neg-risk event e, the running counter `resultsSum[e]`
 * always equals the sum of the YES numerators (result[c][0]) of every condition
 * resolved into e:
 *     resultsSum[e] == Σ_{c ∈ e} result[c][0]
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Resolution Integrity
 * @contract NegRiskModule
 * @impact An event partition could exceed the full denominator, so its positions would redeem for more than was committed
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 * PROPERTIES
 * @property MODU-INT-01 the per-event result counter always equals the sum of the YES numerators of the conditions resolved into that event.
 */


import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using NegRiskModuleHarness as NegRiskModule;
using PositionManager as PositionManager;
using DummyERC20Impl as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    // ---- harness pure/view helpers (envfree) ---- 
    function resultsSumOf(NegRiskModule.EventId) external returns (uint256) envfree;
    // Independent per-event sum of stored YES numerators (result[c][0]), re-derived from every `_storeResult` write. 
    function yesSumOf(NegRiskModule.EventId) external returns (uint256) envfree;

    // ---- PositionManager / CollateralToken: irrelevant to resultsSum, summarize away 
    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);

    // This exact entry takes precedence over the wildcard and pins it to the real code.
    function NegRiskModule.getResult(NegRiskModule.ConditionId) external returns (uint256[]) envfree;

    /* ---- module immutable wiring (NOT linked, so PM/CT calls stay unresolved) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    /* ---- remaining legacy CTF backing reads ---- */
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;

    /* ---- OwnableRoles wiring ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// Ownership-handover + equivalence-proof harness wrappers are not production entry points.
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:NegRiskModule.requestOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.cancelOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.completeOwnershipHandover(address).selector
    || f.selector == sig:NegRiskModule.redeemIfResolvedDuringMigrateReal(NegRiskModule.ConditionId,bytes32).selector
    || f.selector == sig:NegRiskModule.legacyMintedKey(bytes32,uint256).selector;

/* =============================================================================
 * MODU-INT-01 — resultsSum[e] equals the independently-accumulated sum of stored
 * YES numerators, for any arity and including the migration path.
 * ============================================================================= */
/**
 * @title the result counter tracks resolved conditions
 * @description For every event the running result counter equals the sum of the YES numerators of its resolved conditions.
 * @link_property MODU-INT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/b45757c73776474eb76a7bba0b69d9ad?anonymousKey=2ada1b171d08b00422d22a57ff81ea79657f8562
 */
invariant resultsSumTracksConditions(NegRiskModule.EventId e)
    to_mathint(resultsSumOf(e)) == to_mathint(yesSumOf(e))
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * RESULT-NORMALIZED-01 — BinaryModule: stored results are always length 2 and sum to RESULT_DENOMINATOR
 *
 * For every condition c with result[c].length > 0: result[c].length == 2 && result[c][0] + result[c][1] == 1_000_000
 * and reportResult reverts on a malformed result vector.
 *
 * ============================================================================= */

/*
 * MODULE
 * @module BinaryModule Resolution Integrity
 * @contract BinaryModule
 * @impact A malformed or mutable result could make a condition pay out more than the denominator
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 5 iterations
 * PROPERTIES
 * @property BINARY-RESULT-NORMALIZED-01 Every BinaryModule stored result is a complementary pair summing to the result denominator, and reportResult rejects a malformed vector.
 */


import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using BinaryModuleHarness as BinaryModule;
using PositionManager as PositionManager;
using DummyERC20Impl as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- harness view helpers (envfree, never revert) ---- */
    function resultLen(BinaryModule.ConditionId) external returns (uint256) envfree;
    function realR0(BinaryModule.ConditionId) external returns (uint256) envfree;
    function realR1(BinaryModule.ConditionId) external returns (uint256) envfree;
    function isMigration(BinaryModule.ConditionId) external returns (bool) envfree;
    function pidObj(BinaryModule.ConditionId, uint256) external returns (BinaryModule.PositionId) envfree;

    /* ---- real production payout (BaseModule.getPayout), reads the same `result` mapping ---- */
    function getPayout(BinaryModule.PositionId, uint256) external returns (uint256) envfree;

    /* ---- PositionManager / CollateralToken: irrelevant to resolution state ---- */
    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);

    /* ---- module immutable wiring (NOT linked, so PM/CT calls stay unresolved) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    // Legacy CTF backing reads
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;

    // OwnableRoles wiring
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

definition RESULT_DENOMINATOR() returns mathint = 1000000;

// Ownership-handover functions touch keccak-derived assembly slots that the
// prover cannot separate from the `result` dynamic-array slots, so the write
// havocs `result[c]` and yields spurious CEXs.
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:BinaryModule.requestOwnershipHandover().selector
    || f.selector == sig:BinaryModule.cancelOwnershipHandover().selector
    || f.selector == sig:BinaryModule.completeOwnershipHandover(address).selector
    // Equivalence-proof harness wrapper (BinaryMigrationResolutionEquivalence); not a production entry point
    || f.selector == sig:BinaryModule.finalizeMigrationResolutionModel(BinaryModule.ConditionId).selector;

/* =============================================================================
 * [RESULT-NORMALIZED-01a] stored results are empty or normalized
 * ============================================================================= */
/**
 * @title stored results are normalized
 * @description For every condition with a stored result, the result is a pair summing to the result denominator.
 * @link_property BINARY-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/21e4020ae0b344cf91a9070b18af47a6?anonymousKey=a534642da330ec141683886808f692b46e51e6b7
 */
invariant resultNormalized(BinaryModule.ConditionId c)
    resultLen(c) == 0 || (resultLen(c) == 2 && realR0(c) + realR1(c) == RESULT_DENOMINATOR())
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * [RESULT-NORMALIZED-01b] reportResult reverts on a malformed result vector
 * ============================================================================= */
/**
 * @title reportResult rejects a malformed result
 * @description reportResult reverts on any result vector that is not a complementary pair.
 * @link_property BINARY-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/21e4020ae0b344cf91a9070b18af47a6?anonymousKey=a534642da330ec141683886808f692b46e51e6b7
 */
rule reportResultRevertsOnMalformed(BinaryModule.ConditionId c, uint256[] r) {
    require resultLen(c) == 0, "fresh condition";

    // r malformed: wrong length, or a length-2 vector not summing to RESULT_DENOMINATOR. (element reads only under the length guard)
    if (r.length == 2) {
        require r[0] + r[1] != RESULT_DENOMINATOR(), "malformed len-2 = wrong sum; any other length is malformed by length alone";
    }

    env e;
    reportResult@withrevert(e, c, r);

    assert lastReverted, "reportResult must revert on a malformed result vector";
}

/* =============================================================================
 * [RESULT-NORMALIZED-01c] a stored result is immutable under reportResult
 * ============================================================================= */
/**
 * @title a stored result cannot be changed
 * @description reportResult can never overwrite a result that is already stored.
 * @link_property BINARY-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/21e4020ae0b344cf91a9070b18af47a6?anonymousKey=a534642da330ec141683886808f692b46e51e6b7
 */
rule reportResultCannotChangeStoredResult(BinaryModule.ConditionId c) {
    // sound: 01a proves this for every state; here it only rules out an unreachable pre-state (e.g. len 1) that would fake a CEX
    requireInvariant resultNormalized(c);
    require resultLen(c) > 0, "resolved only: immutability says nothing about an unresolved condition";

    uint256 r0Before = realR0(c);
    uint256 r1Before = realR1(c);

    env e;
    calldataarg args;
    reportResult(e, args);

    assert resultLen(c) == 2 && realR0(c) == r0Before && realR1(c) == r1Before,  "a stored result must never be changed by a later reportResult";
}

/* =============================================================================
 * [RESULT-NORMALIZED-01d] a normalized result never overpays
 * ============================================================================= */
/**
 * @title payouts conserve the redeemed amount
 * @description The YES and NO payouts of a resolved condition together account for the amount that funded it.
 * @link_property BINARY-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/21e4020ae0b344cf91a9070b18af47a6?anonymousKey=a534642da330ec141683886808f692b46e51e6b7
 */
rule payoutConservation(BinaryModule.ConditionId c, uint256 amount) {
    // resolved + normalized (len 2, r0+r1 == 1e6): the exact pre-state getPayout assumes
    requireInvariant resultNormalized(c);

    uint256 payoutYes = getPayout(pidObj(c, 0), amount);
    uint256 payoutNo = getPayout(pidObj(c, 1), amount);

    assert payoutYes + payoutNo <= amount, "normalized result => YES+NO payout can never exceed the redeemed principal";
}

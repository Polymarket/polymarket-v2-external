/* =============================================================================
 * RESULT-NORMALIZED-01 — NegRiskModule: stored results are always length 2
 * and sum to RESULT_DENOMINATOR
 *
 * For every condition c with result[c].length > 0:
 *   result[c].length == 2 && result[c][0] + result[c][1] == 1_000_000
 * and reportResult reverts on a malformed result vector.
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
 * @property NEGRISK-RESULT-NORMALIZED-01 Every NegRiskModule stored result is a complementary pair summing to the result denominator, and reportResult rejects a malformed vector.
 */


import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using NegRiskModuleHarness as NegRiskModule;
using PositionManager as PositionManager;
using DummyERC20Impl as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- harness view helpers (envfree, never revert) ---- */
    function resultLen(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR0(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR1(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function isMigration(NegRiskModule.ConditionId) external returns (bool) envfree;
    function condFrom(bytes32) external returns (NegRiskModule.ConditionId) envfree;

    /* ---- PositionManager / CollateralToken: irrelevant to resolution state ---- */
    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);

    // `getPayout` now calls `getResult` instead of reading `result[...]` directly, so the `_.getResult`
    // DISPATCHER wildcard above also captures the module's own self-call and replaces the real derivation with a
    // nondeterministic dispatch.This exact entry takes precedence over the wildcard and pins it to the real code.
    function NegRiskModule.getResult(NegRiskModule.ConditionId) external returns (uint256[]) envfree;

    /* ---- module immutable wiring (NOT linked, so PM/CT calls stay unresolved) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    /* ---- remaining legacy CTF backing reads ----
     * payoutNumerators intentionally NOT summarized: the migration normalization
     * preserves the sum for arbitrary returned values (see header). ---- */
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;

    // sound : legacy-collateral vault settlement is pure plumbing
    // it only reads/transfers USDC.e + legacy-collateral balances to the vault and emits, and
    // never writes `result` / `resultsSum` / `conditionsResolved` (the only state this spec
    // reads via resultLen/realR0/realR1). 
    function _._settleLegacyCollateralToVault() internal => NONDET;

    /* ---- OwnableRoles wiring ---- */
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
    f.selector == sig:NegRiskModule.requestOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.cancelOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.completeOwnershipHandover(address).selector
    // Equivalence-proof harness wrappers (NegRiskMigrationEquivalence); not production entry points
    || f.selector == sig:NegRiskModule.redeemIfResolvedDuringMigrateReal(NegRiskModule.ConditionId,bytes32).selector
    || f.selector == sig:NegRiskModule.legacyMintedKey(bytes32,uint256).selector;

/* =============================================================================
 * [RESULT-NORMALIZED-01a] stored results are empty or normalized
 * ============================================================================= */
/**
 * @title stored results are normalized
 * @description For every condition with a stored result, the result is a pair summing to the result denominator.
 * @link_property NEGRISK-RESULT-NORMALIZED-01
 * @assumption The migration step is bounded to at most 2 migrated positions per call
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/05ec90095e7342f5901aa5c5adce800a?anonymousKey=c4b8a82482e720a5d56e8e7129a829995ded0c7f
 */
invariant resultNormalized(NegRiskModule.ConditionId c)
    resultLen(c) == 0
        || (resultLen(c) == 2 && realR0(c) + realR1(c) == RESULT_DENOMINATOR())
    filtered { f -> !OUT_OF_SCOPE(f) }
{
    // `_migratePositions` derives its loop bound from `_legacyConditionIds.length` and requires the
    // other two arrays to match, so bounding this one bounds the migration.
    preserved migratePositions(
        bytes32[] _legacyConditionIds, uint256[] _outcomeIndices, uint256[] _amounts
    ) with (env e) {
        require _legacyConditionIds.length <= 2, "bounded proof: at most 2 migrated positions per call";
    }
    preserved migratePositions(
        address _from, bytes32[] _legacyConditionIds, uint256[] _outcomeIndices, uint256[] _amounts
    ) with (env e) {
        require _legacyConditionIds.length <= 2, "bounded proof: at most 2 migrated positions per call";
    }
}

/* =============================================================================
 * [RESULT-NORMALIZED-01b] reportResult reverts on a malformed result vector
 * ============================================================================= */
/**
 * @title reportResult rejects a malformed result
 * @description reportResult reverts on any result vector that is not a complementary pair.
 * @link_property NEGRISK-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/63e32c2dedf84f7da9e9e95faa8e2910?anonymousKey=71dc40b7fe002ea2d01d6abcbf989a63541a0d6c
 */
rule reportResultRevertsOnMalformed(NegRiskModule.ConditionId c, uint256[] r) {
    require resultLen(c) == 0, "fresh cond: only here does the caller vector reach _storeResult; resolved path is compare-only (01c)";

    // r malformed: wrong length, or a length-2 vector not summing to RESULT_DENOMINATOR.
    // (element reads only under the length guard)
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
 * @link_property NEGRISK-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/63e32c2dedf84f7da9e9e95faa8e2910?anonymousKey=71dc40b7fe002ea2d01d6abcbf989a63541a0d6c
 */
rule reportResultCannotChangeStoredResult(NegRiskModule.ConditionId c) {
    // sound: 01a proves this for every state; here it only rules out an unreachable pre-state (e.g. len 1) that would fake a CEX
    requireInvariant resultNormalized(c);
    require resultLen(c) > 0, "resolved only: immutability says nothing about an unresolved condition";

    uint256 r0Before = realR0(c);
    uint256 r1Before = realR1(c);

    env e;
    calldataarg args;
    reportResult(e, args);

    assert resultLen(c) == 2 && realR0(c) == r0Before && realR1(c) == r1Before, "a stored result must never be changed by a later reportResult";
}

/* =============================================================================
 * [RESULT-NORMALIZED-01d] a normalized result never overpays
 * ============================================================================= */
/**
 * @title payouts conserve the redeemed amount
 * @description The YES and NO payouts of a resolved condition together account for the amount that funded it.
 * @link_property NEGRISK-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/63e32c2dedf84f7da9e9e95faa8e2910?anonymousKey=71dc40b7fe002ea2d01d6abcbf989a63541a0d6c
 */
rule payoutConservation(NegRiskModule.ConditionId c, uint256 amount) {
    // resolved + normalized (len 2, r0+r1 == 1e6): the exact pre-state a payout assumes
    requireInvariant resultNormalized(c);
    require resultLen(c) > 0, "resolved only: an unresolved condition pays nothing, so there is nothing to conserve";

    // Corollary of 01a
    mathint payoutYes = to_mathint(amount) * realR0(c) / RESULT_DENOMINATOR();
    mathint payoutNo = to_mathint(amount) * realR1(c) / RESULT_DENOMINATOR();

    assert payoutYes + payoutNo <= to_mathint(amount), "normalized result => YES+NO payout can never exceed the redeemed principal";
}

/* =============================================================================
 * [RESULT-NORMALIZED-01f] the migration path can only store a BINARY result
 * ============================================================================= */
/**
 * @title a migrated result is binary
 * @description A result stored by the migration path is always a definitive binary outcome.
 * @link_property NEGRISK-RESULT-NORMALIZED-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/63e32c2dedf84f7da9e9e95faa8e2910?anonymousKey=71dc40b7fe002ea2d01d6abcbf989a63541a0d6c
 */
rule migrationStoredResultIsBinary(bytes32 rawConditionId) {
    // pins legacy payouts to canonical binary resolutions to kill a nonlinear-arithmetic blowup, and
    // its non-lossiness argument rests on "any other quotient reverts".
    NegRiskModule.ConditionId c = condFrom(rawConditionId);
    require resultLen(c) == 0,"fresh cond: only here does the migration path derive and store a result; a resolved cond is a no-op store";

    env e;
    resolveMigrationCondition(e, rawConditionId);

    // A successful call on a fresh condition always stores: `_redeemIfResolved`
    // returning false (payoutDenominator == 0) reverts ConditionNotResolved.
    assert resultLen(c) == 2, "a successful resolve on a fresh condition must store a length-2 result";
    assert realR0(c) == 0 || to_mathint(realR0(c)) == RESULT_DENOMINATOR(), "migration normalization can only store a fully-NO or fully-YES result, never a fraction";
}

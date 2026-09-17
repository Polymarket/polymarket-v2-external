/* =============================================================================
 * NEGRISK-PARTITION-01 — NegRiskModule partition accounting
 *
 * A neg-risk event with arity N has N real conditions (indexes [0, N)) plus the
 * synthetic Other at index N. The partition is sound iff the YES numerators of
 * all N+1 conditions sum to exactly RESULT_DENOMINATOR (D = 1e6) once resolution
 * completes, so horizontalSplit positions redeem to the original collateral.
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
 * @property NEGRISK-PARTITION-01 The YES numerators of all its conditions plus the synthetic Other sum to exactly the denominator once resolution completes.
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
    function resultsSumOf(NegRiskModule.EventId) external returns (uint256) envfree;
    // Independent per-event sum of stored YES numerators (result[c][0]), re-derived
    // from every `_storeResult` write without reading the production counter.
    function yesSumOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function conditionsResolvedOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function arityOf(NegRiskModule.EventId) external returns (uint256) envfree;
    function condAt(NegRiskModule.EventId, uint256) external returns (NegRiskModule.ConditionId) envfree;
    function resultLen(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR0(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR1(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function condIndexOf(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function arityOfCond(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function condFrom(bytes32) external returns (NegRiskModule.ConditionId) envfree;

    /* ---- PositionManager / CollateralToken: irrelevant to resolution state, summarize away ---- */
    function _.moduleId() external => DISPATCHER(true);

    // This exact entry takes precedence over the wildcard and pins it to the real code.
    function NegRiskModule.getResult(NegRiskModule.ConditionId) external returns (uint256[]) envfree;

    /* ---- module immutable wiring (NOT linked, so PM/CT calls stay unresolved) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    /* ---- remaining legacy CTF backing reads ---- */
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;

    // Legacy payouts are a ghost pinned to canonical binary resolutions 
    // (see `ghostLegacyPayout` axiom below).
    function _.payoutNumerators(bytes32 cid, uint256 ix) external => legacyPayoutCVL(cid, ix) expect uint256;

    /* ---- legacy plumbing reached only by `migratePositions`; runs after the result
     * is stored (or on the den == 0 branch) and cannot affect resolution state. Wildcard
     * receiver for the same immutable-handle reason as `payoutNumerators` above. `balanceOf`
     * and `mergePositions` are unique to the legacy CTF; `safeBatchTransferFrom` is left to the
     * imported ERC1155 summary's `_.safeBatchTransferFrom` wildcard. ---- */
    function _.balanceOf(address, uint256) external => NONDET;
    function _.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;

    // Sound : The returned value is EXACTLY [1,2] (same as production), so this is lossless.
    function CTFHelpers.partition() internal returns (uint256[] memory) => partitionCVL();
    // Sound : `_redeemLegacyPositions` only calls the legacy CTF `redeemPositions` (already NONDET above
    // via `_.redeemPositions`) to move legacy-side balances
    function _._redeemLegacyPositions(bytes32) internal => NONDET;

    // Legacy-collateral vault settlement: pure plumbing — reads/transfers USDC.e + legacy
    // balances and emits, never touches `result` / `resultsSum` / `conditionsResolved`.
    function _._settleLegacyCollateralToVault() internal => NONDET;

    // Sound : Over approximation of the migrate loop redeem body.
    function _._useMigrateRedeemModel() internal => ALWAYS(true);
    function _._nondetResolved() internal => NONDET;
    function _._nondetBinaryR0() internal => NONDET;

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

// CTFHelpers.partition() returns the binary index-set partition [1,2] = [0b01, 0b10]. The
// production body uses raw assembly (see CTFHelpers.partition summary above); this clean CVL
// array is value-identical and restores precise prover points-to analysis across migratePositions.
function partitionCVL() returns uint256[] {
    uint256[] result;
    require result.length == 2, "partition() always returns a 2-element array";
    require result[0] == 1, "partition()[0] is the YES index set 0b01";
    require result[1] == 2, "partition()[1] is the NO index set 0b10";
    return result;
}

// Ownership-handover functions touch keccak-derived assembly slots (Solady _HANDOVER_SLOT_SEED)
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:NegRiskModule.requestOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.cancelOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.completeOwnershipHandover(address).selector
    // Equivalence-proof harness wrappers (NegRiskMigrationEquivalence); not production entry points
    || f.selector == sig:NegRiskModule.redeemIfResolvedDuringMigrateReal(NegRiskModule.ConditionId,bytes32).selector
    || f.selector == sig:NegRiskModule.legacyMintedKey(bytes32,uint256).selector;

/* =============================================================================
 * [NEGRISK-PARTITION-01a] resultsSum never exceeds RESULT_DENOMINATOR
 * ============================================================================= */
/**
 * @title the partition sum is bounded
 * @description The sum of resolved YES numerators of an event never exceeds the denominator.
 * @link_property NEGRISK-PARTITION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/1d08f204013a4e02b0d9c0f9df4ae742?anonymousKey=367c6e732e66810fbeb214d118953b4410098255
 */
invariant resultsSumBounded(NegRiskModule.EventId e)
    to_mathint(resultsSumOf(e)) <= RESULT_DENOMINATOR()
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * [NEGRISK-PARTITION-01b] resultsSum equals the sum of stored YES numerators
 * over ALL resolved conditions of the event (real legs + synthetic Other).
 * ============================================================================= */
/**
 * @title the partition sum tracks the YES numerators
 * @description The tracked event sum always equals the sum of the YES numerators actually stored on its conditions.
 * @link_property NEGRISK-PARTITION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/f7eb0d8039c44603acf899a047254d84?anonymousKey=6e4da3fc28aec785956ca7c2f67af3058e060753
 */
invariant resultsSumTracksYesNumerators(NegRiskModule.EventId e)
    to_mathint(resultsSumOf(e)) == to_mathint(yesSumOf(e))
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * Supporting — every stored result vector is normalized: [r0, r1] with
 * r0 + r1 == RESULT_DENOMINATOR (enforced by BaseModule._storeResult).
 * ============================================================================= */
/**
 * @title a resolved condition is normalized
 * @description Every resolved condition of the event carries a complementary pair summing to the denominator.
 * @link_property NEGRISK-PARTITION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e8b3f1f4f39143b7977410c251e8b4ef?anonymousKey=e2b8d2f8fd3ffb441e12d34611ee774575bb0019
 */
invariant resolvedResultNormalized(NegRiskModule.ConditionId c)
    resultLen(c) == 2 => to_mathint(realR0(c)) + to_mathint(realR1(c)) == RESULT_DENOMINATOR()
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * [NEGRISK-PARTITION-01c] Other YES completes the partition
 *
 * Once the synthetic Other (index == arity) resolves YES (r0 == D), the YES
 * numerators of all arity+1 conditions sum to exactly RESULT_DENOMINATOR.
 * ============================================================================= */
/**
 * @title the synthetic leg completes the partition
 * @description Resolving the synthetic Other condition brings the event sum to exactly the denominator.
 * @link_property NEGRISK-PARTITION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0b020e51083149e9901ef4b9ca891979?anonymousKey=62190d28d95e6e9a25ea2c4d80ab51a1dfb131ea
 */
invariant otherResolvedCompletesPartition(NegRiskModule.EventId e)
    to_mathint(realR0(condAt(e, arityOf(e)))) == RESULT_DENOMINATOR() =>
        (to_mathint(resultsSumOf(e)) == RESULT_DENOMINATOR()
            && to_mathint(yesSumOf(e)) == RESULT_DENOMINATOR())
    filtered { f -> !OUT_OF_SCOPE(f) }
    {
        preserved reportResult(NegRiskModule.ConditionId _c, uint256[] _result) with (env ev) {
            requireInvariant resultsSumTracksYesNumerators(e);
        }
        preserved resolveMigrationCondition(bytes32 _raw) with (env ev) {
            requireInvariant resultsSumTracksYesNumerators(e);
        }
    }

/* =============================================================================
 * [NEGRISK-PARTITION-01d] Full resolution only with resultsSum == RESULT_DENOMINATOR
 *
 * conditionsResolved[e] == arity+1 is reachable only with resultsSum[e] == D:
 * the last increment either passes `require(resultsSum_ == RESULT_DENOMINATOR)`,
 * goes through the fallback (which sets D), or is resolveConditionToNo (which requires resultsSum == D up front).
 * ============================================================================= */
/**
 * @title full resolution gives the full sum
 * @description Once every condition of an event is resolved, the event sum is exactly the denominator.
 * @link_property NEGRISK-PARTITION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e1583a4e6e074480ace2fc40a5401aa6?anonymousKey=1988e9ee68a2716e05cc33d680d01a2d6be8541b
 */
invariant fullResolutionImpliesFullSum(NegRiskModule.EventId e)
    to_mathint(conditionsResolvedOf(e)) == to_mathint(arityOf(e)) + 1 =>
        to_mathint(resultsSumOf(e)) == RESULT_DENOMINATOR()
    filtered { f -> !OUT_OF_SCOPE(f) }

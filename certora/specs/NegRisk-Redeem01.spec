/* =============================================================================
 * [REDEEM-01] — NegRiskModule: redeem pays floor(amount * result[c][outcomeIndex] / 1e6),
 *              bounded by amount, burns exactly the position from the module,
 *              and reverts on an unresolved condition or outcomeIndex >= 2.
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Position Lifecycle
 * @contract NegRiskModule
 * @impact A neg-risk operation could mint or burn the wrong outcome conditions, so an event would owe its holders more collateral than was ever paid into it
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 *
 * PROPERTIES
 * @property NEGRISK-REDEEM-01 NegRiskModule redeem pays the floor of the resolved payout, bounded by the amount, and reverts on an unresolved condition or an invalid outcome.
 */


import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using NegRiskRedeemHarness as NegRiskModule;
using PositionManager as PositionManager;
using DummyERC20Impl as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- harness view / derivation helpers (envfree, never revert) ---- */
    function resultLen(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR0(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function realR1(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function derivedLen(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function derivedR0(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function derivedR1(NegRiskModule.ConditionId) external returns (uint256) envfree;
    function pidOf(NegRiskModule.ConditionId, uint256) external returns (uint256) envfree;
    function pidObj(NegRiskModule.ConditionId, uint256) external returns (NegRiskModule.PositionId) envfree;

    /* ---- PositionManager / CollateralToken identity reads irrelevant to redeem ---- */
    function _.moduleId() external => DISPATCHER(true);

    // This exact entry takes precedence over the wildcard and pins it to the real code.
    function NegRiskModule.getResult(NegRiskModule.ConditionId) external returns (uint256[]) envfree;

    /* ---- module immutable wiring (NOT linked, so PM/CT calls hit the ghost summaries) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    /* ---- PositionManager position-token mint/burn -> ERC1155 ghost model.
     * burn is the redeem path under test (burns from the calling module) -> ghostBalance.
     * mint is only reached off-path but tracked per-account so the isolation rules have teeth.
     * batchMint / batchBurn are reached only by horizontal ops / bridge / migrate -> NONDET. ---- */
    function _.burn(uint256 id, uint256 amount) external with (env e) => pmBurnFromSenderCVL(e, id, amount) expect void;
    function _.mint(address to, uint256 id, uint256 amount) external => mintCVL(to, id, amount) expect void;
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external => NONDET;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external => NONDET;

    /* ---- CollateralToken (pUSD) mint/burn -> per-account ctBalance ghost.
     * mint is the redeem path under test (credits the recipient). burn is off-path but
     * tracked so a mutant that destroys collateral elsewhere is caught. ---- */
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_to, _amount) expect void;
    function _.burn(uint256 _amount) external with (env e) => ctBurnFromSenderCVL(e, _amount) expect void;

    /* ---- legacy CTF backing reads (invariant's migration branch only) ----
     * payoutNumerators intentionally NOT summarized: migration normalization preserves
     * the sum for arbitrary returned values (see ResultNorm01-NegRiskModule). ---- */
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;

    /* ---- OwnableRoles read + write wiring -> boolean ghosts ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

definition RESULT_DENOMINATOR() returns mathint = 1000000;

// Ownership-handover functions touch keccak-derived assembly slots the prover cannot
// separate from the `result` dynamic-array slots, so the write havocs result[c] and
// yields spurious CEXs.
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:NegRiskModule.requestOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.cancelOwnershipHandover().selector
    || f.selector == sig:NegRiskModule.completeOwnershipHandover(address).selector;

/* -----------------------------------------------------------------------------
 * Ghost summaries — PositionManager burn debits msg.sender (the module on the
 * redeem path); CollateralToken mint credits `_to`, burn debits msg.sender.
 * (Positions live in ghostBalance/ghostSupply from ERC1155.spec.)
 * --------------------------------------------------------------------------- */
function pmBurnFromSenderCVL(env e, uint256 id, uint256 amount) {
    burnByCVL(e.msg.sender, e.msg.sender, id, amount);
}

ghost mapping(address => mathint) ctBalance;

function ctMintCVL(address to, uint256 amount) {
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

function ctBurnFromSenderCVL(env e, uint256 amount) {
    if (ctBalance[e.msg.sender] < to_mathint(amount)) { revert(); }
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
}

/* =============================================================================
 * Normalization invariant (dependency of the payout bound).
 * Every stored result is empty or a length-2 vector summing to 1e6.
 * ============================================================================= */
/**
 * @title stored results are normalized, NegRiskModule redeem scene
 * @description Every stored result is a complementary pair summing to the result denominator.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
invariant resultNormalized(NegRiskModule.ConditionId c)
    resultLen(c) == 0
        || (resultLen(c) == 2 && realR0(c) + realR1(c) == RESULT_DENOMINATOR())
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * redeem — payout is the exact floor of the redemption formula
 * ============================================================================= */

/**
 * @title redeem pays the exact floor
 * @description A successful redeem mints exactly the floor of the amount scaled by the resolved numerator.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
rule redeemPaysExactFloor(env e, address to, NegRiskModule.ConditionId c, uint256 oi, uint256 amount) {
    // oi<2 = getPayout's valid outcomes; oi>=2 always reverts (proven in redeemRevertsOnBadOutcome), so no success path is dropped.
    require oi < 2, "restrict to valid outcomes; oi>=2 reverts, proven separately";

    requireInvariant resultNormalized(c);

    // getPayout now reads getResult, which can derive results
    // The expected payout must be computed from the same derived view, not the stored realR0/realR1.
    uint256 numU = oi == 0 ? derivedR0(c) : derivedR1(c);
    mathint expected = (to_mathint(amount) * to_mathint(numU)) / RESULT_DENOMINATOR();

    mathint before = ctBalance[to];

    redeem(e, to, pidObj(c, oi), amount);

    assert ctBalance[to] - before == expected, "redeem must mint exactly floor(amount * numerator / 1e6)";
}

/* =============================================================================
 * redeem — payout never exceeds the redeemed principal
 * ============================================================================= */

/**
 * @title redeem never overpays
 * @description For a resolved condition the payout never exceeds the redeemed amount.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
rule redeemPayoutNeverExceedsAmount(env e, address to, NegRiskModule.ConditionId c, uint256 oi, uint256 amount) {
    // resultNormalized is proven below (not assumed): r0+r1==1e6 => each numerator <= 1e6 => floor(amount*num/1e6) <= amount.
    requireInvariant resultNormalized(c);

    mathint before = ctBalance[to];

    redeem(e, to, pidObj(c, oi), amount);

    assert ctBalance[to] - before <= to_mathint(amount), "redeem payout must never exceed the redeemed amount";
}

/* =============================================================================
 * redeem — burns exactly `amount` of the position from the module
 * ============================================================================= */

/**
 * @title redeem burns the position exactly
 * @description A successful redeem burns exactly the redeemed amount from the module and lowers supply by the same.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
rule redeemBurnsPositionExactly(env e, address to, NegRiskModule.ConditionId c, uint256 oi, uint256 amount) {
    uint256 pid = pidOf(c, oi);

    mathint balBefore = ghostBalance[currentContract][pid];
    mathint supplyBefore = ghostSupply[pid];

    redeem(e, to, pidObj(c, oi), amount);

    assert ghostBalance[currentContract][pid] == balBefore - amount, "redeem must burn exactly `amount` from the module";
    assert ghostSupply[pid] == supplyBefore - amount, "redeem must reduce position supply by exactly `amount`";
}

/**
 * @title redeem burns only that position
 * @description A successful redeem touches no position balance other than the redeemed one.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
rule redeemBurnsOnlyThatPosition(
    env e, address to, NegRiskModule.ConditionId c, uint256 oi, uint256 amount, address acc, uint256 id
) {
    // Skip the single slot redeem legitimately burns; its exact delta is proven in redeemBurnsPositionExactly.
    require !(acc == currentContract && id == pidOf(c, oi)), "exclude the burned slot; its exact change is proven separately";

    mathint before = ghostBalance[acc][id];

    redeem(e, to, pidObj(c, oi), amount);

    assert ghostBalance[acc][id] == before, "redeem must not move any other position balance";
}

/* =============================================================================
 * redeem — collateral isolation
 * ============================================================================= */

/**
 * @title redeem mints only recipient collateral
 * @description A successful redeem changes no collateral balance other than the recipient's.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
rule redeemMintsOnlyRecipientCollateral(
    env e, address to, NegRiskModule.ConditionId c, uint256 oi, uint256 amount, address a
) {
    // Skip the paid recipient; its exact credit is proven in redeemPaysExactFloor. Every other account must be untouched.
    require a != to, "exclude the paid recipient; its exact credit is proven separately";

    mathint before = ctBalance[a];

    redeem(e, to, pidObj(c, oi), amount);

    assert ctBalance[a] == before, "redeem must credit only the recipient's collateral";
}

/* =============================================================================
 * redeem — revert conditions
 * ============================================================================= */

/**
 * @title redeem reverts when unresolved
 * @description redeem reverts when the condition has no stored result.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
rule redeemRevertsWhenUnresolved(env e, address to, NegRiskModule.ConditionId c, uint256 oi, uint256 amount) {
    requireInvariant resultNormalized(c);

    // Defines the unresolved scenario (not an input assumption). 
    require derivedLen(c) != 2, "unresolved case: no stored AND no derivable result, the exact case getPayout rejects";

    redeem@withrevert(e, to, pidObj(c, oi), amount);

    assert lastReverted, "redeem must revert on an unresolved condition";
}

/**
 * @title redeem reverts on a bad outcome
 * @description redeem reverts when the outcome index is out of range.
 * @link_property NEGRISK-REDEEM-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9eded9a82d62466d8a7e49cdb1af4051?anonymousKey=d88099065752aa5d26bdf4e0b3ad4176c175a8cd
 */
rule redeemRevertsOnBadOutcome(env e, address to, NegRiskModule.ConditionId c, uint256 oi, uint256 amount) {
    // [2,255] is the full invalid-outcome range: the outcome field is 8 bits, so this covers every value getPayout rejects (<2 required).
    require oi >= 2 && oi <= 255, "full 8-bit invalid-outcome range; getPayout requires outcomeIndex < 2";

    redeem@withrevert(e, to, pidObj(c, oi), amount);

    assert lastReverted, "redeem must revert when outcomeIndex >= 2";
}

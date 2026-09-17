/* =============================================================================
 * [NEGRISK-CONVERT-01] convert burns one NO(i) and mints one YES(j) for every
 * j != i across the arity+1 conditions, conserving notional.
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Position Lifecycle
 * @contract NegRiskModule
 * @impact A neg-risk operation could mint or burn the wrong outcome conditions, so an event would owe its holders more collateral than was ever paid into it
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 * PROPERTIES
 * @property NEGRISK-CONVERT-01 convert burns one NO leg and mints a YES leg for every other condition of the event, conserving notional.
 */


import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";
import "summaries/Solady/ERC1155.spec";
import "summaries/CTFHelpers_summaries.spec";
import "summaries/Solady/SafeTransferLib.spec";

using NegRiskModuleHarness as NegRiskModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;
using DummyERC20Impl as Wcol;

methods {
    /* ---- harness pure helpers (envfree) ---- */
    function pidOf(NegRiskModule.ConditionId, uint256) external returns (uint256) envfree;
    function condAt(NegRiskModule.EventId, uint256) external returns (NegRiskModule.ConditionId) envfree;
    function arityOf(NegRiskModule.EventId) external returns (uint256) envfree;

    /* ---- legacy id derivation -> NONDET (feeds only legacy lookups, never the convert path) ---- */
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;

    /* ---- PositionManager position-token mint/burn ----
     * single mint (per other-YES leg) and single burn (NO(i)) are the convert path -> ghost.
     * batchMint / batchBurn are off the convert path -> NONDET. */
    function _.mint(address to, uint256 id, uint256 amount) external => mintCVL(to, id, amount) expect void;
    function _.burn(uint256 id, uint256 amount) external with (env e) => pmBurnFromSenderCVL(e, id, amount) expect void;
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external => NONDET;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external => NONDET;

    /* ---- CollateralToken (pUSD) mint/burn -> per-account ctBalance ghost ---- */
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_to, _amount) expect void;
    function _.burn(uint256 _amount) external with (env e) => ctBurnFromSenderCVL(e, _amount) expect void;

    // wrap/unwrap are unreachable from the convert path; NONDET removes their storage-split failures.
    function _.wrap(address _asset, address _to, uint256 _amount) external => NONDET;
    function _.unwrap(address _asset, address _to, uint256 _amount) external => NONDET;

    /* ---- OwnableRoles read + write wiring -> boolean ghosts ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

links {
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;
    NegRiskModule.WRAPPED_COLLATERAL_TOKEN => Wcol;
}

/* -----------------------------------------------------------------------------
 * Collateral-balance ghost — pUSD per account. Convert must never move it.
 * --------------------------------------------------------------------------- */
ghost mapping(address => mathint) ctBalance;

function ctMintCVL(address to, uint256 amount) {
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

function ctBurnFromSenderCVL(env e, uint256 amount) {
    if (ctBalance[e.msg.sender] < to_mathint(amount)) { revert(); }
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
}

/* PositionManager single burn — burns from msg.sender (the module). */
function pmBurnFromSenderCVL(env e, uint256 id, uint256 amount) {
    burnByCVL(e.msg.sender, e.msg.sender, id, amount);
}

/* =============================================================================
 * convert — YES minting exactness
 * ============================================================================= */

/**
 * @title convert mints every other YES exactly
 * @description Every other-condition YES leg of the event is credited exactly the converted amount to the recipient.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertMintsEachOtherYesExactly(
    env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount, uint256 j
) {
    require j <= arityOf(ev), "j is a real leg index in [0,arity]";
    require j != i, "targets the other legs";

    uint256 yesJ = pidOf(condAt(ev, j), 0);
    mathint before = ghostBalance[to][yesJ];

    convert(e, to, ev, i, amount);

    assert ghostBalance[to][yesJ] == before + amount;
}

/**
 * @title convert skips the source YES
 * @description The source condition's own YES leg is never minted.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertSkipsSourceYes(env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount) {
    uint256 yesI = pidOf(condAt(ev, i), 0);
    mathint before = ghostBalance[to][yesI];

    convert(e, to, ev, i, amount);

    assert ghostBalance[to][yesI] == before;
}

/* =============================================================================
 * convert — NO burn exactness
 * ============================================================================= */

/**
 * @title convert burns the source NO exactly
 * @description Exactly the converted amount of the source NO leg is burned from the module.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertBurnsSourceNoExactly(env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount) {
    uint256 noI = pidOf(condAt(ev, i), 1);
    mathint before = ghostBalance[currentContract][noI];

    convert(e, to, ev, i, amount);

    assert ghostBalance[currentContract][noI] == before - amount;
}

/* =============================================================================
 * convert — no pUSD is minted or burned
 * ============================================================================= */
/**
 * @title convert moves no collateral
 * @description convert changes no collateral balance and no collateral supply.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertNoCollateralChange(env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount, address a) {
    mathint before = ctBalance[a];

    convert(e, to, ev, i, amount);

    assert ctBalance[a] == before, "convert mints/burns no collateral";
}

/* =============================================================================
 * convert — isolation
 * ============================================================================= */

/**
 * @title convert touches no other NO leg
 * @description Only the source NO leg is burned; any other condition's NO leg is untouched.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertDoesNotTouchOtherNo(
    env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount, uint256 j
) {
    require j <= arityOf(ev), "j is a real leg index in [0,arity]";
    require j != i, "targets the other legs";

    uint256 noJ = pidOf(condAt(ev, j), 1);
    mathint before = ghostBalance[currentContract][noJ];

    convert(e, to, ev, i, amount);

    assert ghostBalance[currentContract][noJ] == before;
}

/**
 * @title convert stops at the synthetic leg
 * @description The YES basket stops at the synthetic Other condition; the leg one past it is untouched.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertDoesNotTouchBeyondOther(env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount) {
    uint256 beyond = pidOf(condAt(ev, require_uint256(arityOf(ev) + 1)), 0);
    mathint before = ghostBalance[to][beyond];

    convert(e, to, ev, i, amount);

    assert ghostBalance[to][beyond] == before;
}

/**
 * @title convert credits only the recipient
 * @description Only the named recipient is credited the YES legs.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertCreditsOnlyRecipient(
    env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount, uint256 j, address acc
) {
    require acc != to, "checks every non-recipient account is untouched";

    uint256 yesJ = pidOf(condAt(ev, j), 0);
    mathint before = ghostBalance[acc][yesJ];

    convert(e, to, ev, i, amount);

    assert ghostBalance[acc][yesJ] == before;
}

/**
 * @title convert conserves notional
 * @description Total YES supply rises by the amount per other leg while the source NO supply falls by the amount.
 * @link_property NEGRISK-CONVERT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/70c139679a504b738069a9ededd16b33?anonymousKey=f8e7af4141bc1b8f8adbbb11d3e25f4e88171576
 */
rule convertConservesSupply(env e, address to, NegRiskModule.EventId ev, uint256 i, uint256 amount, uint256 j) {
    require j <= arityOf(ev), "j is a real leg index in [0,arity]";
    require j != i, "targets the other legs";

    uint256 yesJ = pidOf(condAt(ev, j), 0);
    uint256 noI  = pidOf(condAt(ev, i), 1);
    mathint yesBefore = ghostSupply[yesJ];
    mathint noBefore  = ghostSupply[noI];

    convert(e, to, ev, i, amount);

    assert ghostSupply[yesJ] == yesBefore + amount;
    assert ghostSupply[noI]  == noBefore  - amount;
}
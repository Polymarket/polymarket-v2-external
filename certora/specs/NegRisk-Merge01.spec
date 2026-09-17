/* =============================================================================
 * MERGE-01 — merge is the exact inverse of split (NegRiskModule).
 *
 *   merge(_to, _conditionId, _amount):
 *     - burns exactly `_amount` of the YES position (outcome 0) held by the module,
 *     - burns exactly `_amount` of the NO  position (outcome 1) held by the module,
 *     - mints exactly `_amount` pUSD to `_to`,
 *     - touches no other position balance and no other account's collateral.
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
 * @property NEGRISK-MERGE-01 NegRiskModule merge is the exact inverse of split.
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
    function pidUnwrap(NegRiskModule.PositionId) external returns (uint256) envfree;

    /* ---- legacy id derivation -> NONDET (feeds only legacy lookups, never the merge path) ---- */
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;

    /* ---- PositionManager position-token mint/burn ----
     * burn is the merge path under test (burns from the calling module) -> per-account ghostBalance.
     * mint is reached only by split/bridge on the legit path, but is tracked per-account too so the
     * position-isolation rule has teeth against a mutant that mints positions elsewhere.
     * batchMint / batchBurn are reached only by bridge/migrate -> NONDET. */
    function _.burn(uint256 id, uint256 amount) external with (env e) => pmBurnFromSenderCVL(e, id, amount) expect void;
    function _.mint(address to, uint256 id, uint256 amount) external => mintCVL(to, id, amount) expect void;
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external => NONDET;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external => NONDET;

    /* ---- CollateralToken (pUSD) mint/burn ----
     * mint is the merge path under test (mints to the recipient) -> per-account ctBalance.
     * burn is reached only by split on the legit path, but is tracked per-account too so the
     * collateral-isolation rule has teeth against a mutant that burns collateral elsewhere. */
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_to, _amount) expect void;
    function _.burn(uint256 _amount) external with (env e) => ctBurnFromSenderCVL(e, _amount) expect void;

    // wrap/unwrap are unreachable from the merge path; NONDET removes their storage-split failures.
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

// PositionManager and CollateralToken intentionally NOT linked (so the per-account mint/burn
// ghost summaries fire). CONDITIONAL_TOKENS + WRAPPED_COLLATERAL_TOKEN linked so the harness
// constructor's immutable wiring resolves.
links {
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;
    NegRiskModule.WRAPPED_COLLATERAL_TOKEN => Wcol;
}

/* -----------------------------------------------------------------------------
 * PositionManager position-balance burn — burns from msg.sender.
 * PositionManager.burn(id, amount) burns from msg.sender, which on the merge path
 * is the module (currentContract). burnByCVL (by == from) reverts on insufficient
 * balance, mirroring the real ERC1155 burn.
 * --------------------------------------------------------------------------- */
function pmBurnFromSenderCVL(env e, uint256 id, uint256 amount) {
    burnByCVL(e.msg.sender, e.msg.sender, id, amount);
}

/* -----------------------------------------------------------------------------
 * Collateral-balance ghost — pUSD per account.
 * CollateralToken.mint(to, amount) credits `to`, which on the merge path is the
 * recipient `_to`. burn(amount) burns from msg.sender, tracked per-account so the
 * collateral-isolation rule catches a mutant that destroys collateral elsewhere.
 * --------------------------------------------------------------------------- */
ghost mapping(address => mathint) ctBalance;

function ctMintCVL(address to, uint256 amount) {
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

function ctBurnFromSenderCVL(env e, uint256 amount) {
    if (ctBalance[e.msg.sender] < to_mathint(amount)) { revert(); }
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
}

/* =============================================================================
 * merge — YES/NO burn exactness
 * ============================================================================= */

/**
 * @title merge burns YES and NO exactly
 * @description A successful merge burns exactly the requested amount of the YES and NO positions from the module.
 * @link_property NEGRISK-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/725ab21e4c764c4dba52d153ae12f3be?anonymousKey=48e04739423b75287b39bc6891a8be6cb38ee4dd
 */
rule mergeBurnsYesAndNoExactly(env e, address to, NegRiskModule.ConditionId c, uint256 amount) {
    uint256 yesId = pidOf(c, 0);
    uint256 noId = pidOf(c, 1);

    mathint yesBefore = ghostBalance[currentContract][yesId];
    mathint noBefore = ghostBalance[currentContract][noId];

    merge(e, to, c, amount);

    assert ghostBalance[currentContract][yesId] == yesBefore - amount;
    assert ghostBalance[currentContract][noId] == noBefore - amount;
}

/* =============================================================================
 * merge — collateral mint exactness
 * ============================================================================= */

/**
 * @title merge mints collateral exactly
 * @description A successful merge mints exactly the requested amount of pUSD to the recipient.
 * @link_property NEGRISK-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/725ab21e4c764c4dba52d153ae12f3be?anonymousKey=48e04739423b75287b39bc6891a8be6cb38ee4dd
 */
rule mergeMintsCollateralExactly(env e, address to, NegRiskModule.ConditionId c, uint256 amount) {
    mathint before = ctBalance[to];

    merge(e, to, c, amount);

    assert ctBalance[to] == before + amount;
}

/**
 * @title merge mints only recipient collateral
 * @description A successful merge changes no collateral balance other than the recipient's.
 * @link_property NEGRISK-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/725ab21e4c764c4dba52d153ae12f3be?anonymousKey=48e04739423b75287b39bc6891a8be6cb38ee4dd
 */
rule mergeMintsOnlyRecipientCollateral(env e, address to, NegRiskModule.ConditionId c, uint256 amount, address a) {
    require a != to;

    mathint before = ctBalance[a];

    merge(e, to, c, amount);

    assert ctBalance[a] == before;
}

/* =============================================================================
 * merge — position isolation
 * ============================================================================= */

/**
 * @title merge burns only module positions
 * @description A successful merge touches no position balance other than the two legs held by the module.
 * @link_property NEGRISK-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/725ab21e4c764c4dba52d153ae12f3be?anonymousKey=48e04739423b75287b39bc6891a8be6cb38ee4dd
 */
rule mergeBurnsOnlyModulePositions(env e,address to,NegRiskModule.ConditionId c,uint256 amount,address acc,uint256 id) {
    require !(acc == currentContract && id == pidOf(c, 0));
    require !(acc == currentContract && id == pidOf(c, 1));

    mathint before = ghostBalance[acc][id];

    merge(e, to, c, amount);

    assert ghostBalance[acc][id] == before;
}

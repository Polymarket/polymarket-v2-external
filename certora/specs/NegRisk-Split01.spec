/* =============================================================================
 * SPLIT-01 — split mints equal YES/NO and burns exactly the pre-transferred
 * collateral.
 *
 *   split(_to, _conditionId, _amount):
 *     - mints exactly `_amount` of the YES position (outcome 0) to `_to[0]`,
 *     - mints exactly `_amount` of the NO  position (outcome 1) to `_to[1]`,
 *     - burns exactly `_amount` pUSD from the module's OWN collateral balance,
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
 * @property NEGRISK-SPLIT-01 NegRiskModule split mints equal YES and NO and burns exactly the pre-transferred collateral.
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

    /* ---- legacy id derivation -> NONDET (feeds only legacy lookups, never the split path) ---- */
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;

    /* ---- PositionManager position-token mint/burn ----
     * mint is the split path under test -> per-account ghostBalance.
     * burn / batchMint / batchBurn are reached only by merge/redeem/horizontal/bridge/migrate -> NONDET. */
    function _.mint(address to, uint256 id, uint256 amount) external => mintCVL(to, id, amount) expect void;
    function _.burn(uint256 id, uint256 amount) external => NONDET;
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external => NONDET;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external => NONDET;

    /* ---- CollateralToken (pUSD) mint/burn ----
     * burn is the split path under test (burns from the calling module) -> per-account ctBalance.
     * mint is reached only by merge/redeem on the legit path, but is tracked per-account too so the
     * collateral-isolation rule has teeth against a mutant that redirects collateral elsewhere. */
    function _.burn(uint256 _amount) external with (env e) => ctBurnFromSenderCVL(e, _amount) expect void;
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_to, _amount) expect void;

    // wrap/unwrap are unreachable from the split path; NONDET removes their storage-split failures.
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
 * Collateral-balance ghost — pUSD per account.
 * CollateralToken.burn(amount) burns from msg.sender, which on the split path is
 * the module (currentContract). burnFromSender reverts on insufficient balance,
 * mirroring the real ERC20 burn.
 * --------------------------------------------------------------------------- */
ghost mapping(address => mathint) ctBalance;

function ctBurnFromSenderCVL(env e, uint256 amount) {
    if (ctBalance[e.msg.sender] < to_mathint(amount)) { revert(); }
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
}

// CollateralToken.mint credits `to`. Never called on the legit split path, but tracking it
// per-account lets splitBurnsOnlyModuleCollateral catch a mutant that mints collateral away.
function ctMintCVL(address to, uint256 amount) {
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

/* =============================================================================
 * split — YES/NO mint exactness
 * ============================================================================= */

/**
 * @title split mints YES and NO exactly
 * @description A successful split credits each recipient by exactly the requested amount of the YES and NO positions.
 * @link_property NEGRISK-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/ee6f2a0dbdfa466a9dfa0f3962015de1?anonymousKey=3a73c632c1c9b3ebec1dfcdc4ec8690c98ac4b21
 */
rule splitMintsYesAndNoExactly(env e, address[] to, NegRiskModule.ConditionId c, uint256 amount) {
    uint256 yesId = pidOf(c, 0);
    uint256 noId = pidOf(c, 1);
    mathint yesBefore = ghostBalance[to[0]][yesId];
    mathint noBefore = ghostBalance[to[1]][noId];

    split(e, to, c, amount);

    assert ghostBalance[to[0]][yesId] == yesBefore + amount;
    assert ghostBalance[to[1]][noId] == noBefore + amount;

}

/* =============================================================================
 * split — collateral burn exactness
 * ============================================================================= */

/**
 * @title split burns collateral exactly
 * @description A successful split burns exactly the requested amount of pUSD from the module's own balance.
 * @link_property NEGRISK-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/ee6f2a0dbdfa466a9dfa0f3962015de1?anonymousKey=3a73c632c1c9b3ebec1dfcdc4ec8690c98ac4b21
 */
rule splitBurnsCollateralExactly(env e, address[] to, NegRiskModule.ConditionId c, uint256 amount) {
    mathint before = ctBalance[currentContract];

    split(e, to, c, amount);

    assert ctBalance[currentContract] == before - amount;
}

/**
 * @title split burns only module collateral
 * @description A successful split changes no collateral balance other than the module's.
 * @link_property NEGRISK-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/ee6f2a0dbdfa466a9dfa0f3962015de1?anonymousKey=3a73c632c1c9b3ebec1dfcdc4ec8690c98ac4b21
 */
rule splitBurnsOnlyModuleCollateral(env e, address[] to, NegRiskModule.ConditionId c, uint256 amount, address a) {
    require a != currentContract;

    mathint before = ctBalance[a];

    split(e, to, c, amount);

    assert ctBalance[a] == before;
}

/* =============================================================================
 * split — position isolation
 * ============================================================================= */

/**
 * @title split touches only the split positions
 * @description A successful split touches no position balance other than the two it credits.
 * @link_property NEGRISK-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/ee6f2a0dbdfa466a9dfa0f3962015de1?anonymousKey=3a73c632c1c9b3ebec1dfcdc4ec8690c98ac4b21
 */
rule splitTouchesOnlySplitPositions(env e,address[] to,NegRiskModule.ConditionId c,uint256 amount,address acc,uint256 id) {
    require !(acc == to[0] && id == pidOf(c, 0));
    require !(acc == to[1] && id == pidOf(c, 1));

    mathint before = ghostBalance[acc][id];

    split(e, to, c, amount);

    assert ghostBalance[acc][id] == before;
}

/* =============================================================================
 * SPLIT-01 — split mints equal YES/NO and burns exactly the pre-transferred collateral (BinaryModule).
 *
 *   split(_to, _conditionId, _amount):
 *     - mints exactly `_amount` of the YES position (outcome 0) to `_to[0]`,
 *     - mints exactly `_amount` of the NO  position (outcome 1) to `_to[1]`,
 *     - burns exactly `_amount` pUSD from the module's OWN collateral balance,
 *     - touches no other position balance and no other account's collateral.
 *
 * ============================================================================= */

/*
 * MODULE
 * @module BinaryModule Position Lifecycle
 * @contract BinaryModule
 * @impact split, merge or redeem could mint or burn the wrong amounts, letting a user withdraw more collateral than they put in
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 *
 * PROPERTIES
 * @property BINARY-SPLIT-01 BinaryModule split mints equal YES and NO and burns exactly the pre-transferred collateral.
 */


import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";
import "summaries/Solady/ERC1155.spec";

using BinaryModuleHarness as BinaryModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- harness pure helpers (envfree) ---- */
    function pidOf(BinaryModule.ConditionId, uint256) external returns (uint256) envfree;
    function pidUnwrap(BinaryModule.PositionId) external returns (uint256) envfree;

    /* ---- module immutable wiring ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    /* ---- legacy CTF migration calls -> NONDET ----
     * Reached only by the migration / resolution methods, which the prover still builds. */
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;
    function _.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;

    /* ---- PositionManager position-token mint/burn ----
     * mint is the split path under test -> per-account ghostBalance.
     * burn / batchMint / batchBurn are reached only by merge/redeem/bridge/migrate -> NONDET. */
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

    /* ---- OwnableRoles read + write wiring -> boolean ghosts ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// CONDITIONAL_TOKENS linked so the harness constructor's immutable wiring resolves; PM and
// CollateralToken stay summarized (NOT linked) so the per-account mint/burn ghost summaries fire.
links {
    BinaryModule.CONDITIONAL_TOKENS => ConditionalTokens;
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
 * @link_property BINARY-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8adb96fdc07a469f99ece2ef21d74bb2?anonymousKey=07e63dd456d6a65ba5a6ef439eba45b5210efc57
 */
rule splitMintsYesAndNoExactly(env e, address[] to, BinaryModule.ConditionId c, uint256 amount) {
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
 * @link_property BINARY-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8adb96fdc07a469f99ece2ef21d74bb2?anonymousKey=07e63dd456d6a65ba5a6ef439eba45b5210efc57
 */
rule splitBurnsCollateralExactly(env e, address[] to, BinaryModule.ConditionId c, uint256 amount) {
    mathint before = ctBalance[currentContract];

    split(e, to, c, amount);

    assert ctBalance[currentContract] == before - amount;
}

/**
 * @title split burns only module collateral
 * @description A successful split changes no collateral balance other than the module's.
 * @link_property BINARY-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8adb96fdc07a469f99ece2ef21d74bb2?anonymousKey=07e63dd456d6a65ba5a6ef439eba45b5210efc57
 */
rule splitBurnsOnlyModuleCollateral(env e, address[] to, BinaryModule.ConditionId c, uint256 amount, address a) {
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
 * @link_property BINARY-SPLIT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/8adb96fdc07a469f99ece2ef21d74bb2?anonymousKey=07e63dd456d6a65ba5a6ef439eba45b5210efc57
 */
rule splitTouchesOnlySplitPositions(env e,address[] to,BinaryModule.ConditionId c,uint256 amount,address acc,uint256 id) {
    require !(acc == to[0] && id == pidOf(c, 0));
    require !(acc == to[1] && id == pidOf(c, 1));

    mathint before = ghostBalance[acc][id];

    split(e, to, c, amount);

    assert ghostBalance[acc][id] == before;
}

/* =============================================================================
 * MERGE-01 — merge is the exact inverse of split (BinaryModule).
 *
 *   merge(_to, _conditionId, _amount):
 *     - burns exactly `_amount` of the YES position (outcome 0) held by the module,
 *     - burns exactly `_amount` of the NO  position (outcome 1) held by the module,
 *     - mints exactly `_amount` pUSD to `_to`,
 *     - touches no other position balance and no other account's collateral.
 * ============================================================================= */

/*
 * MODULE
 * @module BinaryModule Position Lifecycle
 * @contract BinaryModule
 * @impact split, merge or redeem could mint or burn the wrong amounts, letting a user withdraw more collateral than they put in
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 * PROPERTIES
 * @property BINARY-MERGE-01 BinaryModule merge is the exact inverse of split.
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
    function pidObj(BinaryModule.ConditionId, uint256) external returns (BinaryModule.PositionId) envfree;
    function pidUnwrap(BinaryModule.PositionId) external returns (uint256) envfree;

    /* ---- module immutable wiring ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    // ---- legacy CTF migration calls -> NONDET ----
    // Reached only by the migration / resolution methods, which the prover still builds.
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;
    function _.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;

    // PositionManager position-token mint/burn (needed due to solady assembly).
    function _.burn(uint256 id, uint256 amount) external with (env e) => pmBurnFromSenderCVL(e, id, amount) expect void;
    function _.mint(address to, uint256 id, uint256 amount) external => mintCVL(to, id, amount) expect void;
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external => NONDET;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external => NONDET;
    // User pre-transfers each split leg to the module before merge.
    function PositionManager.unsafeTransferFrom(
        address from, address to, PositionManager.PositionId id, uint256 amount
    ) external with (env e) => erc1155SafeTransferFromCVL(e, from, to, id, amount);

    // CollateralToken (pUSD) mint/burn (needed due to solady assembly).
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_to, _amount) expect void;
    function _.burn(uint256 _amount) external with (env e) => ctBurnFromSenderCVL(e, _amount) expect void;
    // User pre-funds the module before split.
    function CollateralToken.transfer(address to, uint256 amount) external returns (bool) with (env e) =>
        ctTransferCVL(e, to, amount);

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

// PositionManager position-balance burn — burns from msg.sender.
function pmBurnFromSenderCVL(env e, uint256 id, uint256 amount) {
    burnByCVL(e.msg.sender, e.msg.sender, id, amount);
}

// Collateral-balance ghost — pUSD per account.
ghost mapping(address => mathint) ctBalance;

function ctMintCVL(address to, uint256 amount) {
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

function ctBurnFromSenderCVL(env e, uint256 amount) {
    if (ctBalance[e.msg.sender] < to_mathint(amount)) { revert(); }
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
}

function ctTransferCVL(env e, address to, uint256 amount) returns bool {
    if (to == 0 || ctBalance[e.msg.sender] < to_mathint(amount)) { revert(); }
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
    return true;
}

/* =============================================================================
 * merge — YES/NO burn exactness
 * ============================================================================= */

/**
 * @title merge burns YES and NO exactly
 * @description A successful merge burns exactly the requested amount of the YES and NO positions from the module.
 * @link_property BINARY-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/99f35b71fdde41988c55ed4cda257b2a?anonymousKey=2028f95f12963d57f404be758dbb0b7fecc30819
 */
rule mergeBurnsYesAndNoExactly(env e, address to, BinaryModule.ConditionId c, uint256 amount) {
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
 * @link_property BINARY-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/99f35b71fdde41988c55ed4cda257b2a?anonymousKey=2028f95f12963d57f404be758dbb0b7fecc30819
 */
rule mergeMintsCollateralExactly(env e, address to, BinaryModule.ConditionId c, uint256 amount) {
    mathint before = ctBalance[to];

    merge(e, to, c, amount);

    assert ctBalance[to] == before + amount;
}

/**
 * @title merge mints only recipient collateral
 * @description A successful merge changes no collateral balance other than the recipient's.
 * @link_property BINARY-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/99f35b71fdde41988c55ed4cda257b2a?anonymousKey=2028f95f12963d57f404be758dbb0b7fecc30819
 */
rule mergeMintsOnlyRecipientCollateral(env e, address to, BinaryModule.ConditionId c, uint256 amount, address a) {
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
 * @link_property BINARY-MERGE-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/99f35b71fdde41988c55ed4cda257b2a?anonymousKey=2028f95f12963d57f404be758dbb0b7fecc30819
 */
rule mergeBurnsOnlyModulePositions(env e,address to,BinaryModule.ConditionId c,uint256 amount,address acc,uint256 id) {
    require !(acc == currentContract && id == pidOf(c, 0));
    require !(acc == currentContract && id == pidOf(c, 1));

    mathint before = ghostBalance[acc][id];

    merge(e, to, c, amount);

    assert ghostBalance[acc][id] == before;
}

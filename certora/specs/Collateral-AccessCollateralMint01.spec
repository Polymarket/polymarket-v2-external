/* =============================================================================
 * ACCESS-COLLATERAL-MINT-01 — Only MINTER_ROLE can change pUSD totalSupply via
 * mint/burn; only WRAPPER_ROLE (on a valid asset) via wrap/unwrap.
 * ============================================================================= */

/*
 * MODULE
 * @module CollateralToken Supply Access Control
 * @contract CollateralToken
 * @impact An unauthorized caller could change pUSD supply, inflating the collateral token
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property ACCESS-COLLATERAL-MINT-01 Only the minter role can change pUSD supply through mint and burn, and only the wrapper role on a valid asset through wrap and unwrap.
 * @property ACCESS-COLLATERAL-RESCUE-01 Only the owner can rescue ERC20 tokens held by the collateral token.
 */


import "summaries/Solady/SafeTransferLib.spec";
import "summaries/Solady/OwnableRoles.spec";

using CollateralToken as CollateralToken;

methods {
    function totalSupply() external returns (uint256) envfree;
    function owner() external returns (address) envfree;

    /* ---- immutable wiring (valid-asset set) ---- */
    function USDC() external returns (address) envfree;
    function USDCE() external returns (address) envfree;

    /* ---- OwnableRoles read/write wiring -> boolean ghosts ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// The functions allowed to change totalSupply, keyed by required role.
definition isMintBurn(method f) returns bool =
    f.selector == sig:mint(address, uint256).selector || f.selector == sig:burn(uint256).selector;

definition isWrapUnwrap(method f) returns bool =
    f.selector == sig:wrap(address, address, uint256).selector
        || f.selector == sig:unwrap(address, address, uint256).selector
        || f.selector == sig:wrap(address, address, uint256, address, bytes).selector
        || f.selector == sig:unwrap(address, address, uint256, address, bytes).selector;

// A supported asset is exactly USDC or USDC.e (mirrors onlyValidAsset).
definition validAsset(address a) returns bool = a == USDC() || a == USDCE();

// Role reads against the OwnableRoles ghost model (bit 0 = MINTER, bit 1 = WRAPPER).
function hasMinterRole(address user) returns bool {
    return ghostHasRole0[CollateralToken][user];
}

function hasWrapperRole(address user) returns bool {
    return ghostHasRole1[CollateralToken][user];
}

/* =============================================================================
 * R1 — No function outside {mint, burn, wrap, unwrap} changes totalSupply.
 * ============================================================================= */

/**
 * @title only the supply mutators move pUSD supply
 * @description No method other than mint, burn, wrap and unwrap changes the pUSD total supply.
 * @link_property ACCESS-COLLATERAL-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule onlySupplyMutators(method f)
    filtered {
        f -> f.selector != sig:upgradeToAndCall(address, bytes).selector // owner trusted escape hatch
              && f.selector != sig:permit(address, address, uint256, uint256, uint8, bytes32, bytes32).selector // prover problem when modeling
    }
{
    env e;
    calldataarg args;

    uint256 supplyBefore = totalSupply();
    f(e, args);

    assert totalSupply() != supplyBefore => isMintBurn(f) || isWrapUnwrap(f), "totalSupply changed by a function outside mint/burn/wrap/unwrap";
}

/* =============================================================================
 * R2 — A supply change through a mutator requires the matching role.
 * ============================================================================= */

/**
 * @title a supply change requires a role
 * @description Any change to pUSD total supply requires the caller to hold the minter or wrapper role.
 * @link_property ACCESS-COLLATERAL-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule supplyChangeRequiresRole(method f) filtered { f -> isMintBurn(f) || isWrapUnwrap(f) } {
    env e;
    calldataarg args;

    // Read roles BEFORE the call; none of the four mutators changes roles.
    bool minterBefore = hasMinterRole(e.msg.sender);
    bool wrapperBefore = hasWrapperRole(e.msg.sender);

    uint256 supplyBefore = totalSupply();
    f(e, args);

    assert totalSupply() != supplyBefore => (isMintBurn(f) ? minterBefore : wrapperBefore), "totalSupply changed by a caller without the required role";
}

/* =============================================================================
 * R3 — mint/burn revert without MINTER_ROLE.
 * ============================================================================= */

/**
 * @title mint requires the minter role
 * @description mint reverts for a caller without the minter role.
 * @link_property ACCESS-COLLATERAL-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule mintRevertsWithoutMinterRole(env e, address to, uint256 amount) {
    bool authorized = hasMinterRole(e.msg.sender);

    mint@withrevert(e, to, amount);

    assert !authorized => lastReverted, "mint succeeded without MINTER_ROLE";
}

/**
 * @title burn requires the minter role
 * @description burn reverts for a caller without the minter role.
 * @link_property ACCESS-COLLATERAL-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule burnRevertsWithoutMinterRole(env e, uint256 amount) {
    bool authorized = hasMinterRole(e.msg.sender);

    burn@withrevert(e, amount);

    assert !authorized => lastReverted, "burn succeeded without MINTER_ROLE";
}

/* =============================================================================
 * R4 — wrap/unwrap revert without WRAPPER_ROLE or with an invalid asset.
 * ============================================================================= */

/**
 * @title wrap requires the wrapper role and a valid asset
 * @description wrap reverts for a caller without the wrapper role or for an asset that is not accepted.
 * @link_property ACCESS-COLLATERAL-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule wrapRevertsWithoutWrapperRoleOrInvalidAsset(env e, address asset, address to, uint256 amount) {
    bool authorized = hasWrapperRole(e.msg.sender) && validAsset(asset);

    wrap@withrevert(e, asset, to, amount);

    assert !authorized => lastReverted, "wrap succeeded without WRAPPER_ROLE or with an invalid asset";
}

/**
 * @title unwrap requires the wrapper role and a valid asset
 * @description unwrap reverts for a caller without the wrapper role or for an asset that is not accepted.
 * @link_property ACCESS-COLLATERAL-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule unwrapRevertsWithoutWrapperRoleOrInvalidAsset(env e, address asset, address to, uint256 amount) {
    bool authorized = hasWrapperRole(e.msg.sender) && validAsset(asset);

    unwrap@withrevert(e, asset, to, amount);

    assert !authorized => lastReverted, "unwrap succeeded without WRAPPER_ROLE or with an invalid asset";
}

/* =============================================================================
 * R5 — upgradeToAndCall is owner-gated.
 * ============================================================================= */

/**
 * @title upgrades require the owner
 * @description The upgrade entry point reverts for any caller other than the owner.
 * @link_property ACCESS-COLLATERAL-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule upgradeRevertsWithoutOwner(env e, address newImplementation, bytes data) {
    address currentOwner = owner();

    upgradeToAndCall@withrevert(e, newImplementation, data);

    assert e.msg.sender != currentOwner => lastReverted, "upgradeToAndCall succeeded for a non-owner";
}

/* =============================================================================
 * R6 — rescue is owner-gated.
 * ============================================================================= */

/**
 * @title rescuing tokens requires the owner
 * @description The rescue entry point reverts for any caller other than the owner.
 * @link_property ACCESS-COLLATERAL-RESCUE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c228413eea18416f91866e61fb4897c3?anonymousKey=84e7e4f7f27ffa883dab72d69416489b8ffada11
 */
rule rescueRevertsWithoutOwner(env e, address[] assets, address[] tos, uint256[] amounts) {
    address currentOwner = owner();

    rescue@withrevert(e, assets, tos, amounts);
    bool reverted = lastReverted;

    assert e.msg.sender != currentOwner => reverted, "rescue succeeded for a non-owner";
    satisfy !reverted;
}

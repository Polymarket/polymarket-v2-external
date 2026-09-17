/* =============================================================================
 * WRAP-01 / UNWRAP-01 — CollateralToken ramp mint/burn is exactly backed.
 *
 * wrap:
 *   - mints exactly `_amount` pUSD to `_to`,
 *   - forwards exactly `_amount` of the asset from this contract to the VAULT,
 *   - raises pUSD totalSupply by exactly `_amount`.
 *
 * unwrap:
 *   - releases exactly `_amount` of the asset from the VAULT to `_to`,
 *   - burns exactly `_amount` pUSD from this contract's OWN pre-transferred balance,
 *   - lowers pUSD totalSupply by exactly `_amount`.
 *
 * ============================================================================= */

/*
 * MODULE
 * @module CollateralToken Wrap Backing
 * @contract CollateralToken
 * @impact pUSD could be minted without the matching asset reaching the vault, leaving the collateral token unbacked
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property WRAP-01 wrap mints pUSD exactly backed by the asset it forwards to the vault.
 * @property UNWRAP-01 unwrap burns pUSD exactly matched by the asset it releases from the vault.
 */


import "summaries/Solady/SafeTransferLib.spec";
import "summaries/Solady/OwnableRoles.spec";

using CollateralToken as CollateralToken;

methods {
    /* ---- pUSD native reads (CollateralToken IS the Solady ERC20 under test) ---- */
    function balanceOf(address) external returns (uint256) envfree;
    function totalSupply() external returns (uint256) envfree;

    /* ---- immutable wiring (valid-asset set + vault) ---- */
    function USDC() external returns (address) envfree;
    function USDCE() external returns (address) envfree;
    function VAULT() external returns (address) envfree;

    /* ---- OwnableRoles read/write wiring -> boolean ghosts (mirrors sanity spec) ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

/* =============================================================================
 *                                  WRAP-01
 * ============================================================================= */

function wrapMintsAndForwardsBody(
    env e, address asset, address to, uint256 amount, bool legacy, address cbReceiver, bytes cbData
) {
    require VAULT() != currentContract, "vault distinct from asset source";
    // ERC20 well-formedness, assumed: no invariant in this tree proves it (Solady's assembly
    // balance slots defeat a sum-of-balances ghost).
    require balanceOf(to) <= totalSupply(), "no balance exceeds total supply";

    mathint supplyBefore = totalSupply();
    mathint toPusdBefore = balanceOf(to);
    mathint vaultAssetBefore = balanceByToken[asset][VAULT()];
    mathint ctAssetBefore = balanceByToken[asset][currentContract];

    if (legacy) {
        wrap(e, asset, to, amount, cbReceiver, cbData);
    } else {
        wrap(e, asset, to, amount);
    }

    assert totalSupply() == supplyBefore + amount, "pUSD supply rises by amount";
    assert balanceOf(to) == toPusdBefore + amount, "recipient minted exactly amount";
    assert balanceByToken[asset][VAULT()] == vaultAssetBefore + amount, "vault receives amount";
    assert balanceByToken[asset][currentContract] == ctAssetBefore - amount, "asset leaves contract";
}

/**
 * @title wrap mints and forwards exactly
 * @description A successful wrap mints exactly the requested pUSD to the recipient and forwards the same amount of the asset to the vault.
 * @link_property WRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule wrapMintsAndForwards(
    env e, address asset, address to, uint256 amount, address cbReceiver, bytes cbData
) {
    wrapMintsAndForwardsBody(e, asset, to, amount, false, cbReceiver, cbData);
}

/**
 * @title the legacy wrap overload mints and forwards exactly
 * @description A successful wrap through the five-argument overload mints exactly the requested pUSD to the recipient and forwards the same amount of the asset to the vault, whatever the callback arguments.
 * @link_property WRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule wrapMintsAndForwardsLegacyOverload(
    env e, address asset, address to, uint256 amount, address cbReceiver, bytes cbData
) {
    wrapMintsAndForwardsBody(e, asset, to, amount, true, cbReceiver, cbData);
}

/* =============================================================================
 *                                 UNWRAP-01
 * ============================================================================= */

function unwrapReleasesAndBurnsBody(
    env e, address asset, address to, uint256 amount, bool legacy, address cbReceiver, bytes cbData
) {
    require VAULT() != to, "vault distinct from asset recipient";
    require balanceOf(currentContract) <= totalSupply(), "no balance exceeds total supply";

    mathint supplyBefore = totalSupply();
    mathint ctPusdBefore = balanceOf(currentContract);
    mathint vaultAssetBefore = balanceByToken[asset][VAULT()];
    mathint toAssetBefore = balanceByToken[asset][to];

    if (legacy) {
        unwrap(e, asset, to, amount, cbReceiver, cbData);
    } else {
        unwrap(e, asset, to, amount);
    }

    assert totalSupply() == supplyBefore - amount, "pUSD supply falls by amount";
    assert balanceOf(currentContract) == ctPusdBefore - amount, "contract pUSD burned exactly amount";
    assert balanceByToken[asset][VAULT()] == vaultAssetBefore - amount, "vault releases amount";
    assert balanceByToken[asset][to] == toAssetBefore + amount, "recipient receives amount";
}

/**
 * @title unwrap releases and burns exactly
 * @description A successful unwrap releases exactly the requested asset from the vault to the recipient and burns the same amount of pUSD from the ramp's own balance.
 * @link_property UNWRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule unwrapReleasesAndBurns(
    env e, address asset, address to, uint256 amount, address cbReceiver, bytes cbData
) {
    unwrapReleasesAndBurnsBody(e, asset, to, amount, false, cbReceiver, cbData);
}

/**
 * @title the legacy unwrap overload releases and burns exactly
 * @description A successful unwrap through the five-argument overload releases exactly the requested asset from the vault to the recipient and burns the same amount of pUSD from the ramp's own balance, whatever the callback arguments.
 * @link_property UNWRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule unwrapReleasesAndBurnsLegacyOverload(
    env e, address asset, address to, uint256 amount, address cbReceiver, bytes cbData
) {
    unwrapReleasesAndBurnsBody(e, asset, to, amount, true, cbReceiver, cbData);
}

/* =============================================================================
 *                              balance isolation
 * ============================================================================= */

function wrapTouchesNoOtherBalanceBody(
    env e, address asset, address to, uint256 amount, address other, address t, address acc,
    bool legacy, address cbReceiver, bytes cbData
) {
    require other != to, "exclude the mint recipient";
    require !(t == asset && acc == VAULT()), "exclude vault asset leg";
    require !(t == asset && acc == currentContract), "exclude contract asset leg";

    mathint pusdOtherBefore = balanceOf(other);
    mathint assetOtherBefore = balanceByToken[t][acc];

    if (legacy) {
        wrap(e, asset, to, amount, cbReceiver, cbData);
    } else {
        wrap(e, asset, to, amount);
    }

    assert balanceOf(other) == pusdOtherBefore, "no other pUSD balance changes";
    assert balanceByToken[t][acc] == assetOtherBefore, "no other asset balance changes";
}

/**
 * @title wrap touches no other balance
 * @description wrap touches no pUSD balance other than the recipient and no asset cell other than the ramp and the vault.
 * @link_property WRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule wrapTouchesNoOtherBalance(
    env e, address asset, address to, uint256 amount, address other, address t, address acc,
    address cbReceiver, bytes cbData
) {
    wrapTouchesNoOtherBalanceBody(e, asset, to, amount, other, t, acc, false, cbReceiver, cbData);
}

/**
 * @title the legacy wrap overload touches no other balance
 * @description wrap through the five-argument overload touches no pUSD balance other than the recipient and no asset cell other than the ramp and the vault, whatever the callback arguments.
 * @link_property WRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule wrapTouchesNoOtherBalanceLegacyOverload(
    env e, address asset, address to, uint256 amount, address other, address t, address acc,
    address cbReceiver, bytes cbData
) {
    wrapTouchesNoOtherBalanceBody(e, asset, to, amount, other, t, acc, true, cbReceiver, cbData);
}

function unwrapTouchesNoOtherBalanceBody(
    env e, address asset, address to, uint256 amount, address other, address t, address acc,
    bool legacy, address cbReceiver, bytes cbData
) {
    require other != currentContract, "exclude the burn source";
    require !(t == asset && acc == VAULT()), "exclude vault asset leg";
    require !(t == asset && acc == to), "exclude recipient asset leg";

    mathint pusdOtherBefore = balanceOf(other);
    mathint assetOtherBefore = balanceByToken[t][acc];

    if (legacy) {
        unwrap(e, asset, to, amount, cbReceiver, cbData);
    } else {
        unwrap(e, asset, to, amount);
    }

    assert balanceOf(other) == pusdOtherBefore, "no other pUSD balance changes";
    assert balanceByToken[t][acc] == assetOtherBefore, "no other asset balance changes";
}

/**
 * @title unwrap touches no other balance
 * @description unwrap touches no pUSD balance other than the ramp's and no asset cell other than the vault and the recipient.
 * @link_property UNWRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule unwrapTouchesNoOtherBalance(
    env e, address asset, address to, uint256 amount, address other, address t, address acc,
    address cbReceiver, bytes cbData
) {
    unwrapTouchesNoOtherBalanceBody(e, asset, to, amount, other, t, acc, false, cbReceiver, cbData);
}

/**
 * @title the legacy unwrap overload touches no other balance
 * @description unwrap through the five-argument overload touches no pUSD balance other than the ramp's and no asset cell other than the vault and the recipient, whatever the callback arguments.
 * @link_property UNWRAP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/386c8b250da744718389338e841b4056?anonymousKey=9339b00f4681b0afb96fb6e60049b2b874945138
 */
rule unwrapTouchesNoOtherBalanceLegacyOverload(
    env e, address asset, address to, uint256 amount, address other, address t, address acc,
    address cbReceiver, bytes cbData
) {
    unwrapTouchesNoOtherBalanceBody(e, asset, to, amount, other, t, acc, true, cbReceiver, cbData);
}
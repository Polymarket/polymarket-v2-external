
/*
 * MODULE
 * @module CombinatorialModule Global Solvency
 * @contract CombinatorialModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 *
 * PROPERTIES
 * @property COMBO-NEUTRAL-01 The position-only combinatorial transforms move no collateral.
 */

import "../summaries/PositionManager_full_summaries.spec";
import "../summaries/CombinatorialModule_solvency_call_resolution.spec";
import "../summaries/CombinatorialModule_base_summaries.spec";
import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";
import "../summaries/Solady/SafeTransferLib.spec";
import "../summaries/CTFHelpers_summaries.spec";
import "../summaries/muldiv.spec";

methods {
    // ---- envfree ----
    function CollateralToken.USDC() external returns (address) envfree;
    function CollateralToken.USDCE() external returns (address) envfree;
    function CollateralToken.VAULT() external returns (address) envfree;

    // Approvals answer from the ghost model
    function _.isApprovedForAll(address owner, address operator) internal =>
        isApprovedForAllCVL(owner, operator) expect bool;

    // ---- PositionManager position mutators ----
    function PositionManager.mint(address _to, PositionManager.PositionId _positionId, uint256 _amount)
        external with (env e) => mintWithAuthCVL(e, _to, _positionId, _amount);
    function PositionManager.batchMint(address _to, PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external with (env e) => batchMintWithAuthCVL(e, _to, _positionIds, _amounts);
    function PositionManager.burn(PositionManager.PositionId _positionId, uint256 _amount)
        external with (env e) => burnWithAuthCVL(e, _positionId, _amount);
    function PositionManager.batchBurn(PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external with (env e) => batchBurnWithAuthCVL(e, _positionIds, _amounts);
    function PositionManager.unsafeTransferFrom(address from, address to, PositionManager.PositionId id, uint256 amount)
        external with (env e) => transferWithAuthCVL(e, from, to, id, amount);
    function PositionManager.unsafeBatchTransferFrom(
        address from, address to, PositionManager.PositionId[] ids, uint256[] amounts
    ) external with (env e) => batchTransferWithAuthCVL(e, from, to, ids, amounts);
    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);

    // The YES-basket id helpers build their result via in-place assembly array-length
    // manipulation (mstore on the array length slot). Replacing the helpers with a fresh same-length array
    // removes the assembly so those calls resolve to the summarized PM mutators.
    function CombinatorialModule._prepareYesBasketPositionIds(CombinatorialModule.PositionId[] memory fullLegs)
        internal returns (CombinatorialModule.PositionId[] memory) => basketIdsCVL(fullLegs);

    // ---- CollateralToken pUSD supply ----
    function CollateralToken.mint(address _to, uint256 _amount) external => pusdMintCVL(_amount);
    function CollateralToken.burn(uint256 _amount) external => pusdBurnCVL(_amount);

    // ---- OwnableRoles ----
    function _.hasAnyRole(address user, uint256 roles) internal =>
        hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal =>
        hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal =>
        rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) =>
        checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal =>
        setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal =>
        updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;

    // ---- Call resolution ----
    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);

    // The event ops (splitOnEvent / mergeOnEvent / convertOnEvent) build their child position ids
    // through inline assembly, which loses the sighash of the PM calls that follow in the same function body.
    unresolved external in CombinatorialModule.splitOnEvent(
        address[], CombinatorialModule.PositionId, CombinatorialModule.EventId, uint256
    ) => DISPATCH(optimistic=true) [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.burn(PositionManager.PositionId, uint256)
    ];
    unresolved external in CombinatorialModule.mergeOnEvent(
        address, CombinatorialModule.PositionId, CombinatorialModule.EventId, uint256
    ) => DISPATCH(optimistic=true) [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.batchBurn(PositionManager.PositionId[], uint256[])
    ];
    unresolved external in CombinatorialModule.convertOnEvent(
        address[], CombinatorialModule.PositionId, uint256, uint256
    ) => DISPATCH(optimistic=true) [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.burn(PositionManager.PositionId, uint256)
    ];
}

// Mirrors pUSD.totalSupply
ghost mathint ghostPusdSupply;

// pUSD minted (merge): supply up. pUSD burned (split): supply down.
function pusdMintCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply + to_mathint(amount);
}

function pusdBurnCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply - to_mathint(amount);
}

// Overapproximation for the assembly-built YES-basket id helpers: a fresh array of the same length
function basketIdsCVL(CombinatorialModule.PositionId[] fullLegs) returns CombinatorialModule.PositionId[] {
    CombinatorialModule.PositionId[] res;
    require res.length == fullLegs.length;
    return res;
}

// ------------------------------------------------------------
// Collateral neutrality of the position-only transforms
//
// The refinement ops and wrap/unwrap only re-arrange ERC1155 positions: they call neither
// CollateralToken.mint nor CollateralToken.burn, and never move vault/CT ERC20 balances. So
// they cannot change the LHS assets or the pUSD term of the global inequality.
// ------------------------------------------------------------

/**
 * @title position-only transforms are collateral-neutral
 * @description None of the eleven position-only combinatorial transforms changes the pUSD supply or any counted asset balance.
 * @link_property COMBO-NEUTRAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/f9bc455e49364042a6173bc5dd561a8c?anonymousKey=0e23e369e7798f38997557d636680bf5e8c58171
 */
rule transformsAreCollateralNeutral(env e, method f, calldataarg args)
filtered {
    f -> f.selector
            == sig:CombinatorialModule.splitOnCondition(address[],CombinatorialModule.PositionId,CombinatorialModule.ConditionId,uint256).selector
        || f.selector
            == sig:CombinatorialModule.mergeOnCondition(address,CombinatorialModule.PositionId,CombinatorialModule.ConditionId,uint256).selector
        || f.selector == sig:CombinatorialModule.extract(address[],CombinatorialModule.PositionId,uint256,uint256).selector
        || f.selector == sig:CombinatorialModule.inject(address,CombinatorialModule.PositionId,uint256,uint256).selector
        || f.selector == sig:CombinatorialModule.convertToYesBasket(address[],CombinatorialModule.PositionId,uint256).selector
        || f.selector == sig:CombinatorialModule.mergeFromYesBasket(address,CombinatorialModule.PositionId,uint256).selector
        || f.selector == sig:CombinatorialModule.wrap(address,CombinatorialModule.PositionId,uint256).selector
        || f.selector == sig:CombinatorialModule.unwrap(address,CombinatorialModule.PositionId,uint256).selector
        || f.selector
            == sig:CombinatorialModule.splitOnEvent(address[],CombinatorialModule.PositionId,CombinatorialModule.EventId,uint256).selector
        || f.selector
            == sig:CombinatorialModule.mergeOnEvent(address,CombinatorialModule.PositionId,CombinatorialModule.EventId,uint256).selector
        || f.selector
            == sig:CombinatorialModule.convertOnEvent(address[],CombinatorialModule.PositionId,uint256,uint256).selector
} {
    address usdc = CollateralToken.USDC();
    address usdce = CollateralToken.USDCE();
    address vault = CollateralToken.VAULT();

    mathint pusdBefore = ghostPusdSupply;
    mathint usdcVaultBefore = balanceByToken[usdc][vault];
    mathint usdceVaultBefore = balanceByToken[usdce][vault];
    mathint usdceCtBefore = balanceByToken[usdce][ConditionalTokens];

    f(e, args);

    assert ghostPusdSupply == pusdBefore, "position-only transform changed pUSD totalSupply";
    assert balanceByToken[usdc][vault] == usdcVaultBefore
        && balanceByToken[usdce][vault] == usdceVaultBefore
        && balanceByToken[usdce][ConditionalTokens] == usdceCtBefore,
        "position-only transform moved vault/CT collateral";
}

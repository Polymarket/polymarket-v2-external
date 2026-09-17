// Shared base for the PositionManager-scene solvency specs:
//   * certora/specs/solvency/PositionManager.spec (verify: PositionManager)
//   * certora/specs/solvency/BinaryModule.spec    (verify: BinaryModule)
// Both run the SAME scene (same files list); they differ only in the conf's verify
// target and parametric_contracts, which is what partitions solvencyPreserved's
// coverage between the two contracts.

import "../summaries/PositionManager_full_summaries.spec";
import "../summaries/PositionManager_call_resolution.spec";
import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";
import "../summaries/Solady/SafeTransferLib.spec";
import "../summaries/CTFHelpers_summaries.spec";
import "../summaries/BinaryModule_base_summaries.spec";
import "../summaries/LegacyCTF_migration_summaries.spec";

using ConditionalTokens as ConditionalTokens;
using USDCe as USDCe;

links {
    BinaryModule.USDCE => USDCe;
    CollateralToken.USDCE => USDCe;
}

methods {
    // ---- envfree ----
    function CollateralToken.totalSupply() external returns (uint256) envfree;
    function CollateralToken.USDC() external returns (address) envfree;
    function CollateralToken.USDCE() external returns (address) envfree;
    function CollateralToken.VAULT() external returns (address) envfree;
    // moduleById / crossModuleAuth are declared envfree by PositionManager_full_summaries.spec.

    // Approvals answer from the ghost model
    function _.isApprovedForAll(address owner, address operator) internal =>
        isApprovedForAllCVL(owner, operator) expect bool;

    function BinaryModule.conditionResultData(uint256) external returns (bool, uint256, uint256) envfree;

    // ---- PositionManager position summaries ----
    function PositionManager.mint(address _to, PositionManager.PositionId _positionId, uint256 _amount)
        external with (env e) => liabAwareMint(e, _to, _positionId, _amount);
    function PositionManager.batchMint(address _to, PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external with (env e) => liabAwareBatchMint(e, _to, _positionIds, _amounts);
    function PositionManager.burn(PositionManager.PositionId _positionId, uint256 _amount)
        external with (env e) => liabAwareBurn(e, _positionId, _amount);
    function PositionManager.batchBurn(PositionManager.PositionId[] _positionIds, uint256[] _amounts)
        external with (env e) => liabAwareBatchBurn(e, _positionIds, _amounts);
    function PositionManager.unsafeTransferFrom(address from, address to, PositionManager.PositionId id, uint256 amount)
        external with (env e) => transferWithAuthCVL(e, from, to, id, amount);
    function PositionManager.unsafeBatchTransferFrom(
        address from, address to, PositionManager.PositionId[] ids, uint256[] amounts
    ) external with (env e) => batchTransferWithAuthCVL(e, from, to, ids, amounts);
    // The safe variants are the unsafe ones plus a receiver callback; see the two wrappers below.
    function PositionManager.safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data)
        external with (env e) => transferWithAuthNondetRevertCVL(e, from, to, id, amount);
    function PositionManager.safeBatchTransferFrom(
        address from, address to, uint256[] ids, uint256[] amounts, bytes data
    ) external with (env e) => batchTransferWithAuthNondetRevertCVL(e, from, to, ids, amounts);
    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);

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
}

// ------------------------------------------------------------
// Solvency accounting (result-aware liability)
//
// Invariant:
//   USDC.bal(VAULT) + USDCe.bal(VAULT) + USDCe.bal(ConditionalTokens)
//     >= pUSD.totalSupply() + Σ_all_C liability(C)
//   liability(C) = unresolved(C) ? max(YES,NO) : floor((YES*r0 + NO*r1) / D)
// ------------------------------------------------------------

// A safe transfer is an unsafe transfer plus a callback to the receiver. An arbitrary receiver
// either accepts or rejects, so the model performs the movement and then reverts
// nondeterministically. 
function transferWithAuthNondetRevertCVL(env e, address from, address to, uint256 id, uint256 amount) {
    transferWithAuthCVL(e, from, to, id, amount);
    bool receiverRejects;
    if (receiverRejects) { revert(); }
}

function batchTransferWithAuthNondetRevertCVL(
    env e, address from, address to, uint256[] ids, uint256[] amounts
) {
    batchTransferWithAuthCVL(e, from, to, ids, amounts);
    bool receiverRejects;
    if (receiverRejects) { revert(); }
}

// Mirrors pUSD.totalSupply.
ghost mathint ghostPusdSupply;

// liabilityTotal = Σ_all_C liability(C), the redemption value owed to outstanding
// position holders. Per condition: YES id = condKey (outcome 0), NO id =
// condKey+1 (outcome 1), so the supplies are ghostSupply[condKey]/[condKey+1].
//   liability(C) = unresolved(C) ? max(YES, NO) : floor((YES*r0 + NO*r1) / D)
// This single term replaces the old locked + migratedBackingMax: for a standard
// condition it equals the locked collateral (pre-resolution YES=NO=max; post-
// resolution it drops exactly as redeems mint pUSD); for a migrated condition it
// is the same formula, backed by the ConditionalTokens USDCe reserve.
ghost mathint liabilityTotal;

// RESULT_DENOMINATOR: results are numerators out of 1e6.
definition RESULT_DENOMINATOR() returns mathint = 1000000;

// pUSD minted (merge/redeem): supply up. pUSD burned (split): supply down.
function pusdMintCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply + to_mathint(amount);
}

function pusdBurnCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply - to_mathint(amount);
}

// ------------------------------------------------------------
// Liability accounting
//
// Every position supply change flows through PM mint/burn (split/merge/redeem and,
// when admitted, migrate/bridge), so onSupplyChange keeps liabilityTotal exact 
// via an incremental delta of the condition's liability. 
// ------------------------------------------------------------

function cvlMax(mathint a, mathint b) returns mathint {
    return a > b ? a : b;
}

// Maintain liabilityTotal after a supply change of `delta` at `positionId`.
// Only YES(0)/NO(1) of a binary condition contribute to that condition's liability.
//
// liability(C) = unresolved ? max(YES, NO) : (YES*r0 + NO*r1) / D. The resolved-case
// delta is computed in CLOSED FORM: numNew := numOld + delta*rOut, i.e. the
// distribution of (yesOld + delta)*r0 (or noOld + delta times r1) is done here by
// hand, so the solver never has to expand a post-supply * result product.
function onSupplyChange(uint256 positionId, mathint delta) {
    mathint outcome = positionId % 256;
    require outcome == 0 || outcome == 1, "last byte of positionId can only be 0 or 1";

    uint256 condKey = require_uint256(positionId - outcome);
    mathint yesNew = ghostSupply[condKey];
    mathint noNew = ghostSupply[require_uint256(condKey + 1)];
    mathint yesOld = outcome == 0 ? yesNew - delta : yesNew;
    mathint noOld = outcome == 1 ? noNew - delta : noNew;

    // ERC1155 token supplies are non-negative
    require yesNew >= 0 && noNew >= 0 && yesOld >= 0 && noOld >= 0;

    bool resolved;
    uint256 r0Raw;
    uint256 r1Raw;
    resolved, r0Raw, r1Raw = BinaryModule.conditionResultData(condKey);
    if (resolved) {
        mathint r0 = to_mathint(r0Raw);
        mathint r1 = to_mathint(r1Raw);
        // _storeResult invariant: r0 + r1 == D proved by resultNormalized (Binary-ResultNorm01.spec)
        require r0 + r1 == RESULT_DENOMINATOR();
        // Implied by the sum (both are uint256 >= 0)
        require r0 <= RESULT_DENOMINATOR() && r1 <= RESULT_DENOMINATOR();

        mathint rOut = outcome == 0 ? r0 : r1;
        mathint numOld = yesOld * r0 + noOld * r1;
        mathint numNew = numOld + delta * rOut; // == yesNew*r0 + noNew*r1 by algebra
        liabilityTotal = liabilityTotal
            + numNew / RESULT_DENOMINATOR()
            - numOld / RESULT_DENOMINATOR();
    } else {
        liabilityTotal = liabilityTotal + cvlMax(yesNew, noNew) - cvlMax(yesOld, noOld);
    }
}

// Single mint
function liabAwareMint(env e, address to, uint256 id, uint256 amount) {
    mintWithAuthCVL(e, to, id, amount);
    onSupplyChange(id, to_mathint(amount));
}

// Single burn
function liabAwareBurn(env e, uint256 id, uint256 amount) {
    burnWithAuthCVL(e, id, amount);
    onSupplyChange(id, -to_mathint(amount));
}

// Batch mint
function liabAwareBatchMint(env e, address to, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (to == 0) { revert(); }
    if (ids.length > 0) { liabAwareMintElem(to, ids[0], amounts[0]); }
    if (ids.length > 1) { liabAwareMintElem(to, ids[1], amounts[1]); }
    if (ids.length > 2) { liabAwareMintElem(to, ids[2], amounts[2]); }
}

function liabAwareMintElem(address to, uint256 id, uint256 amount) {
    if (ghostBalance[to][id] + to_mathint(amount) > max_uint256) { revert(); }
    mintCVL(to, id, amount);
    onSupplyChange(id, to_mathint(amount));
}

// Batch burn
function liabAwareBatchBurn(env e, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (ids.length > 0) { liabAwareBurnElem(e.msg.sender, ids[0], amounts[0]); }
    if (ids.length > 1) { liabAwareBurnElem(e.msg.sender, ids[1], amounts[1]); }
    if (ids.length > 2) { liabAwareBurnElem(e.msg.sender, ids[2], amounts[2]); }
}

function liabAwareBurnElem(address from, uint256 id, uint256 amount) {
    burnByCVL(0, from, id, amount);
    onSupplyChange(id, -to_mathint(amount));
}

// ------------------------------------------------------------
// Solvency
//
// Headline (global) invariant:
//   vault_USDC + vault_USDCe + USDCe.bal(ConditionalTokens)
//     >= pUSD.totalSupply() + Σ_all_C liability(C)
//   liability(C) = unresolved(C) ? max(YES,NO) : floor((YES*r0 + NO*r1) / D)
// ------------------------------------------------------------

/// @title Vault + CT reserve >= pUSD totalSupply + Σ liability(C).
rule solvencyPreserved(env e, method f, calldataarg args)
filtered {
    f -> !f.isView
        && f.selector != sig:BinaryModule.mintFromBridge(address,BinaryModule.PositionId,uint256).selector
        && f.selector != sig:BinaryModule.burnFromBridge(BinaryModule.PositionId[],uint256[]).selector
} {
    address usdc = CollateralToken.USDC();
    address usdce = CollateralToken.USDCE();
    address vault = CollateralToken.VAULT();
    require usdc != usdce, "deployment: USDC and USDCe are distinct tokens";

    mathint assetsBefore = balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
    mathint liabBefore = ghostPusdSupply + liabilityTotal;
    require assetsBefore >= liabBefore, "solvency holds before";

    f(e, args);

    mathint assetsAfter = balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
    mathint liabAfter = ghostPusdSupply + liabilityTotal;
    assert assetsAfter >= liabAfter,
        "method broke vault+reserve >= pUSD totalSupply + liability";
}

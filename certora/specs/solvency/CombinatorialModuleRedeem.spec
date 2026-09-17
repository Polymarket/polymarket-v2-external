
/*
 * MODULE
 * @module CombinatorialModule Global Solvency
 * @contract CombinatorialModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 3 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 *
 * PROPERTIES
 * @property COMBO-GLOB-SOLVENCY CombinatorialModule preserves the collateral backing of every outstanding position it has minted, under every possible market resolution.
 */

import "../summaries/PositionManager_full_summaries.spec";
import "../summaries/CombinatorialModuleRedeem_call_resolution.spec";
import "../summaries/CombinatorialModule_base_summaries.spec";
import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";
import "../summaries/Solady/SafeTransferLib.spec";
import "../summaries/CTFHelpers_summaries.spec";
import "../summaries/muldiv.spec";
import "../summaries/CombinatorialPayout_summaries.spec";
import "./CombinatorialCondIdModel.spec";

// ============================================================
// Solvency accounting
//
// For a SINGLE combinatorial conjunction Q (a conjunction of underlying binary/negrisk legs),
// YES(Q) and NO(Q) are per-unit complementary, so the worst-case obligation collapses to:
//   liability(Q) = NO + PR * max(0, YES - NO),   PR = Π_{resolved legs}(factor_j / D)
// (PR = 1 when no leg is resolved, recovering max(YES,NO)). Tracked scaled by
// D^2 (= D^maxLegs, maxLegs = 2) so PR is an exact integer and there is no rounding.
//
// Bounded proof: conjunctions are restricted to <= 2 legs.
// ============================================================

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
    function _.moduleId() external => DISPATCHER(true);

    // ---- Payout summaries ----
    function CombinatorialModule._getConditionPayout(CombinatorialModule.PositionId _leg)
        internal returns (bool, uint256) => condPayoutCVL(_leg);
    function CombinatorialModule._getPositionPayout(CombinatorialModule.PositionId _positionId, uint256 _amount)
        internal returns (uint256) with (env e) => positionPayoutCVL(e, _positionId, _amount);

    function CombinatorialModule._trimArray(CombinatorialModule.PositionId[] memory arr, uint256 len)
        internal returns (CombinatorialModule.PositionId[] memory) => trimArrayCVL(arr, len);

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

    function _.hasAnyRole(address user, uint256 roles) external =>
        hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) external =>
        hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) external =>
        rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) external with (env e) =>
        checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) external =>
        setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) external =>
        updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) external =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;

    // ---- Call resolution ----
    function _.transfer(address, uint256) external => DISPATCHER(true);
    function _.balanceOf(address) external => DISPATCHER(true);
}

// Mirrors pUSD.totalSupply.
ghost mathint ghostPusdSupply;

// liabilityScaled = Σ_combinatorialConditions D^2 * liability(Q).
ghost mathint liabilityScaled;

// RESULT_DENOMINATOR / D2 come from CombinatorialPayout_summaries.spec.

function pusdMintCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply + to_mathint(amount);
}

function pusdBurnCVL(uint256 amount) {
    ghostPusdSupply = ghostPusdSupply - to_mathint(amount);
}

function cvlMax(mathint a, mathint b) returns mathint {
    return a > b ? a : b;
}

// Model of _trimArray: return arr truncated to the first `len` elements. Pins the
// fresh CVL array to the true prefix (element-preserving), so the residual conjunction Q'
// keeps the actual unresolved legs. Bounded: len <= 1 at legs <= 2
function trimArrayCVL(CombinatorialModule.PositionId[] arr, uint256 len) returns CombinatorialModule.PositionId[] {
    require len <= arr.length;
    CombinatorialModule.PositionId[] res;
    require res.length == len;
    if (len > 0) { require res[0] == arr[0]; }
    if (len > 1) { require res[1] == arr[1]; }
    return res;
}

// D^2 * liability(Q), result-aware:
//   all legs resolved  -> EXACT obligation  YES*PR_scaled + NO*(D^2 - PR_scaled)
//   else (worst case)   -> D^2*NO + PR_scaled * max(0, YES - NO)
// where PR_scaled = product of the per-leg factor numerators, each defaulting to D (= a PR
// contribution of 1) when the leg is unresolved or absent (so PR_scaled = D^2 / D*f / f0*f1 for
// 0 / 1 / 2 resolved legs). 
function combiLiabScaled(uint256 condKey, mathint yes, mathint no) returns mathint {
    uint256 cnt = CombinatorialModule.legCount(condKey);
    require cnt >= 1 && cnt <= 2, "bounded proof: combinatorial conjunction has 1 or 2 legs";

    uint256 leg0 = CombinatorialModule.legAt(condKey, 0);
    bool res0 = legResolved(leg0);
    mathint f0 = res0 ? legFactorNum(leg0) : RESULT_DENOMINATOR();
    require f0 <= RESULT_DENOMINATOR(); // factor <= D (r0 + r1 == D, both >= 0); tames the product

    bool res1;
    mathint f1;
    if (cnt == 2) {
        uint256 leg1 = CombinatorialModule.legAt(condKey, 1);
        res1 = legResolved(leg1);
        f1 = res1 ? legFactorNum(leg1) : RESULT_DENOMINATOR();
        require f1 <= RESULT_DENOMINATOR();
    } else {
        res1 = true; // absent second leg: a constant factor of 1, always "resolved"
        f1 = RESULT_DENOMINATOR();
    }

    mathint prScaled = f0 * f1;
    bool allResolved = res0 && res1;

    return allResolved
        ? yes * prScaled + no * (D2() - prScaled)
        : D2() * no + prScaled * cvlMax(0, yes - no);
}

// ------------------------------------------------------------
// liabilityScaled maintenance: recompute the touched conjunction's D^2 * liability(Q) and
// fold the delta in. YES(Q) id = condKey (outcome 0), NO(Q) id = condKey + 1 (outcome 1).
// ------------------------------------------------------------
function onSupplyChange(uint256 positionId, mathint delta) {
    require moduleIdOf(positionId) == 3, "combinatorial scene: positions are combinatorial (moduleId 3)";
    mathint outcome = positionId % 256;
    require outcome == 0 || outcome == 1, "combinatorial position outcome byte is 0 or 1";

    uint256 condKey = require_uint256(positionId - outcome);
    mathint yesNew = ghostSupply[condKey];
    mathint noNew = ghostSupply[require_uint256(condKey + 1)];
    mathint yesOld = outcome == 0 ? yesNew - delta : yesNew;
    mathint noOld = outcome == 1 ? noNew - delta : noNew;

    // ERC1155 supplies are non-negative in any reachable state.
    require yesNew >= 0 && noNew >= 0 && yesOld >= 0 && noOld >= 0;

    liabilityScaled = liabilityScaled
        + combiLiabScaled(condKey, yesNew, noNew)
        - combiLiabScaled(condKey, yesOld, noOld);
}

// ------------------------------------------------------------
// liability-aware PM mint/burn wrappers.
// ------------------------------------------------------------
function liabAwareMint(env e, address to, uint256 id, uint256 amount) {
    mintWithAuthCVL(e, to, id, amount);
    onSupplyChange(id, to_mathint(amount));
}

function liabAwareBurn(env e, uint256 id, uint256 amount) {
    burnWithAuthCVL(e, id, amount);
    onSupplyChange(id, -to_mathint(amount));
}

function liabAwareBatchMint(env e, address to, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (to == 0) { revert(); }
    if (ids.length > 0) { liabAwareMintElem(to, ids[0], amounts[0]); }
    if (ids.length > 1) { liabAwareMintElem(to, ids[1], amounts[1]); }
}

function liabAwareMintElem(address to, uint256 id, uint256 amount) {
    if (ghostBalance[to][id] + to_mathint(amount) > max_uint256) { revert(); }
    mintCVL(to, id, amount);
    onSupplyChange(id, to_mathint(amount));
}

function liabAwareBatchBurn(env e, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (ids.length > 0) { liabAwareBurnElem(e.msg.sender, ids[0], amounts[0]); }
    if (ids.length > 1) { liabAwareBurnElem(e.msg.sender, ids[1], amounts[1]); }
}

function liabAwareBurnElem(address from, uint256 id, uint256 amount) {
    burnByCVL(0, from, id, amount);
    onSupplyChange(id, -to_mathint(amount));
}

/**
 * @title solvency preserved, combinatorial split merge redeem
 * @description split, merge and redeem on a prepared combinatorial conjunction preserve the backing inequality against the result-aware worst-case liability.
 * @link_property COMBO-GLOB-SOLVENCY
 * @assumption Verified with loops unrolled to at most 2 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d808ce4aceeb4eabb500d50e25802f6d?anonymousKey=343f67bc963cb2433b351e232f7de70c89d458bf
 * @dev D^2*(vault + CT reserve) >= D^2*pUSD totalSupply + Sum of D^2*liability(Q).
 */
rule solvencyPreserved(env e, method f, calldataarg args)
filtered {
    // Harness-only mutator with no production counterpart (see CombinatorialCanonical.spec);
    // excluded so this rule's verdict is unaffected by the harness addition.
    f -> f.selector != sig:CombinatorialModule.storeLegsFromMemoryReal(CombinatorialModule.PositionId[]).selector
        && (f.contract == currentContract
            || f.selector == sig:CombinatorialModule.split(address[],CombinatorialModule.ConditionId,uint256).selector
            || f.selector == sig:CombinatorialModule.merge(address,CombinatorialModule.ConditionId,uint256).selector
            || f.selector == sig:CombinatorialModule.redeem(address,CombinatorialModule.PositionId,uint256).selector)
} {
    address usdc = CollateralToken.USDC();
    address usdce = CollateralToken.USDCE();
    address vault = CollateralToken.VAULT();
    require usdc != usdce, "deployment: USDC and USDCe are distinct tokens";

    mathint assetsBefore = balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
    mathint liabBefore = D2() * ghostPusdSupply + liabilityScaled;
    require D2() * assetsBefore >= liabBefore, "solvency holds before";

    f(e, args);

    mathint assetsAfter = balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
    mathint liabAfter = D2() * ghostPusdSupply + liabilityScaled;
    assert D2() * assetsAfter >= liabAfter,
        "method broke D^2*(vault+reserve) >= D^2*pUSD totalSupply + scaled liability";
}
// ============================================================
// Properties:
//   ACCESS-PM-MINT-01     Only the registered module for a positionId (or a
//                         crossModuleAuth-granted module) can mint or burn
//                         that position.
//   ACCESS-PM-REGISTRY-01 Module registration (addModule), removal
//                         (removeModule), and setCrossModuleAuth are
//                         admin-only (_ROLE_0).
// ============================================================

/*
 * MODULE
 * @module PositionManager Access Control
 * @contract PositionManager
 * @impact A contract that is not the position module could mint or burn it, forging unbacked positions
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * @global_assumption Solady OwnableRoles role bitmaps are replaced by a CVL model
 *
 * PROPERTIES
 * @property ACCESS-PM-MINT-01 Only the registered module for a positionId, or a crossModuleAuth module, can mint or burn that position.
 * @property ACCESS-PM-REGISTRY-01 Module registration, removal, and crossModuleAuth are admin-only.
 */

import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";

methods {
    // ---- envfree concrete-storage reads ----
    function moduleById(uint256) external returns (address) envfree;
    function crossModuleAuth(address) external returns (bool) envfree;
    function balanceOf(address, uint256) external returns (uint256) envfree;

    // ---- OwnableRoles ghost model ----
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

    function _.moduleId() external => NONDET;
}

// ------------------------------------------------------------
// Helpers
// ------------------------------------------------------------

// Top 8 bits of a positionId select the module (PositionIdLib.moduleId:
// id >> 248).
definition moduleIdOf(uint256 p) returns mathint = p / 2^248;

// The registered module for positionId `p` (moduleById[p >> 248]).
function moduleFor(uint256 p) returns address {
    return moduleById(assert_uint256(moduleIdOf(p)));
}

// Whether `sender` is the registered module of every id in the batch
// (unrolled to loop_iter = 3). Empty batches are owned
function allIdsOwnedBy3(address sender, uint256[] ids) returns bool {
    bool ok0 = ids.length > 0 ? moduleFor(ids[0]) == sender : true;
    bool ok1 = ids.length > 1 ? moduleFor(ids[1]) == sender : true;
    bool ok2 = ids.length > 2 ? moduleFor(ids[2]) == sender : true;
    return ok0 && ok1 && ok2;
}

// The four supply-changing entry points.
definition IS_MINT_BURN(method f) returns bool =
    f.selector == sig:mint(address,PositionManager.PositionId,uint256).selector
        || f.selector == sig:batchMint(address,PositionManager.PositionId[],uint256[]).selector
        || f.selector == sig:burn(PositionManager.PositionId,uint256).selector
        || f.selector == sig:batchBurn(PositionManager.PositionId[],uint256[]).selector;

// Balance-moving (supply-preserving) entry points.
definition IS_TRANSFER(method f) returns bool =
    f.selector == sig:safeTransferFrom(address,address,uint256,uint256,bytes).selector
        || f.selector == sig:safeBatchTransferFrom(address,address,uint256[],uint256[],bytes).selector
        || f.selector == sig:unsafeTransferFrom(address,address,PositionManager.PositionId,uint256).selector
        || f.selector == sig:unsafeBatchTransferFrom(address,address,PositionManager.PositionId[],uint256[]).selector;

// The admin-gated registry entry points.
definition IS_REGISTRY(method f) returns bool =
    f.selector == sig:addModule(address).selector
        || f.selector == sig:removeModule(uint256).selector
        || f.selector == sig:setCrossModuleAuth(address,bool).selector;

// ------------------------------------------------------------
// ACCESS-PM-MINT-01 — entry-point auth rules
// ------------------------------------------------------------

/**
 * @title mint requires module authorization
 * @description mint succeeds only for the id's registered module or a cross-authorized caller.
 * @link_property ACCESS-PM-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule mintRequiresModuleAuth(env e) {
    address to;
    uint256 positionId;
    uint256 amount;
    address registered = moduleFor(positionId);
    bool crossAuth = crossModuleAuth(e.msg.sender);

    mint@withrevert(e, to, positionId, amount);

    assert !lastReverted => (registered == e.msg.sender || crossAuth),
        "mint succeeded for a caller that is neither the id's module nor cross-authorized";
    satisfy !lastReverted;
}

/**
 * @title burn requires module authorization
 * @description burn succeeds only for the id's registered module or a cross-authorized caller.
 * @link_property ACCESS-PM-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule burnRequiresModuleAuth(env e) {
    uint256 positionId;
    uint256 amount;
    address registered = moduleFor(positionId);
    bool crossAuth = crossModuleAuth(e.msg.sender);

    burn@withrevert(e, positionId, amount);

    assert !lastReverted => (registered == e.msg.sender || crossAuth),
        "burn succeeded for a caller that is neither the id's module nor cross-authorized";
    satisfy !lastReverted;
}

/**
 * @title batchMint requires module authorization
 * @description batchMint succeeds only when the caller is the registered module for every id, or is cross-authorized.
 * @link_property ACCESS-PM-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule batchMintRequiresModuleAuth(env e) {
    address to;
    uint256[] positionIds;
    uint256[] amounts;
    require positionIds.length <= 3, "loop_iter bound";
    bool allOwn = allIdsOwnedBy3(e.msg.sender, positionIds);
    bool crossAuth = crossModuleAuth(e.msg.sender);

    batchMint@withrevert(e, to, positionIds, amounts);

    assert !lastReverted => (allOwn || crossAuth),
        "batchMint succeeded without per-id module ownership or cross-auth";
    satisfy !lastReverted;
}

/**
 * @title batchBurn requires module authorization
 * @description batchBurn succeeds only when the caller is the registered module for every id, or is cross-authorized.
 * @link_property ACCESS-PM-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule batchBurnRequiresModuleAuth(env e) {
    uint256[] positionIds;
    uint256[] amounts;
    require positionIds.length <= 3, "loop_iter bound";
    bool allOwn = allIdsOwnedBy3(e.msg.sender, positionIds);
    bool crossAuth = crossModuleAuth(e.msg.sender);

    batchBurn@withrevert(e, positionIds, amounts);

    assert !lastReverted => (allOwn || crossAuth),
        "batchBurn succeeded without per-id module ownership or cross-auth";
    satisfy !lastReverted;
}

// ------------------------------------------------------------
// ACCESS-PM-MINT-01 — parametric completeness
// ------------------------------------------------------------

/**
 * @title balance changes require an authorized entry point
 * @description A balance of (holder, id) changes only via a transfer or via an authorized mint or burn entry point.
 * @link_property ACCESS-PM-MINT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule balanceChangesRequireAuthorizedEntryPoint(env e, method f, calldataarg args)
filtered { f -> !f.isView } {
    address holder;
    uint256 p;
    address registered = moduleFor(p);
    bool crossAuth = crossModuleAuth(e.msg.sender);
    uint256 balanceBefore = balanceOf(holder, p);

    f(e, args);

    assert balanceOf(holder, p) != balanceBefore =>
        (IS_TRANSFER(f) || (IS_MINT_BURN(f) && (registered == e.msg.sender || crossAuth))),
        "a method that is neither a transfer nor an authorized mint/burn moved a balance";
}

// ------------------------------------------------------------
// ACCESS-PM-REGISTRY-01 — entry-point auth rules
// ------------------------------------------------------------

/**
 * @title addModule requires admin
 * @description addModule succeeds only for an admin caller.
 * @link_property ACCESS-PM-REGISTRY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule addModuleRequiresAdmin(env e) {
    address module;
    bool isAdmin = ghostHasRole0[currentContract][e.msg.sender];

    addModule@withrevert(e, module);

    assert !lastReverted => isAdmin, "addModule succeeded for a non-admin caller";
    satisfy !lastReverted;
}

/**
 * @title removeModule requires admin
 * @description removeModule succeeds only for an admin caller.
 * @link_property ACCESS-PM-REGISTRY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule removeModuleRequiresAdmin(env e) {
    uint256 moduleId;
    bool isAdmin = ghostHasRole0[currentContract][e.msg.sender];

    removeModule@withrevert(e, moduleId);

    assert !lastReverted => isAdmin, "removeModule succeeded for a non-admin caller";
    satisfy !lastReverted;
}

/**
 * @title setCrossModuleAuth requires admin
 * @description setCrossModuleAuth succeeds only for an admin caller.
 * @link_property ACCESS-PM-REGISTRY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule setCrossModuleAuthRequiresAdmin(env e) {
    address module;
    bool authorized;
    bool isAdmin = ghostHasRole0[currentContract][e.msg.sender];

    setCrossModuleAuth@withrevert(e, module, authorized);

    assert !lastReverted => isAdmin, "setCrossModuleAuth succeeded for a non-admin caller";
    satisfy !lastReverted;
}

// ------------------------------------------------------------
// ACCESS-PM-REGISTRY-01 — parametric completeness
// ------------------------------------------------------------

/**
 * @title registry changes require admin
 * @description moduleById and crossModuleAuth change only via the three registry entry points, and only under an admin caller.
 * @link_property ACCESS-PM-REGISTRY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4600cbb95acf4dd492979f410f389f7e?anonymousKey=0d4a4b1b6a6f24e4d074ae3ddce2869d23f577ab
 */
rule registryChangesRequireAdmin(env e, method f, calldataarg args)
filtered { f -> !f.isView } {
    uint256 id;
    address m;
    address moduleBefore = moduleById(id);
    bool authBefore = crossModuleAuth(m);
    bool isAdmin = ghostHasRole0[currentContract][e.msg.sender];

    f(e, args);

    bool changed = moduleById(id) != moduleBefore || crossModuleAuth(m) != authBefore;
    assert changed => isAdmin,
        "registry state changed under a non-admin caller";
    assert changed => IS_REGISTRY(f),
        "a non-registry method changed moduleById or crossModuleAuth";
}
/* =============================================================================
 * PM-ACCESS-INV-01 — cross-module authorization implies registration
 *
 * Property: a module can hold cross-module mint/burn authorization only if it is
 * currently registered. The design keeps a module registered under its OWN
 * self-reported id, so the faithful (and inductive) statement is:
 *
 *     ∀ m ≠ 0.  crossModuleAuth[m]  ⟹  moduleById[m.moduleId()] == m
 * ============================================================================= */

/*
 * MODULE
 * @module PositionManager Access Control
 * @contract PositionManager
 * @impact A contract that is not the position module could mint or burn it, forging unbacked positions
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property PM-ACCESS-INV-01 a module holds cross-module mint and burn authorization only while it is registered under its own id.
 */


import "summaries/Solady/OwnableRoles.spec";

using PositionManager as PositionManager;

// Sound : moduleId() modeled as a deterministic function of the callee address.
ghost moduleIdGhost(address) returns uint256;

methods {
    /* ---- public mapping getters (state read in the invariant) ---- */
    function crossModuleAuth(address) external returns (bool)    envfree;
    function moduleById(uint256)      external returns (address) envfree;

    /* ---- moduleId(): deterministic per-callee (addModule / setCrossModuleAuth) ---- */
    function _.moduleId() external => moduleIdGhost(calledContract) expect uint256;

    /* ---- getPayout inner call: view, irrelevant; NONDET avoids a spurious havoc ---- */
    function _.getPayout(PositionManager.PositionId, uint256) external => NONDET;

    /* ---- OwnableRoles wiring (onlyAdmin ⇒ _checkRoles); currentContract-keyed ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// Functions havocing the state
definition opaqueExternalCall(method f) returns bool =
       f.selector == sig:safeTransferFrom(address,address,uint256,uint256,bytes).selector
    || f.selector == sig:safeBatchTransferFrom(address,address,uint256[],uint256[],bytes).selector
    || f.selector == sig:upgradeToAndCall(address,bytes).selector;

/**
 * @title cross-authorization implies registration
 * @description A cross-authorized module is always registered under its own reported id.
 * @link_property PM-ACCESS-INV-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/982b712c5a87416681ca2bf01b44f29e?anonymousKey=7a69593406aed425e244080fd10dc402a27606d7
 */
invariant crossAuthImpliesRegistered(address m)
    m != 0 => (crossModuleAuth(m) => moduleById(moduleIdGhost(m)) == m)
    filtered { f -> !opaqueExternalCall(f) }

/**
 * @title a registered module reports its own id
 * @description A registered module always reports the id it is filed under.
 * @link_property PM-ACCESS-INV-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/982b712c5a87416681ca2bf01b44f29e?anonymousKey=7a69593406aed425e244080fd10dc402a27606d7
 */
invariant moduleReportsOwnId(uint256 id)
    moduleById(id) != 0 => moduleIdGhost(moduleById(id)) == id
    filtered { f -> !opaqueExternalCall(f) }

/**
 * @title granting cross-authorization requires registration
 * @description Cross-module authorization can only be granted to a module registered under its own id.
 * @link_property PM-ACCESS-INV-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/982b712c5a87416681ca2bf01b44f29e?anonymousKey=7a69593406aed425e244080fd10dc402a27606d7
 */
rule setCrossAuthRequiresRegistration(env e, address module, bool authorized) {
    setCrossModuleAuth(e, module, authorized);
    assert moduleById(moduleIdGhost(module)) == module;
}

/**
 * @title removing a module clears its authorization
 * @description De-registering a module clears its cross-module authorization.
 * @link_property PM-ACCESS-INV-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/982b712c5a87416681ca2bf01b44f29e?anonymousKey=7a69593406aed425e244080fd10dc402a27606d7
 */
rule removeModuleClearsCrossAuth(env e, uint256 moduleId_) {
    address removed = moduleById(moduleId_);

    removeModule(e, moduleId_);

    assert !crossModuleAuth(removed);
}

/**
 * @title cross-authorization changes only through admin entry points
 * @description A cross-module authorization flag changes only through the two admin-gated entry points.
 * @link_property PM-ACCESS-INV-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/982b712c5a87416681ca2bf01b44f29e?anonymousKey=7a69593406aed425e244080fd10dc402a27606d7
 */
rule crossAuthOnlyByAdminEntryPoints(env e, method f, calldataarg args, address m)
    filtered { f -> !opaqueExternalCall(f) }
{
    bool before = crossModuleAuth(m);
    f(e, args);
    bool after = crossModuleAuth(m);

    assert before != after =>
        (f.selector == sig:setCrossModuleAuth(address,bool).selector
            || f.selector == sig:removeModule(uint256).selector)
        && hasAnyRoleCVL(currentContract, e.msg.sender, 1);
}

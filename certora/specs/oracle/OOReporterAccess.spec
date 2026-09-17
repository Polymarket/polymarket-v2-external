// ============================================================
// Properties:
//   OO-INIT-MONO-01  `requestInitialized[s]` never transitions true -> false, for any scope and
//                    any method.
//   OO-ACCESS-01     Privileged state changes only by authorized writers, in state-change form:
//                      * `aggregator` changed  => ADMIN_ROLE caller and `setAggregator`, or the
//                        one-shot `initialize`;
//                      * `requestInitialized[s]` false -> true => `createRequest` by an
//                        OPERATOR_ROLE caller, or `initializeReporterModule` by the aggregator;
//                      * roles of any user changed => the owner, or an ADMIN_ROLE caller through
//                        the Auth mixin's admin entry points, or self-renunciation, or
//                        `initialize`;
//                      * the ERC-1967 implementation changed => the owner (`_authorizeUpgrade`).
//   OO-CUSTODY-01    No method moves ERC-20 tokens or ETH out of the module, and no method
//                    grants an allowance
// ============================================================


/*
 * MODULE
 * @module OOReporterModule Registration and Access Control
 * @contract OOReporterModule
 * @impact A request could be registered twice or by an unauthorized caller, re-pointing a market at a different question
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property OO-INIT-MONO-01 A request registration never transitions from true back to false.
 * @property OO-ACCESS-01 Privileged state changes only by authorized writers.
 * @property OO-CUSTODY-01 No method moves ERC-20 value or ETH out of the module, and none grants an allowance.
 */

import "../summaries/OptimisticOraclePayout_constants.spec";
import "../summaries/OOReporterModule_call_resolution.spec";
import "../summaries/OOReporterModule_base_summaries.spec";
import "../summaries/OOReporterModule_registration_scene.spec";
import "../summaries/Solady/OwnableRoles.spec";

using DummyERC20Impl as Token;

methods {
    // ---- Ownable: constant-slot owner read ----
    function OOReporterModule.owner() external returns (address) envfree;

    // ---- Solady OwnableRoles ghost model ----
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

    // ---- ERC-1967 implementation slot (harness view over the constant slot) ----
    function OOReporterModule.implementationSlotValue() external returns (address) envfree;

    // ---- Custody probe ----
    function Token.balanceOf(address) external returns (uint256) envfree;
    function Token.allowance(address, address) external returns (uint256) envfree;

    unresolved external in OracleAggregator.reportResult(bytes32, uint256[]) => DISPATCH(optimistic=true) [
        MockArbitratorModule.onArbitrationTriggered(bytes32, bytes32)
    ];
}

// ------------------------------------------------------------
// Role bits (src/oracle/mixins/Auth.sol) and method sets
// ------------------------------------------------------------

// Role bits map onto the shared ghost model's booleans:
//   ADMIN_ROLE    = _ROLE_0 = ghostHasRole0
//   OPERATOR_ROLE = _ROLE_1 = ghostHasRole1

definition IS_INITIALIZE(method f) returns bool =
    f.selector == sig:initialize(address, address, address).selector;

definition IS_CREATE_REQUEST(method f) returns bool =
    f.selector == sig:createRequest(bytes32, bytes, uint64, uint64).selector;

definition IS_BATCH_INIT(method f) returns bool =
    f.selector == sig:initializeReporterModule(OOReporterModule.EventId, bytes).selector;

definition IS_SET_AGGREGATOR(method f) returns bool =
    f.selector == sig:setAggregator(address).selector;

// Auth mixin entry points gated on ADMIN_ROLE.
definition IS_ADMIN_ROLE_WRITER(method f) returns bool =
    f.selector == sig:removeAdmin(address).selector
        || f.selector == sig:addOperator(address).selector
        || f.selector == sig:removeOperator(address).selector;

// Owner-gated role writers: Auth's `addAdmin` plus Solady's `grantRoles` / `revokeRoles`.
definition IS_OWNER_ROLE_WRITER(method f) returns bool =
    f.selector == sig:addAdmin(address).selector
        || f.selector == sig:grantRoles(address, uint256).selector
        || f.selector == sig:revokeRoles(address, uint256).selector;

// Solady's self-service renunciation.
definition IS_RENOUNCE_ROLES(method f) returns bool =
    f.selector == sig:renounceRoles(uint256).selector;

// The UUPS entry point
definition IS_UPGRADE(method f) returns bool =
    f.selector == sig:upgradeToAndCall(address, bytes).selector;

// ------------------------------------------------------------
// OO-INIT-MONO-01 — the registration flag is monotonic
// ------------------------------------------------------------

/**
 * @title registration is monotonic
 * @description No method clears a registration: an initialized request never goes back to uninitialized.
 * @link_property OO-INIT-MONO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d820534082c54f15ac59fa35decbf500?anonymousKey=64ce5c396ed8939e38ae7a9c27f85b0c3590dfb9
 */
rule requestInitializedIsMonotonic(env e, method f, calldataarg args, bytes32 scopeKey)
filtered { f -> !f.isView && !IS_UPGRADE(f) } {
    requireSceneWiring();

    bool registeredBefore = requestInitializedAt(scopeKey);
    f(e, args);
    bool registeredAfter = requestInitializedAt(scopeKey);

    assert registeredBefore => registeredAfter,
        "a method cleared an existing request registration";
}

// ------------------------------------------------------------
// OO-ACCESS-01 — only authorized writers
// ------------------------------------------------------------

/**
 * @title registration writes require operator or aggregator
 * @description A registration appears only through createRequest by an operator, or through the aggregator batch.
 * @link_property OO-ACCESS-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d820534082c54f15ac59fa35decbf500?anonymousKey=64ce5c396ed8939e38ae7a9c27f85b0c3590dfb9
 */
rule registrationWritesRequireOperatorOrAggregator(env e, method f, calldataarg args, bytes32 scopeKey)
filtered { f -> !f.isView && !IS_UPGRADE(f) } {
    requireSceneWiring();
    bool registeredBefore = requestInitializedAt(scopeKey);
    bool callerIsOperator = ghostHasRole1[currentContract][e.msg.sender];
    bool callerIsAggregator = e.msg.sender == OracleAggregator;

    f(e, args);

    bool registeredAfter = requestInitializedAt(scopeKey);

    assert (!registeredBefore && registeredAfter) =>
        ((IS_CREATE_REQUEST(f) && callerIsOperator) || (IS_BATCH_INIT(f) && callerIsAggregator)),
        "a scope became registered outside the operator or aggregator registration paths";
}

/**
 * @title aggregator changes require admin or init
 * @description The aggregator pointer changes only through an admin setAggregator or the one-shot initialize.
 * @link_property OO-ACCESS-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d820534082c54f15ac59fa35decbf500?anonymousKey=64ce5c396ed8939e38ae7a9c27f85b0c3590dfb9
 */
rule aggregatorChangesRequireAdminOrInit(env e, method f, calldataarg args)
filtered { f -> !f.isView && !IS_UPGRADE(f) } {
    address aggregatorBefore = aggregator();
    bool callerIsAdmin = ghostHasRole0[currentContract][e.msg.sender];

    f(e, args);

    assert aggregator() != aggregatorBefore =>
        ((IS_SET_AGGREGATOR(f) && callerIsAdmin) || IS_INITIALIZE(f)),
        "the aggregator pointer changed outside setAggregator (admin) or initialize";
}

/**
 * @title role changes require an authorized writer
 * @description Roles change only for the owner, for an admin, for a user renouncing their own roles, or in initialize.
 * @link_property OO-ACCESS-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d820534082c54f15ac59fa35decbf500?anonymousKey=64ce5c396ed8939e38ae7a9c27f85b0c3590dfb9
 */
rule roleChangesRequireAuthorizedWriter(env e, method f, calldataarg args, address user)
filtered { f -> !f.isView && !IS_UPGRADE(f) } {
    requireSceneWiring();
    uint256 rolesBefore = rolesOfCVL(currentContract, user);
    bool callerIsOwner = e.msg.sender == owner();
    bool callerIsAdmin = ghostHasRole0[currentContract][e.msg.sender];

    f(e, args);

    assert rolesOfCVL(currentContract, user) != rolesBefore =>
        (IS_INITIALIZE(f)
            || (IS_OWNER_ROLE_WRITER(f) && callerIsOwner)
            || (IS_ADMIN_ROLE_WRITER(f) && callerIsAdmin)
            || (IS_RENOUNCE_ROLES(f) && user == e.msg.sender)),
        "a user's roles changed outside the owner, admin or self-renunciation paths";
}

/**
 * @title upgrades require the owner
 * @description The ERC-1967 implementation changes only for the owner.
 * @link_property OO-ACCESS-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d820534082c54f15ac59fa35decbf500?anonymousKey=64ce5c396ed8939e38ae7a9c27f85b0c3590dfb9
 */
rule implementationChangesRequireOwner(env e, method f, calldataarg args)
filtered { f -> !f.isView } {
    address implementationBefore = implementationSlotValue();
    address ownerBefore = owner();

    f(e, args);

    assert implementationSlotValue() != implementationBefore => e.msg.sender == ownerBefore,
        "the implementation slot changed for a caller that was not the owner";
}

// ------------------------------------------------------------
// OO-CUSTODY-01 — the module holds and moves no value
// ------------------------------------------------------------

/**
 * @title no value leaves the module
 * @description No method moves ERC-20 value out of the module or grants an allowance on the module behalf.
 * @link_property OO-CUSTODY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d820534082c54f15ac59fa35decbf500?anonymousKey=64ce5c396ed8939e38ae7a9c27f85b0c3590dfb9
 * @dev ETH: every entry point except the inherited payable `upgradeToAndCall` is non-payable,
 *      so the balance claim is stated as "never decreases".
 */
rule noValueLeavesTheModule(env e, method f, calldataarg args, address spender)
filtered { f -> !f.isView } {
    requireSceneWiring();
    uint256 tokenBalanceBefore = Token.balanceOf(currentContract);
    uint256 allowanceBefore = Token.allowance(currentContract, spender);
    mathint etherBefore = nativeBalances[currentContract];

    f(e, args);

    assert Token.balanceOf(currentContract) >= tokenBalanceBefore,
        "a method moved ERC-20 tokens out of the module";
    assert Token.allowance(currentContract, spender) <= allowanceBefore,
        "a method granted an ERC-20 allowance on the module's behalf";
    assert nativeBalances[currentContract] >= etherBefore,
        "a method moved ETH out of the module";
}

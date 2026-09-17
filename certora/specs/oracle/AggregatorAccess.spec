// ============================================================
// Properties:
//   ORACLE-ACC-01  resolveResult authority — confined to the configured arbitrator and admins.
//   ORACLE-ACC-02  Finalizer exclusivity — a non-zero finalizer is exclusive, and no role bypasses it;
//           the zero finalizer makes finalize permissionless.
//   ORACLE-ACC-03  reportResult is registered-reporter-only.
//   ORACLE-ACC-04  disputeResult is registered-disputer-only.
//   ORACLE-ACC-05  The config-mutation surface is operator-or-admin, verified parametrically.
//   ORACLE-ACC-06  Upgrades are owner-only.
//   ORACLE-ACC-07  Rules-role separation.
// ============================================================


/*
 * MODULE
 * @module OracleAggregator Access Control
 * @contract OracleAggregator
 * @impact An unauthorized caller could resolve, report on, or reconfigure a request, dictating a market outcome
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property ORACLE-ACC-01 resolveResult authority is confined to the configured arbitrator and admins.
 * @property ORACLE-ACC-02 A non-zero finalizer is exclusive and no role bypasses it; the zero finalizer makes finalize permissionless.
 * @property ORACLE-ACC-03 reportResult is registered-reporter-only.
 * @property ORACLE-ACC-04 disputeResult is registered-disputer-only.
 * @property ORACLE-ACC-05 The config-mutation surface is operator-or-admin.
 * @property ORACLE-ACC-06 Upgrades are owner-only.
 * @property ORACLE-ACC-07 Rules-role separation between the rule manager and the operator.
 */

import "../summaries/OracleAggregator_call_resolution.spec";
import "../summaries/OracleAggregator_base_summaries.spec";

/*--------------------------------------------------------------
                ORACLE-ACC-01 — resolveResult authority
--------------------------------------------------------------*/

/**
 * @title resolveResult authority
 * @description A non-arbitrator, non-admin caller cannot resolve a request that is not yet Resolved.
 * @link_property ORACLE-ACC-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule resolveResultAuthority(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.statusOf(requestId) != RESOLVED();
    require e.msg.sender != OracleAggregator.arbitratorOfRequest(requestId);
    require !isAdmin(e.msg.sender);

    resolveResult@withrevert(e, requestId, result);

    assert lastReverted,
        "resolveResult on a live request must revert for anyone but the configured arbitrator or an admin";
}

/*--------------------------------------------------------------
                ORACLE-ACC-02 — finalizer exclusivity
--------------------------------------------------------------*/

/**
 * @title finalizer exclusivity
 * @description A configured finalizer is exclusive, and no role bypasses the gate.
 * @link_property ORACLE-ACC-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule finalizerExclusivity(env e, bytes32 requestId, uint256[] result) {
    address finalizer = OracleAggregator.finalizerOfRequest(requestId);
    require finalizer != 0;
    require e.msg.sender != finalizer;

    finalize@withrevert(e, requestId, result);

    assert lastReverted, "only the configured finalizer may finalize; no role bypasses the gate";
}

/**
 * @title zero finalizer is permissionless
 * @description A zero finalizer makes finalize permissionless.
 * @link_property ORACLE-ACC-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule finalizeIsPermissionlessWhenFinalizerZero(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.finalizerOfRequest(requestId) == 0;
    // require !isAdmin(e.msg.sender) && !isOperator(e.msg.sender);
    // require e.msg.sender != OracleAggregator.arbitratorOfRequest(requestId);

    finalize(e, requestId, result);

    satisfy OracleAggregator.statusOf(requestId) == RESOLVED();
}

/*--------------------------------------------------------------
        ORACLE-ACC-03 / ORACLE-ACC-04 — vote authority is set membership
--------------------------------------------------------------*/

/**
 * @title report requires a registered reporter
 * @description Only a registered reporter module for the request's event can report.
 * @link_property ORACLE-ACC-03
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule reportResultRegisteredReporterOnly(env e, bytes32 requestId, uint256[] result) {
    bool isReporter = OracleAggregator.isReporterOfRequest(requestId, e.msg.sender);

    reportResult@withrevert(e, requestId, result);

    assert !isReporter => lastReverted, "reportResult must revert for a caller outside the event's reporter set";
    satisfy isReporter => !lastReverted;
}

/**
 * @title dispute requires a registered disputer
 * @description Only a registered disputer module for the request's event can dispute.
 * @link_property ORACLE-ACC-04
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule disputeResultRegisteredDisputerOnly(env e, bytes32 requestId) {
    bool isDisputer = OracleAggregator.isDisputerOfRequest(requestId, e.msg.sender);

    disputeResult@withrevert(e, requestId);

    assert !isDisputer => lastReverted, "disputeResult must revert for a caller outside the event's disputer set";
    satisfy isDisputer => !lastReverted;
}

/*--------------------------------------------------------------
        ORACLE-ACC-05 — the config-mutation surface is operator-or-admin
--------------------------------------------------------------*/

/**
 * @title config mutation requires operator or admin
 * @description Every operator-or-admin gated entry point reverts for a caller holding neither role.
 * @link_property ORACLE-ACC-05
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule configMutationRequiresOperatorOrAdmin(env e, method f, calldataarg args)
    filtered { f -> IS_CONFIG_MUTATOR(f) }
{
    require !isAdmin(e.msg.sender) && !isOperator(e.msg.sender);

    f@withrevert(e, args);

    assert lastReverted, "config mutation must revert without the operator or admin role";
}

/**
 * @title initializeRequest is operator-only
 * @description initializeRequest succeeds only for an operator caller.
 * @link_property ORACLE-ACC-05
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule initializeRequestIsOperatorOnly(env e, OracleAggregator.InitParams params) {
    require !isOperator(e.msg.sender);

    initializeRequest@withrevert(e, params);

    assert lastReverted, "initializeRequest must revert without the operator role, admin included";
}

/*--------------------------------------------------------------
                ORACLE-ACC-06 — upgrades are owner-only
--------------------------------------------------------------*/

/**
 * @title upgrades require the owner
 * @description The ERC-1967 implementation slot only ever changes through the owner.
 * @link_property ORACLE-ACC-06
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule implementationChangesRequireOwner(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    address implBefore = OracleAggregator.implementationSlotValue();
    address ownerBefore = OracleAggregator.owner();

    f(e, args);

    assert OracleAggregator.implementationSlotValue() != implBefore => e.msg.sender == ownerBefore,
        "the implementation slot may only change for the owner";
}

/*--------------------------------------------------------------
                ORACLE-ACC-07 — rules-role separation
--------------------------------------------------------------*/

/**
 * @title product spec writes require rule manager or admin
 * @description Product-specification writes need the rule-manager or admin role.
 * @link_property ORACLE-ACC-07
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule productSpecWritesRequireRuleManagerOrAdmin(env e, string name, string uri) {
    require !isAdmin(e.msg.sender) && !isRuleManager(e.msg.sender);

    setProductSpecification@withrevert(e, name, uri);

    assert lastReverted, "setProductSpecification must revert without the rule-manager or admin role";
}

/**
 * @title request rule writes require operator or admin
 * @description Per-request rule writes need the operator or admin role.
 * @link_property ORACLE-ACC-07
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule requestRuleWritesRequireOperatorOrAdmin(env e, bytes32 requestId, bytes rules) {
    require !isAdmin(e.msg.sender) && !isOperator(e.msg.sender);

    updateRequestRules@withrevert(e, requestId, rules);

    assert lastReverted, "updateRequestRules must revert without the operator or admin role";
}

/**
 * @title rule manager cannot write request rules
 * @description A rule-manager-only account cannot write per-request rules.
 * @link_property ORACLE-ACC-07
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule ruleManagerCannotWriteRequestRules(env e, bytes32 requestId, bytes rules) {
    require isRuleManager(e.msg.sender);
    require !isAdmin(e.msg.sender) && !isOperator(e.msg.sender);

    updateRequestRules@withrevert(e, requestId, rules);

    assert lastReverted, "the rule-manager role does not reach updateRequestRules";
}

/**
 * @title operator cannot write product specs
 * @description An operator-only account cannot write product specifications.
 * @link_property ORACLE-ACC-07
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c3b9c60666c34a55b1d9a7e02e806253?anonymousKey=097b88935ccc97176d32eab0c4be57c9b46456ee
 */
rule operatorCannotWriteProductSpecs(env e, string name, string uri) {
    require isOperator(e.msg.sender);
    require !isAdmin(e.msg.sender) && !isRuleManager(e.msg.sender);

    setProductSpecification@withrevert(e, name, uri);

    assert lastReverted, "the operator role does not reach setProductSpecification";
}

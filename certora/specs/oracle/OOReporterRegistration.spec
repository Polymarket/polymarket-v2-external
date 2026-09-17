// ============================================================
// Property: a requestId can be registered EXACTLY ONCE globally — through `createRequest` or
// through the aggregator's `initializeReporterModule` batch, never both, never twice — and on
// a successful batch every registration it performed belongs to the supplied event
// ============================================================


/*
 * MODULE
 * @module OOReporterModule Registration and Access Control
 * @contract OOReporterModule
 * @impact A request could be registered twice or by an unauthorized caller, re-pointing a market at a different question
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 *
 * PROPERTIES
 * @property OO-REG-01 A requestId is registered exactly once globally across both entry points, and every registration in a successful batch belongs to the supplied event.
 */

import "../summaries/OptimisticOraclePayout_constants.spec";
import "../summaries/OOReporterModule_call_resolution.spec";
import "../summaries/OOReporterModule_base_summaries.spec";
import "../summaries/OOReporterModule_registration_scene.spec";

methods {
    // Harness projections: the scope -> event relation, as raw bytes32 on both sides, so the
    // batch's `scopeId.eventId() == _eventId` check can be restated in CVL.
    function OOReporterModule.eventIdOfScopeKey(bytes32) external returns (bytes32) envfree;
    function OOReporterModule.eventIdAsBytes32(OOReporterModule.EventId) external returns (bytes32) envfree;
}

// ------------------------------------------------------------
// OO-REG-01 — single registration per scope, across both entry points
// ------------------------------------------------------------

/**
 * @title createRequest is one-shot
 * @description createRequest cannot register a scope that is already registered.
 * @link_property OO-REG-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e9657651db184e2196f5a7e7e731c307?anonymousKey=f89449a2ae1316dc1a94a991a93589edf7549c35
 */
rule createRequestIsOneShot(env e, bytes32 rid, bytes requestRules, uint64 minLiveness, uint64 maxLiveness) {
    requireSceneWiring();
    require requestInitializedAt(rid), "the scope is already registered";

    createRequest@withrevert(e, rid, requestRules, minLiveness, maxLiveness);

    assert lastReverted, "createRequest registered an already-registered scope a second time";
}

/**
 * @title the batch cannot re-register a scope
 * @description The aggregator batch cannot re-register a scope that is already registered.
 * @link_property OO-REG-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e9657651db184e2196f5a7e7e731c307?anonymousKey=f89449a2ae1316dc1a94a991a93589edf7549c35
 */
rule batchCannotReRegisterAScope(env e, OOReporterModule.EventId eventId, bytes data, bytes32 scopeKey) {
    requireSceneWiring();
    require requestInitializedAt(scopeKey), "the scope is already registered";

    initializeReporterModule@withrevert(e, eventId, data);
    bool reverted = lastReverted;

    assert requestInitializedAt(scopeKey),
        "a batch cleared an existing registration";
}

/**
 * @title batch registrations belong to the supplied event
 * @description Every scope a successful batch registered to belongs to the event the aggregator supplied.
 * @link_property OO-REG-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e9657651db184e2196f5a7e7e731c307?anonymousKey=f89449a2ae1316dc1a94a991a93589edf7549c35
 */
rule batchRegistrationsBelongToTheSuppliedEvent(
    env e,
    OOReporterModule.EventId eventId,
    bytes data,
    bytes32 scopeKey
) {
    requireSceneWiring();
    require !requestInitializedAt(scopeKey), "an unregistered scope before the batch";

    initializeReporterModule(e, eventId, data);

    assert requestInitializedAt(scopeKey) => eventIdOfScopeKey(scopeKey) == eventIdAsBytes32(eventId),
        "the batch registered a scope belonging to a different event";
}

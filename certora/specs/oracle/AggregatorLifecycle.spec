// ============================================================
// Properties:
//   ORACLE-LIFE-01  Status is monotone with only three reachable transitions:
//                   None -> ArbitrationRequested, None -> Resolved, ArbitrationRequested -> Resolved.
//   ORACLE-LIFE-02  No resolution without quorum or authority — every transition to Resolved is
//                   caused either by a `finalize` whose proposal is quorum-backed, or by
//                   `resolveResult` from the configured arbitrator or an admin.
//   ORACLE-RES-01   Idempotent terminal no-op: on an already-Resolved request, `resolveResult`
//                   silently no-ops for any caller, authorized or not.
//   ORACLE-TGT-02   Exactly-once target write: `finalizeCount(r) <= 1` over the contract lifetime.
//
// ORACLE-TGT-02 is proved as a three-part decomposition:
//   (a) `targetWritesOnlyFromFinalizeOrResolve` — no other entry point can reach the target;
//   (b) `resolvedRequestCannotBeFinalizedAgain` — after Resolved, `finalize` reverts;
//   (c) ORACLE-RES-01;
// together with `statusIsMonotoneWithThreeTransitions` making Resolved terminal, so the second write
// for a given request is unreachable through either path.
// ============================================================


/*
 * MODULE
 * @module OracleAggregator Resolution Lifecycle
 * @contract OracleAggregator
 * @impact A request could resolve twice, resolve without authority, or report to the wrong condition, settling a market incorrectly
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property ORACLE-LIFE-01 Status is monotone with only three reachable transitions.
 * @property ORACLE-LIFE-02 No resolution without quorum or authority.
 * @property ORACLE-RES-01 On an already-Resolved request, resolveResult is a no-op for any caller.
 * @property ORACLE-TGT-02 Once a request has been settled, it can never be settled again.
 */

import "../summaries/OracleAggregator_call_resolution.spec";
import "../summaries/OracleAggregator_base_summaries.spec";
import "./AggregatorVotes.spec";

use invariant proposalImpliesRegisteredRequest;
use invariant thresholdBacksLiveProposal;
use invariant unregisteredRequestHasCleanDisputeState;
use invariant disputeQuorumImpliesEscalation;

/*--------------------------------------------------------------
        ORACLE-LIFE-01 — forward-only lifecycle, three edges
--------------------------------------------------------------*/

/**
 * @title Active is never persisted
 * @description The Active status is never written to storage, so it cannot be observed.
 * @link_property ORACLE-LIFE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/36788fcaa7914a98aee9a6aa98903c9a?anonymousKey=f5bc51a5df829c2836d101c1fec1e40635530528
 */
invariant activeIsNeverPersisted(bytes32 requestId)
    OracleAggregator.statusOf(requestId) != ACTIVE()
    filtered { f -> !f.isView && !IS_UPGRADE(f) }

/**
 * @title status is monotone with three transitions
 * @description Status never moves backwards, and only along the three reachable edges.
 * @link_property ORACLE-LIFE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/553fb6e835e049aa98c4cd886e2d9f5c?anonymousKey=c111d3fc0d6f1919b898c4b3e8de15a7d4a63803
 */
rule statusIsMonotoneWithThreeTransitions(env e, method f, calldataarg args, bytes32 requestId)
    filtered { f -> !f.isView && !IS_UPGRADE(f) }
{
    requireInvariant activeIsNeverPersisted(requestId);
    uint8 statusBefore = OracleAggregator.statusOf(requestId);

    f(e, args);

    uint8 statusAfter = OracleAggregator.statusOf(requestId);

    assert statusAfter >= statusBefore, "resolution status is monotone";
    assert statusAfter != statusBefore
        => ((statusBefore == NONE() && statusAfter == ARBITRATION_REQUESTED())
            || (statusBefore == NONE() && statusAfter == RESOLVED())
            || (statusBefore == ARBITRATION_REQUESTED() && statusAfter == RESOLVED())),
        "only None->ArbitrationRequested, None->Resolved and ArbitrationRequested->Resolved occur";
}

/*--------------------------------------------------------------
    ORACLE-LIFE-02 — no resolution without quorum or authority
--------------------------------------------------------------*/

/**
 * @title resolution needs quorum or authority
 * @description Every transition to Resolved is a quorum-backed finalize or an authorized override.
 * @link_property ORACLE-LIFE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/02090a0b788d4b988dd165d70002f3c2?anonymousKey=6872535c43c323c5b2288bc232df828adaa947f9
 */
rule resolvedOnlyViaQuorumOrAuthority(env e, method f, calldataarg args, bytes32 requestId)
    filtered { f -> !f.isView && !IS_UPGRADE(f) }
{
    require OracleAggregator.statusOf(requestId) != RESOLVED(), "we start from a non-resolved status";

    bytes32 proposalBefore = OracleAggregator.proposedHashOf(requestId);
    mathint votesForProposal =
        to_mathint(OracleAggregator.voteCount(OracleAggregator.voteKeyFor(requestId, proposalBefore)));
    mathint reporterThreshold = to_mathint(OracleAggregator.reporterThresholdOfRequest(requestId));

    requireInvariant thresholdBacksLiveProposal(requestId);

    bool callerIsArbitrator = e.msg.sender == OracleAggregator.arbitratorOfRequest(requestId);
    bool callerIsAdmin = isAdmin(e.msg.sender);

    f(e, args);

    assert OracleAggregator.statusOf(requestId) == RESOLVED()
        => ((f.selector == sig:finalize(bytes32, uint256[]).selector && proposalBefore != to_bytes32(0)
                && votesForProposal >= reporterThreshold)
            || (f.selector == sig:resolveResult(bytes32, uint256[]).selector
                && (callerIsArbitrator || callerIsAdmin))),
        "a request becomes Resolved only via quorum-backed finalize or an authorized override";
}

/*--------------------------------------------------------------
        ORACLE-RES-01 — idempotent terminal no-op
--------------------------------------------------------------*/

/**
 * @title resolveResult on a Resolved request is a no-op
 * @description On a Resolved request, resolveResult no-ops silently for any caller, authorized or not.
 * @link_property ORACLE-RES-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/02090a0b788d4b988dd165d70002f3c2?anonymousKey=6872535c43c323c5b2288bc232df828adaa947f9
 */
rule resolvedResolveResultIsSilentNoOpForAnyCaller(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.statusOf(requestId) == RESOLVED();
    requireResolvableRequestId(requestId);
    requireRecordingTarget(requestId);
    require e.msg.value == 0;
    require !OracleAggregator.globalPaused();

    bytes32 proposalBefore = OracleAggregator.proposedHashOf(requestId);
    uint16 disputesBefore = OracleAggregator.disputeCountOf(requestId);
    uint40 windowBefore = OracleAggregator.windowEndOf(requestId);
    bytes32 conflictBefore = OracleAggregator.conflictingResultHash(requestId);
    uint256 targetReportsBefore = BinaryReporterTargetMock.reportCount();

    resolveResult@withrevert(e, requestId, result);

    assert !lastReverted, "a replayed resolveResult on a Resolved request should not revert";
    assert OracleAggregator.statusOf(requestId) == RESOLVED()
        && OracleAggregator.proposedHashOf(requestId) == proposalBefore
        && OracleAggregator.disputeCountOf(requestId) == disputesBefore
        && OracleAggregator.windowEndOf(requestId) == windowBefore
        && OracleAggregator.conflictingResultHash(requestId) == conflictBefore,
        "the replay leaves the resolution state untouched";
    assert BinaryReporterTargetMock.reportCount() == targetReportsBefore,
        "the replay makes no target call";
}

/*--------------------------------------------------------------
        ORACLE-TGT-02 — exactly-once target write
--------------------------------------------------------------*/

/**
 * @title only finalize and resolveResult reach the target
 * @description No entry point other than finalize and resolveResult can ever write to the resolution target.
 * @link_property ORACLE-TGT-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/02090a0b788d4b988dd165d70002f3c2?anonymousKey=6872535c43c323c5b2288bc232df828adaa947f9
 */
rule targetWritesOnlyFromFinalizeOrResolve(env e, method f, calldataarg args)
    filtered { f -> !f.isView && !IS_UPGRADE(f) }
{
    uint256 targetReportsBefore = BinaryReporterTargetMock.reportCount();

    f(e, args);

    assert BinaryReporterTargetMock.reportCount() != targetReportsBefore
        => (f.selector == sig:finalize(bytes32, uint256[]).selector
            || f.selector == sig:resolveResult(bytes32, uint256[]).selector),
        "no entry point other than finalize and resolveResult reports to the target";
}

/**
 * @title a Resolved request cannot be finalized again
 * @description Once a request is Resolved, finalize always reverts.
 * @link_property ORACLE-TGT-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/02090a0b788d4b988dd165d70002f3c2?anonymousKey=6872535c43c323c5b2288bc232df828adaa947f9
 */
rule resolvedRequestCannotBeFinalizedAgain(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.statusOf(requestId) == RESOLVED();

    finalize@withrevert(e, requestId, result);

    assert lastReverted, "finalize must revert on an already-Resolved request";
}

/**
 * @title a request in arbitration cannot be finalized
 * @description While a request is in arbitration, finalize always reverts.
 * @link_property ORACLE-TGT-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/02090a0b788d4b988dd165d70002f3c2?anonymousKey=6872535c43c323c5b2288bc232df828adaa947f9
 */
rule arbitrationRequestedRequestCannotBeFinalized(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.statusOf(requestId) == ARBITRATION_REQUESTED();

    finalize@withrevert(e, requestId, result);

    assert lastReverted, "finalize must revert once arbitration has been requested";
}

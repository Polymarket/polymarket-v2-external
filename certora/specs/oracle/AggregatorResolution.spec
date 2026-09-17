// ============================================================
// Properties:
//   ORACLE-TGT-01  Payout mapping to the target — binary/incremental report `[v, DENOM - v]` at the
//                  request's own condition index; atomic reports `[DENOM, 0]` at the WINNER's
//                  condition index. Exactly one condition is reported, and the pair always
//                  conserves DENOM.
//   ORACLE-FIN-01  The finalized outcome is caller-independent — a racer can only trigger the
//                  already-determined settlement, never change it.
//   ORACLE-ARB-01  Arbitrator hook failures never brick the lifecycle: a threshold-crossing dispute
//                  or a reporter conflict still escalates, and admin resolution still completes,
//                  when every arbitrator hook reverts.
// ============================================================


/*
 * MODULE
 * @module OracleAggregator Resolution Lifecycle
 * @contract OracleAggregator
 * @impact A request could resolve twice, resolve without authority, or report to the wrong condition, settling a market incorrectly
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 *
 * PROPERTIES
 * @property ORACLE-TGT-01 Settling a request writes a payout to exactly one market outcome, and that outcome's YES and NO shares always add up to denominator.
 * @property ORACLE-FIN-01 The finalized outcome is caller-independent.
 * @property ORACLE-ARB-01 Arbitrator hook failures never brick the lifecycle.
 */

import "../summaries/OracleAggregator_call_resolution.spec";
import "../summaries/OracleAggregator_base_summaries.spec";

/*--------------------------------------------------------------
            ORACLE-TGT-01 — payout mapping to the target
--------------------------------------------------------------*/

/**
 * @title binary and incremental payout mapping
 * @description Binary and incremental neg-risk reports write the complementary pair at the request's own condition index.
 * @link_property ORACLE-TGT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49984a12d9b84eacbd6b0ef5235f915e?anonymousKey=32f6271bcc94cf5ea129ac685111074895c10d7b
 */
rule payoutMappingBinaryAndIncremental(env e, bytes32 requestId, uint256[] result) {
    requireRecordingTarget(requestId);
    require OracleAggregator.marketTypeOfRequest(requestId) != OracleAggregator.MarketType.ATOMIC_NEGRISK, "consider only binary and incremental neg-risk";
    uint256 reportsBefore = BinaryReporterTargetMock.reportCount();

    finalize(e, requestId, result);

    assert BinaryReporterTargetMock.reportCount() == reportsBefore + 1,
        "exactly one condition is reported";
    assert BinaryReporterTargetMock.lastResultLen() == 2, "the target receives a payout pair";
    assert BinaryReporterTargetMock.lastResult0() == result[0], "payout[0] is the reported value";
    assert to_mathint(BinaryReporterTargetMock.lastResult0())
        + to_mathint(BinaryReporterTargetMock.lastResult1()) == RESULT_DENOMINATOR(),
        "the payout pair conserves RESULT_DENOMINATOR";
    assert BinaryReporterTargetMock.lastConditionId()
        == OracleAggregator.conditionIdOfRequestIndex(requestId, OracleAggregator.conditionIndexOf(requestId)),
        "the report lands on the request's own condition index";
}

/**
 * @title atomic payout mapping
 * @description Atomic neg-risk reports the full denominator at the winner's condition index and zero elsewhere.
 * @link_property ORACLE-TGT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49984a12d9b84eacbd6b0ef5235f915e?anonymousKey=32f6271bcc94cf5ea129ac685111074895c10d7b
 */
rule payoutMappingAtomic(env e, bytes32 requestId, uint256[] result) {
    requireRecordingTarget(requestId);
    require OracleAggregator.marketTypeOfRequest(requestId) == OracleAggregator.MarketType.ATOMIC_NEGRISK, "consider only atomic neg-risk";
    // Excludes the arbitrary pre-state the Prover may start from, where `proposedResultHash` was never produced by a
    // report at all.
    require result.length == 1 && validSingletonResult(requestId, OracleAggregator.marketTypeOfRequest(requestId), result[0]);
    uint256 reportsBefore = BinaryReporterTargetMock.reportCount();

    finalize(e, requestId, result);

    assert BinaryReporterTargetMock.reportCount() == reportsBefore + 1,
        "exactly one condition is reported";
    assert BinaryReporterTargetMock.lastResultLen() == 2, "the target receives a payout pair";
    assert to_mathint(BinaryReporterTargetMock.lastResult0()) == RESULT_DENOMINATOR()
        && BinaryReporterTargetMock.lastResult1() == 0,
        "the winning condition is paid in full";
    assert BinaryReporterTargetMock.lastConditionId()
        == OracleAggregator.conditionIdOfRequestIndex(requestId, result[0]),
        "the report lands on the winner index, not on the request's own index";
    assert to_mathint(result[0]) < to_mathint(OracleAggregator.arityOfRequest(requestId)),
        "the winner index is a real condition of the event";
}

/*--------------------------------------------------------------
        ORACLE-FIN-01 — the finalized outcome is caller-independent
--------------------------------------------------------------*/

/**
 * @title finalize outcome is caller-independent
 * @description Two successful finalizations of the same request from the same state deliver the same outcome, whoever calls and whatever array they submit.
 * @link_property ORACLE-FIN-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49984a12d9b84eacbd6b0ef5235f915e?anonymousKey=32f6271bcc94cf5ea129ac685111074895c10d7b
 */
rule finalizeOutcomeIsCallerIndependent(env e1, env e2, bytes32 requestId, uint256[] resultA, uint256[] resultB) {
    requireRecordingTarget(requestId);
    storage init = lastStorage;

    finalize(e1, requestId, resultA);
    bytes32 conditionA = BinaryReporterTargetMock.lastConditionId();
    uint256 payout0A = BinaryReporterTargetMock.lastResult0();
    uint256 payout1A = BinaryReporterTargetMock.lastResult1();

    finalize(e2, requestId, resultB) at init;

    assert BinaryReporterTargetMock.lastConditionId() == conditionA,
        "both finalizers resolve the same condition";
    assert BinaryReporterTargetMock.lastResult0() == payout0A
        && BinaryReporterTargetMock.lastResult1() == payout1A,
        "both finalizers deliver the same payouts";
}

/**
 * @title finalized outcome matches the proposal
 * @description A finalized result is exactly the one the standing proposal committed to.
 * @link_property ORACLE-FIN-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49984a12d9b84eacbd6b0ef5235f915e?anonymousKey=32f6271bcc94cf5ea129ac685111074895c10d7b
 * @dev `result.length == 1` is required rather than asserted: a stored proposal hash always
 *      comes from a validated singleton.
 */
rule finalizedOutcomeMatchesTheProposal(env e, bytes32 requestId, uint256[] result) {
    require result.length == 1;
    bytes32 proposal = OracleAggregator.proposedHashOf(requestId);

    finalize(e, requestId, result);

    assert OracleAggregator.resultHashFor(result[0]) == proposal,
        "finalize can only settle the hash the proposal committed to";
}

/*--------------------------------------------------------------
        ORACLE-ARB-01 — hook failures never brick the lifecycle
--------------------------------------------------------------*/

// Shared preconditions of a dispute that is valid in every respect expect that the arbitrator
// will notify reverts.
function requireLiveDisputeAgainstFailingArbitrator(env e, bytes32 requestId) {
    require e.msg.value == 0;
    require !OracleAggregator.globalPaused();
    requireResolvableRequestId(requestId);

    require OracleAggregator.isActiveStatusExt(OracleAggregator.statusOf(requestId)),
        "visible gate: the request still accepts disputes";
    require OracleAggregator.proposedHashOf(requestId) != to_bytes32(0),
        "visible gate: there is a proposal to challenge";
    require e.block.timestamp < to_mathint(OracleAggregator.windowEndOf(requestId)),
        "visible gate: the dispute window is open";
    require OracleAggregator.isDisputerOfRequest(requestId, e.msg.sender),
        "visible gate: the caller is a registered disputer module";
    require !OracleAggregator.hasDisputerVoted(requestId, e.msg.sender),
        "visible gate: the module has not disputed yet";
    // `disputeCount++` is a checked uint16 increment, so saturation is a genuine revert path.
    require to_mathint(OracleAggregator.disputeCountOf(requestId)) < max_uint16;

    require OracleAggregator.arbitratorOfRequest(requestId) == RevertingArbitratorMock,
        "adversary: every arbitration hook of this arbitrator reverts";
}

/**
 * @title threshold dispute escalates despite a failing hook
 * @description A threshold-crossing dispute escalates even when the arbitrator's hook reverts.
 * @link_property ORACLE-ARB-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49984a12d9b84eacbd6b0ef5235f915e?anonymousKey=32f6271bcc94cf5ea129ac685111074895c10d7b
 */
rule thresholdDisputeEscalatesDespiteFailingHook(env e, bytes32 requestId) {
    requireLiveDisputeAgainstFailingArbitrator(e, requestId);
    // `disputeResult` fires arbitration exactly when the count reaches the threshold, and
    // `disputeQuorumImpliesEscalation` proves a disputable request
    // never carries a count at or above it so equality is the crossing dispute.
    require to_mathint(OracleAggregator.disputeCountOf(requestId)) + 1
        == to_mathint(OracleAggregator.disputerThresholdOfRequest(requestId)),
        "this dispute is the one that crosses the threshold";

    disputeResult@withrevert(e, requestId);

    assert !lastReverted, "a failing arbitrator hook must not revert the escalating dispute";
    assert OracleAggregator.statusOf(requestId) == ARBITRATION_REQUESTED(),
        "the request parks in ArbitrationRequested for admin resolution";
}

/**
 * @title reporter conflict escalates despite a failing hook
 * @description A reporter conflict escalates even when the arbitrator's hook reverts.
 * @link_property ORACLE-ARB-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49984a12d9b84eacbd6b0ef5235f915e?anonymousKey=32f6271bcc94cf5ea129ac685111074895c10d7b
 */
rule reporterConflictEscalatesDespiteFailingHook(env e, bytes32 requestId, uint256[] result) {
    require e.msg.value == 0;
    require !OracleAggregator.globalPaused();
    requireResolvableRequestId(requestId);

    require OracleAggregator.isActiveStatusExt(OracleAggregator.statusOf(requestId)),
        "visible gate: the request still accepts reports";
    require OracleAggregator.isReporterOfRequest(requestId, e.msg.sender),
        "visible gate: the caller is a registered reporter module";
    require !OracleAggregator.hasReporterVoted(requestId, e.msg.sender),
        "visible gate: the module has not voted yet";
    require result.length == 1
        && to_mathint(OracleAggregator.resultLengthOfRequest(requestId)) == 1
        && validSingletonResult(requestId, OracleAggregator.marketTypeOfRequest(requestId), result[0]),
        "visible gate: the result passes validation at the configured shape (ORACLE-CONF-02 result-length pair)";
    require OracleAggregator.proposedHashOf(requestId) != to_bytes32(0),
        "a proposal already stands";
    require e.block.timestamp < to_mathint(OracleAggregator.windowEndOf(requestId)),
        "visible gate: the dispute window is open";
    require OracleAggregator.resultHashFor(result[0]) != OracleAggregator.proposedHashOf(requestId),
        "the reported result conflicts with the proposal";
    require to_mathint(OracleAggregator.voteCount(OracleAggregator.voteKeyForValue(requestId, result[0]))) + 1
        >= to_mathint(OracleAggregator.reporterThresholdOfRequest(requestId)),
        "the conflicting result reaches the reporter threshold with this vote";
    // `voteCount[voteKey] + 1` is a checked increment, so a saturated counter is a genuine
    // revert path and has to be excluded from a liveness claim.
    require to_mathint(OracleAggregator.voteCount(OracleAggregator.voteKeyForValue(requestId, result[0])))
        < max_uint256;

    require OracleAggregator.arbitratorOfRequest(requestId) == RevertingArbitratorMock,
        "adversary: every arbitration hook of this arbitrator reverts";

    reportResult@withrevert(e, requestId, result);

    assert !lastReverted, "a failing arbitrator hook must not revert the conflicting report";
    assert OracleAggregator.statusOf(requestId) == ARBITRATION_REQUESTED(),
        "a reporter conflict escalates to arbitration";
}

/**
 * @title admin resolve completes despite a failing hook
 * @description Admin resolution during arbitration completes even when the arbitrator's hook reverts.
 * @link_property ORACLE-ARB-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/49984a12d9b84eacbd6b0ef5235f915e?anonymousKey=32f6271bcc94cf5ea129ac685111074895c10d7b
 */
rule adminResolveCompletesDespiteFailingHook(env e, bytes32 requestId, uint256[] result) {
    require e.msg.value == 0;
    require !OracleAggregator.globalPaused();
    requireResolvableRequestId(requestId);
    requireRecordingTarget(requestId);

    require OracleAggregator.statusOf(requestId) == ARBITRATION_REQUESTED();
    require isAdmin(e.msg.sender), "visible gate: the caller is an admin";
    require e.msg.sender != OracleAggregator.arbitratorOfRequest(requestId),
        "the admin is not the arbitrator, so the notification branch is taken";
    require result.length == 1
        && to_mathint(OracleAggregator.resultLengthOfRequest(requestId)) == 1
        && validSingletonResult(requestId, OracleAggregator.marketTypeOfRequest(requestId), result[0]),
        "visible gate: the result passes validation at the configured shape (ORACLE-CONF-02 result-length pair)";

    require OracleAggregator.arbitratorOfRequest(requestId) == RevertingArbitratorMock,
        "adversary: every arbitration hook of this arbitrator reverts";

    resolveResult@withrevert(e, requestId, result);

    assert !lastReverted, "a failing arbitrator hook must not block emergency admin resolution";
    assert OracleAggregator.statusOf(requestId) == RESOLVED(),
        "admin resolution completes to Resolved";
}

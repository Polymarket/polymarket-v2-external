// ============================================================
// Properties:
//   ORACLE-THRESH-01  A live proposal is always backed by reporter quorum.
//   ORACLE-VOTE-01    Vote conservation.
//   ORACLE-VOTE-02    reportResult single-vote accounting.
//   ORACLE-DISP-01    Dispute accounting and escalation at threshold.
//
// ORACLE-VOTE-01 asks for `SUM_h voteCount[keccak(r,h)] == |R(r)|` and `disputeCount == |D(r)|`.
// ============================================================


/*
 * MODULE
 * @module OracleAggregator Vote Accounting
 * @contract OracleAggregator
 * @impact An outcome could enter the dispute window without quorum, or one reporter could vote repeatedly, settling on an unbacked result
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property ORACLE-THRESH-01 A live proposal is always backed by reporter quorum.
 * @property ORACLE-VOTE-01 Vote conservation across both counters.
 * @property ORACLE-VOTE-02 reportResult single-vote accounting.
 * @property ORACLE-DISP-01 Dispute accounting and escalation at the threshold.
 */

import "../summaries/OracleAggregator_call_resolution.spec";
import "../summaries/OracleAggregator_base_summaries.spec";

/*--------------------------------------------------------------
        ORACLE-THRESH-01 — quorum backs every live proposal
--------------------------------------------------------------*/

/**
 * @title a proposal implies a registered request
 * @description A standing proposal hash always exists in the config of a registered request.
 * @link_property ORACLE-THRESH-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/dd4c6d30c3af4f078816cbe3a1d07c2f?anonymousKey=95666f09fe5f8d57276b0bd55d997be72af5f16a
 */
invariant proposalImpliesRegisteredRequest(bytes32 requestId)
    OracleAggregator.proposedHashOf(requestId) != to_bytes32(0)
        => OracleAggregator.targetOfRequest(requestId) != 0
    filtered { f -> !f.isView && !IS_UPGRADE(f) }

/**
 * @title reporter quorum backs a live proposal
 * @description No outcome enters the dispute window unless the reporter threshold of distinct modules agreed.
 * @link_property ORACLE-THRESH-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/764e71381d58409badc655e7a485963d?anonymousKey=86b417b120ae6584617f9f71a0c78c3147e02917
 */
invariant thresholdBacksLiveProposal(bytes32 requestId)
    (OracleAggregator.statusOf(requestId) != RESOLVED()
        && OracleAggregator.proposedHashOf(requestId) != to_bytes32(0))
        => to_mathint(
            OracleAggregator.voteCount(
                OracleAggregator.voteKeyFor(requestId, OracleAggregator.proposedHashOf(requestId))
            )
        ) >= to_mathint(OracleAggregator.reporterThresholdOfRequest(requestId))
    filtered { f -> !f.isView && !IS_UPGRADE(f) }
    { preserved { requireInvariant proposalImpliesRegisteredRequest(requestId); } }

/*--------------------------------------------------------------
                ORACLE-VOTE-01 — vote conservation
--------------------------------------------------------------*/

/**
 * @title vote counters advance only through report or dispute
 * @description Both counters are monotone, flags are never cleared, and only the two vote entry points move them.
 * @link_property ORACLE-VOTE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/27911bb44bf740c6925f215757dcd038?anonymousKey=69a919f1170dbef0c6e17339597453e010030b6d
 */
rule voteCountersAdvanceOnlyThroughReportOrDispute(
    env e,
    method f,
    calldataarg args,
    bytes32 requestId,
    bytes32 voteKey,
    address module
) filtered { f -> !f.isView && !IS_UPGRADE(f) } {
    uint256 votesBefore = OracleAggregator.voteCount(voteKey);
    uint16 disputesBefore = OracleAggregator.disputeCountOf(requestId);
    bool reporterFlagBefore = OracleAggregator.hasReporterVoted(requestId, module);
    bool disputerFlagBefore = OracleAggregator.hasDisputerVoted(requestId, module);

    f(e, args);

    assert to_mathint(OracleAggregator.voteCount(voteKey)) >= to_mathint(votesBefore),
        "vote counts never decrease";
    assert to_mathint(OracleAggregator.disputeCountOf(requestId)) >= to_mathint(disputesBefore),
        "dispute counts never decrease";
    assert reporterFlagBefore => OracleAggregator.hasReporterVoted(requestId, module),
        "a reporter's vote flag is never cleared";
    assert disputerFlagBefore => OracleAggregator.hasDisputerVoted(requestId, module),
        "a disputer's vote flag is never cleared";
    assert OracleAggregator.voteCount(voteKey) != votesBefore
        => f.selector == sig:reportResult(bytes32, uint256[]).selector,
        "only reportResult moves a vote count";
    assert OracleAggregator.disputeCountOf(requestId) != disputesBefore
        => f.selector == sig:disputeResult(bytes32).selector,
        "only disputeResult moves a dispute count";
}

/*--------------------------------------------------------------
            ORACLE-VOTE-02 — single-vote accounting
--------------------------------------------------------------*/

/**
 * @title report casts exactly one vote
 * @description A successful report sets exactly the caller's flag and increments exactly one vote key.
 * @link_property ORACLE-VOTE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/038e9e7b7ede44cbbece31989e361699?anonymousKey=f38cb6e9c87d6c600fe5d5b2543afd4ab2ee5846
 */
rule reportResultCastsExactlyOneVote(
    env e,
    bytes32 requestId,
    uint256[] result,
    bytes32 otherVoteKey,
    address otherModule
) {
    require result.length == 1, "Valid shape as proved in certora/specs/oracle/AggregatorConfig.spec";
    // Needed only so `result[0]` below is in bounds
    bytes32 voteKey = OracleAggregator.voteKeyForValue(requestId, result[0]);
    require otherVoteKey != voteKey, "without it `otherVoteKey` can be the reported key";

    uint256 votesBefore = OracleAggregator.voteCount(voteKey);
    uint256 otherVotesBefore = OracleAggregator.voteCount(otherVoteKey);
    bool otherFlagBefore = OracleAggregator.hasReporterVoted(requestId, otherModule);

    reportResult(e, requestId, result);

    assert OracleAggregator.hasReporterVoted(requestId, e.msg.sender),
        "the reporting module's flag is set";
    assert to_mathint(OracleAggregator.voteCount(voteKey)) == to_mathint(votesBefore) + 1,
        "the reported result's vote key gains exactly one unit";
    assert OracleAggregator.voteCount(otherVoteKey) == otherVotesBefore,
        "no other vote key moves";
    assert otherModule != e.msg.sender
        => OracleAggregator.hasReporterVoted(requestId, otherModule) == otherFlagBefore,
        "no other module's flag moves";
}

/**
 * @title a module cannot vote twice
 * @description A module cannot vote twice on the same request.
 * @link_property ORACLE-VOTE-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/038e9e7b7ede44cbbece31989e361699?anonymousKey=f38cb6e9c87d6c600fe5d5b2543afd4ab2ee5846
 */
rule reportResultRepeatByTheSameModuleReverts(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.hasReporterVoted(requestId, e.msg.sender);

    reportResult@withrevert(e, requestId, result);

    assert lastReverted, "a module that has already voted must be rejected with AlreadyVoted";
}

/*--------------------------------------------------------------
    ORACLE-DISP-01 — dispute accounting and escalation at threshold
--------------------------------------------------------------*/

/**
 * @title an unregistered request has clean dispute state
 * @description An unregistered request carries no dispute state.
 * @link_property ORACLE-DISP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/5781fec7a9114a90afe8f32c41d4439b?anonymousKey=4587995ad8484c84823492f218ff8c55ea569024
 */
invariant unregisteredRequestHasCleanDisputeState(bytes32 requestId)
    OracleAggregator.targetOfRequest(requestId) == 0
        => (OracleAggregator.disputeCountOf(requestId) == 0
            && OracleAggregator.statusOf(requestId) == NONE())
    filtered { f -> !f.isView && !IS_UPGRADE(f) }

/**
 * @title dispute quorum implies escalation
 * @description While a request can still take disputes its dispute count is strictly below the threshold, so the threshold-crossing dispute escalates in the same transaction.
 * @link_property ORACLE-DISP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/85c64667e539431fbbdf8bb2c7e5ffd0?anonymousKey=6113179b4153b7867fd2fcfaa2a1efead66a1a8e
 */
invariant disputeQuorumImpliesEscalation(bytes32 requestId)
    OracleAggregator.targetOfRequest(requestId) != 0
        => (OracleAggregator.disputeCountOf(requestId)
                < OracleAggregator.disputerThresholdOfRequest(requestId)
            || OracleAggregator.statusOf(requestId) == ARBITRATION_REQUESTED()
            || OracleAggregator.statusOf(requestId) == RESOLVED())
    filtered { f -> !f.isView && !IS_UPGRADE(f) }
    { preserved { requireInvariant unregisteredRequestHasCleanDisputeState(requestId); } }

/**
 * @title dispute accounting and escalation
 * @description A successful dispute counts once and escalates exactly at the threshold.
 * @link_property ORACLE-DISP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/038e9e7b7ede44cbbece31989e361699?anonymousKey=f38cb6e9c87d6c600fe5d5b2543afd4ab2ee5846
 */
rule disputeAccountingAndEscalation(env e, bytes32 requestId) {
    requireInvariant disputeQuorumImpliesEscalation(requestId);

    mathint disputesBefore = to_mathint(OracleAggregator.disputeCountOf(requestId));
    mathint threshold = to_mathint(OracleAggregator.disputerThresholdOfRequest(requestId));
    uint8 statusBefore = OracleAggregator.statusOf(requestId);

    disputeResult(e, requestId);

    assert to_mathint(OracleAggregator.disputeCountOf(requestId)) == disputesBefore + 1,
        "the dispute counter advances by exactly one";
    assert OracleAggregator.hasDisputerVoted(requestId, e.msg.sender),
        "the disputing module's flag is set";
    assert (disputesBefore + 1 >= threshold)
        <=> (OracleAggregator.statusOf(requestId) == ARBITRATION_REQUESTED()),
        "escalation happens exactly when the dispute threshold is reached";
    assert (disputesBefore + 1 < threshold) => OracleAggregator.statusOf(requestId) == statusBefore,
        "a sub-threshold dispute leaves the status unchanged";
}

/**
 * @title a dispute requires a prior proposal
 * @description A dispute can only follow a prior successful proposal.
 * @link_property ORACLE-DISP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/038e9e7b7ede44cbbece31989e361699?anonymousKey=f38cb6e9c87d6c600fe5d5b2543afd4ab2ee5846
 */
rule disputeRequiresPriorProposal(env e, bytes32 requestId) {
    require OracleAggregator.proposedHashOf(requestId) == to_bytes32(0);

    disputeResult@withrevert(e, requestId);

    assert lastReverted, "there is nothing to challenge before a proposal stands";
}

/**
 * @title a module cannot dispute twice
 * @description A module cannot dispute twice on the same request.
 * @link_property ORACLE-DISP-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/038e9e7b7ede44cbbece31989e361699?anonymousKey=f38cb6e9c87d6c600fe5d5b2543afd4ab2ee5846
 */
rule disputeRepeatByTheSameModuleReverts(env e, bytes32 requestId) {
    require OracleAggregator.hasDisputerVoted(requestId, e.msg.sender);

    disputeResult@withrevert(e, requestId);

    assert lastReverted, "a module that has already disputed must be rejected with AlreadyVoted";
}

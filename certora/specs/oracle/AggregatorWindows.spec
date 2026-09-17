// ============================================================
// Properties:
//   ORACLE-WIND-01  Window immutability — `disputeWindowEnd` is written exactly once, at proposal
//                   creation, and never moves afterwards.
//   ORACLE-WIND-02  Window expiry closes reporting and disputing.
// ============================================================


/*
 * MODULE
 * @module OracleAggregator Vote Accounting
 * @contract OracleAggregator
 * @impact An outcome could enter the dispute window without quorum, or one reporter could vote repeatedly, settling on an unbacked result
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 *
 * PROPERTIES
 * @property ORACLE-WIND-01 Window immutability: the dispute window is written exactly once, at proposal creation.
 * @property ORACLE-WIND-02 Window expiry closes reporting and disputing.
 */

import "../summaries/OracleAggregator_call_resolution.spec";
import "../summaries/OracleAggregator_base_summaries.spec";

// `disputeWindowEnd` is a uint40 field written as `uint40(block.timestamp + cfg.livenessWindow)`
definition WINDOW_MODULUS() returns mathint = 2 ^ 40;

/*--------------------------------------------------------------
                ORACLE-WIND-01 — window immutability
--------------------------------------------------------------*/

/**
 * @title the window is frozen once proposed
 * @description Once a proposal stands, nothing moves its dispute window.
 * @link_property ORACLE-WIND-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2a0f5e4329b043ed8d9a0aaa0ad2d331?anonymousKey=2e75073d5fb36a4fcd4d70a9c5a58a585b146111
 */
rule windowIsFrozenOnceProposed(env e, method f, calldataarg args, bytes32 requestId)
    filtered { f -> !f.isView && !IS_UPGRADE(f) }
{
    require OracleAggregator.proposedHashOf(requestId) != to_bytes32(0);
    uint40 windowBefore = OracleAggregator.windowEndOf(requestId);

    f(e, args);

    assert OracleAggregator.windowEndOf(requestId) == windowBefore,
        "an existing proposal's dispute window must never move";
}

/**
 * @title a new window is now plus liveness
 * @description A fresh proposal's window is the current time plus the configured liveness.
 * @link_property ORACLE-WIND-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2a0f5e4329b043ed8d9a0aaa0ad2d331?anonymousKey=2e75073d5fb36a4fcd4d70a9c5a58a585b146111
 */
rule newProposalWindowIsNowPlusLiveness(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.proposedHashOf(requestId) == to_bytes32(0);
    uint32 liveness = OracleAggregator.livenessWindowOfRequest(requestId);

    reportResult(e, requestId, result);

    assert OracleAggregator.proposedHashOf(requestId) != to_bytes32(0)
        => to_mathint(OracleAggregator.windowEndOf(requestId))
            == (to_mathint(e.block.timestamp) + to_mathint(liveness)) % WINDOW_MODULUS(),
        "a new proposal's window is uint40(now + livenessWindow)";
}

/*--------------------------------------------------------------
        ORACLE-WIND-02 — expiry closes reporting and disputing
--------------------------------------------------------------*/

/**
 * @title reporting closes at the window end
 * @description Reporting is rejected at and after the window end.
 * @link_property ORACLE-WIND-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2a0f5e4329b043ed8d9a0aaa0ad2d331?anonymousKey=2e75073d5fb36a4fcd4d70a9c5a58a585b146111
 */
rule reportRejectedAtOrAfterWindowEnd(env e, bytes32 requestId, uint256[] result) {
    require OracleAggregator.proposedHashOf(requestId) != to_bytes32(0);
    require e.block.timestamp >= to_mathint(OracleAggregator.windowEndOf(requestId));

    reportResult@withrevert(e, requestId, result);

    assert lastReverted, "no report may land at or after the dispute window end";
}

/**
 * @title disputing closes at the window end
 * @description Disputing is rejected at and after the window end.
 * @link_property ORACLE-WIND-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2a0f5e4329b043ed8d9a0aaa0ad2d331?anonymousKey=2e75073d5fb36a4fcd4d70a9c5a58a585b146111
 */
rule disputeRejectedAtOrAfterWindowEnd(env e, bytes32 requestId) {
    require OracleAggregator.proposedHashOf(requestId) != to_bytes32(0);
    require e.block.timestamp >= to_mathint(OracleAggregator.windowEndOf(requestId));

    disputeResult@withrevert(e, requestId);

    assert lastReverted, "no dispute may land at or after the dispute window end";
}

// ============================================================
// Properties:
//   OO-RELAY-01   Result integrity of the permissionless relay. On any successful
//                 report / finalize the array handed to the aggregator is exactly the
//                 deterministic translation of `ooReporter.getRequestResolution(r)` under
//                 `aggregator.getRequestShape(r)`, and nothing about the caller or the
//                 calldata beyond `r` influences it.
//   OO-ATOMIC-01  The atomic-neg-risk branch forwards a RAW WINNER INDEX, and its acceptance set is exactly
//                 `p >= 0 && p % 1e18 == 0 && p / 1e18 < arity.
// ============================================================


/*
 * MODULE
 * @module OOReporterModule Result Translation
 * @contract OOReporterModule
 * @impact A settled price could translate into the wrong payout vector, settling the market on the wrong outcome
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 *
 * PROPERTIES
 * @property OO-RELAY-01 Result integrity of the permissionless relay: the array the aggregator records is exactly the deterministic translation of the settled price, caller-independent.
 * @property OO-ATOMIC-01 The atomic neg-risk branch forwards a raw winner index, with an exact acceptance set.
 */

import "../summaries/OptimisticOraclePayout_constants.spec";
import "../summaries/OOReporterModule_call_resolution.spec";
import "../summaries/OOReporterModule_base_summaries.spec";

methods {
    function OOReporterModule.settledResultLen(bytes32) external returns (uint256) envfree;
    function OOReporterModule.settledResultAt(bytes32, uint256) external returns (uint256) envfree;

    function OracleAggregator.getRequestState(bytes32) external
        returns (OracleAggregator.ResolutionStatus, bytes32, uint256, uint256) envfree;
}

// ------------------------------------------------------------
// Helpers
// ------------------------------------------------------------

// The visible preconditions of `_getSettledResult`.
function requireRelayPreconditions(bytes32 rid) {
    requireSceneWiring();
    require isCanonicalRequestId(rid), "ConditionIdLib.from rejects a dirty outcome byte";
    require requestInitializedAt(rid), "the module registered this request";
    require OOReporter.isRequestResolved(rid), "UMA settled this request";
}

// Keeps the conflict path out: a second, differing result reaching the reporter
// threshold calls `_triggerArbitration`, whose low-level call to a config-set arbitrator
// address no scene contract implements.
function requireNoLiveProposal(bytes32 rid) {
    OracleAggregator.ResolutionStatus status; bytes32 proposal; uint256 windowEnd; uint256 disputes;
    status, proposal, windowEnd, disputes = OracleAggregator.getRequestState(rid);
    require proposal == to_bytes32(0), "no proposal yet: the report cannot conflict";
}

// The singleton shape the fidelity/independence rules pin: their hash comparisons go through
// `resultHashFor`, whose pre-image is a fixed 96-byte length-1 encoding, so they are sound
// only when the translation is a singleton. That is the only configured shape —
// `initializeRequest` pins `resultLength == 1`, carried by the aggregator-family pair
// `initializeRequestConfiguresSingletonResultLength` (registration sets it to 1) and
// `onlyInitializeRequestChangesResultLength` (nothing else moves it), both in
// AggregatorConfig.spec — and the atomic branch translates to a singleton by construction.
function requireSingletonShape(bytes32 rid) {
    uint8 mt; uint16 n;
    mt, n = OracleAggregator.getRequestShape(rid);
    require mt == ATOMIC_NEGRISK() || n == 1,
        "visible precondition: the singleton request shape every initialized request carries";
}

// The single element the non-atomic branch must produce for a single-outcome request:
// YES -> D, P3 -> D/2, NO (and nothing else can be accepted) -> 0.
function singleOutcomePayout(int256 p) returns mathint {
    if (to_mathint(p) == YES_PRICE()) {
        return RESULT_DENOMINATOR();
    }
    if (to_mathint(p) == P3_PRICE()) {
        return RESULT_DENOMINATOR() / 2;
    }
    return 0;
}

// ------------------------------------------------------------
// (1) TRANSLATION
// ------------------------------------------------------------

/**
 * @title atomic translation is the raw winner index
 * @description On the atomic neg-risk branch the module forwards the length-one raw winner index, and that index is inside the event arity.
 * @link_property OO-ATOMIC-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d91d45324cbb4d13b731b0e8fb11ffb5?anonymousKey=ccf7c0ffa489cc9836c2b74e83bf843773662181
 */
rule atomicTranslationIsTheRawWinnerIndex(bytes32 rid) {
    requireRelayPreconditions(rid);

    uint8 mt; uint16 n;
    mt, n = OracleAggregator.getRequestShape(rid);
    require mt == ATOMIC_NEGRISK(), "the atomic branch";

    int256 p = OOReporter.getRequestResolution(rid);
    uint256 len = settledResultLen(rid);
    uint256 element = settledResultAt(rid, 0);

    assert len == 1, "the atomic branch did not produce a singleton";
    assert to_mathint(element) == to_mathint(p) / YES_PRICE(),
        "the atomic element is not the raw winner index price / 1e18";
    assert to_mathint(element) < to_mathint(arityOfRequestId(rid)),
        "the forwarded winner index is outside the event arity";
}

/**
 * @title atomic accepts exactly the valid indices
 * @description The atomic branch accepts a settled price exactly when it is a non-negative whole multiple of the price unit whose quotient is below the event arity.
 * @link_property OO-ATOMIC-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d91d45324cbb4d13b731b0e8fb11ffb5?anonymousKey=ccf7c0ffa489cc9836c2b74e83bf843773662181
 */
rule atomicAcceptsExactlyValidIndices(bytes32 rid) {
    requireRelayPreconditions(rid);

    uint8 mt; uint16 n;
    mt, n = OracleAggregator.getRequestShape(rid);
    require mt == ATOMIC_NEGRISK(), "the atomic branch";

    int256 p = OOReporter.getRequestResolution(rid);
    mathint arity = to_mathint(arityOfRequestId(rid));

    settledResultLen@withrevert(rid);
    bool reverted = lastReverted;

    bool priceIsValidIndex =
        (p) >= 0 && to_mathint(p) % YES_PRICE() == 0 && to_mathint(p) / YES_PRICE() < arity;

    assert !reverted <=> priceIsValidIndex,
        "the atomic acceptance set differs from the valid-index specification";
}

// ------------------------------------------------------------
// (2) FIDELITY — the relay body neither reshapes nor truncates
// ------------------------------------------------------------

/**
 * @title report forwards the translation
 * @description A successful report makes the aggregator record exactly one vote, for the hash of the module's own translation, and for no other result.
 * @link_property OO-RELAY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d91d45324cbb4d13b731b0e8fb11ffb5?anonymousKey=ccf7c0ffa489cc9836c2b74e83bf843773662181
 */
rule reportForwardsTheTranslationToTheAggregator(env e, bytes32 rid, bytes32 anyVoteKey) {
    requireRelayPreconditions(rid);
    requireSingletonShape(rid);

    uint256 len = settledResultLen(rid);
    uint256 element = settledResultAt(rid, 0);
    bytes32 expectedKey = voteKeyFor(rid, resultHashFor(element));

    mathint expectedVotesBefore = to_mathint(OracleAggregator.voteCount(expectedKey));
    mathint otherVotesBefore = to_mathint(OracleAggregator.voteCount(anyVoteKey));

    report(e, rid);

    assert to_mathint(OracleAggregator.voteCount(expectedKey)) == expectedVotesBefore + 1,
        "the aggregator did not record a vote for the module's translated result";
    assert anyVoteKey != expectedKey =>
        to_mathint(OracleAggregator.voteCount(anyVoteKey)) == otherVotesBefore,
        "the aggregator recorded a vote for a result the module did not translate";
    assert OracleAggregator.hasReporterVoted(rid, OOReporterModule),
        "the module's vote was not attributed to the module";
    assert len == 1,
        "a successful relay forwarded a non-singleton array";
}

// ------------------------------------------------------------
// (3) Caller independence
// ------------------------------------------------------------

/**
 * @title the relay is caller-independent
 * @description Two different callers relaying the same request from the same state make the aggregator record the same result.
 * @link_property OO-RELAY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d91d45324cbb4d13b731b0e8fb11ffb5?anonymousKey=ccf7c0ffa489cc9836c2b74e83bf843773662181
 */
rule relayIsCallerIndependent(env e1, env e2, bytes32 rid) {
    requireRelayPreconditions(rid);
    requireNoLiveProposal(rid);
    requireSingletonShape(rid);
    require e1.msg.sender != e2.msg.sender, "two distinct relayers";
    require e1.block.timestamp == e2.block.timestamp, "same block, so the dispute window matches";

    storage init = lastStorage;

    uint256 element = settledResultAt(rid, 0);
    bytes32 expectedKey = voteKeyFor(rid, resultHashFor(element));
    mathint votesBefore = to_mathint(OracleAggregator.voteCount(expectedKey));

    report(e1, rid) at init;
    mathint votesAfterFirstCaller = to_mathint(OracleAggregator.voteCount(expectedKey));

    report(e2, rid) at init;
    mathint votesAfterSecondCaller = to_mathint(OracleAggregator.voteCount(expectedKey));

    assert votesAfterFirstCaller == votesBefore + 1 && votesAfterSecondCaller == votesBefore + 1,
        "the relayed content depends on who relayed it";
}

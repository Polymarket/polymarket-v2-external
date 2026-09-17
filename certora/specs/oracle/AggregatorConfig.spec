/*
 * MODULE
 * @module OracleAggregator Request Configuration
 * @contract OracleAggregator
 * @impact A request could be left with a zero arbitrator or a result shape the reporters cannot satisfy, making resolution or escalation impossible
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 2 iterations, except
 *   `initializeRequestConfiguresSingletonResultLength`, which runs at 1 iteration.
 * PROPERTIES
 * @property ORACLE-CONF-02 A request's thresholds and result length are fixed at registration, and a registered request always has a non-zero arbitrator.
 */

import "../summaries/OracleAggregator_call_resolution.spec";
import "../summaries/OracleAggregator_base_summaries.spec";

/*--------------------------------------------------------------
        ORACLE-CONF-02 — registered-request config pins
--------------------------------------------------------------*/

/**
 * @title thresholds never change
 * @description A registered request's thresholds never change.
 * @link_property ORACLE-CONF-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0363d11a93944e3e87ab08411ba751d4?anonymousKey=4e630747727589c4a98123a46f93a2c06bd43c44
 */
rule thresholdsOfRegisteredRequestNeverChange(env e, method f, calldataarg args, bytes32 rawEventId)
    filtered { f -> !f.isView && !IS_UPGRADE(f) }
{
    require OracleAggregator.cfgTarget(rawEventId) != 0;
    uint16 reporterThresholdBefore = OracleAggregator.cfgReporterThreshold(rawEventId);
    uint16 disputerThresholdBefore = OracleAggregator.cfgDisputerThreshold(rawEventId);

    f(e, args);

    assert OracleAggregator.cfgReporterThreshold(rawEventId) == reporterThresholdBefore
        && OracleAggregator.cfgDisputerThreshold(rawEventId) == disputerThresholdBefore,
        "a registered request's thresholds never change";
}

/**
 * @title arbitrator is never zero
 * @description A registered request can never end up with a zero arbitrator.
 * @link_property ORACLE-CONF-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/75d4fef82bff4c8183aa8c859554b2ca?anonymousKey=0d9165319edeac109c3585df3fcb7f88bfc7d6c1
 */
invariant registeredRequestHasAnArbitrator(bytes32 rawEventId)
    OracleAggregator.cfgTarget(rawEventId) != 0
        => OracleAggregator.cfgArbitrator(rawEventId) != 0
    filtered { f -> !f.isView && !IS_UPGRADE(f) }

/**
 * @title initializeRequest configures a singleton result length
 * @description A request can only be registered with a result length of exactly 1.
 * @link_property ORACLE-CONF-02
 * @assumption At most one reporter module and one disputer module are registered by the call
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/3ff66cadfe89447880718b0bbd424f29?anonymousKey=79b4dc9044bf344fae9e15910b516b83d78f5a34
 */
rule initializeRequestConfiguresSingletonResultLength(env e, OracleAggregator.InitParams params) {
    require params.reporterModules.length <= 1 && params.disputerModules.length <= 1,
        "bounded proof: at most one module per set";

    initializeRequest(e, params);

    assert OracleAggregator.cfgResultLengthOf(params.eventId) == 1,
        "initializeRequest can only configure a singleton result length";
}

/**
 * @title only initializeRequest changes the result length
 * @description No method other than registration ever moves a request's configured result length.
 * @link_property ORACLE-CONF-02
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0a757c1c7be2428684963b3fd2a4be5d?anonymousKey=e28324ffa97bede7e3be2a50de8193aa1cfb7906
 */
rule onlyInitializeRequestChangesResultLength(env e, method f, calldataarg args, bytes32 rawEventId)
    filtered { f -> !f.isView && !IS_UPGRADE(f) && !IS_INITIALIZE_REQUEST(f) }
{
    uint16 lengthBefore = OracleAggregator.cfgResultLength(rawEventId);

    f(e, args);

    assert OracleAggregator.cfgResultLength(rawEventId) == lengthBefore,
        "only initializeRequest may change a request's configured result length";
}

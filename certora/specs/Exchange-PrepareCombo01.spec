/* =============================================================================
 * [EXCHANGE-PREPARE-COMBO-01] matchOrdersAndPrepareCombinatorial binds the
 * prepared condition to the taker tokenId.
 *
 * prepareCondition(legs) is called atomically before matching; the returned
 * conditionId must equal takerOrder.tokenId.conditionId(), else the entry
 * reverts InvalidTokenId. This guarantees the combinatorial market traded is 
 * exactly the one prepared in the same tx.
 * ============================================================================= */

/*
 * MODULE
 * @module Exchange Combinatorial Binding
 * @contract Exchange
 * @impact The prepared condition could differ from the taker token, settling the trade against the wrong market
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property EXCHANGE-PREPARE-COMBO-01 The Exchange combinatorial entry point binds the condition it prepares atomically to the taker token id.
 */


using ExchangeHarness as Exchange;
using CombinatorialModuleHarness as CombinatorialModule;

methods {
    // CombinatorialModule pure/view helpers (envfree: no msg context needed).
    function CombinatorialModule.getConditionId(CombinatorialModule.PositionId[]) external returns (CombinatorialModule.ConditionId) envfree;
    function CombinatorialModule.condIdOf(CombinatorialModule.PositionId) external returns (CombinatorialModule.ConditionId) envfree;
    function CombinatorialModule.pidUnwrap(CombinatorialModule.PositionId) external returns (uint256) envfree;
    function CombinatorialModule.moduleIdOfPid(uint256) external returns (uint256) envfree;
    function CombinatorialModule.outcomeOfPid(uint256) external returns (uint256) envfree;
    function CombinatorialModule.legsLengthOfPid(uint256) external returns (uint256) envfree;

    // Non-memory-safe _computeStructHash assembly breaks selector recovery NONDET strips it.
    // The hash only keys order-status/signature slots orthogonal to this property.
    function _._hashOrder(Exchange.Order calldata) internal => NONDET;
    // Signature machinery (ecrecover, ERC1271 staticcall, create2).
    function _._isValidSignature(bytes32, Exchange.Order calldata) internal => NONDET;

    // Event-only assembly emitters.
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;
    function _._emitTakerEvents(bytes32, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;

    // Module split/merge: summarized at the internal wrapper so the external
    // call is never emitted. Real split/merge mint/burn tokens only — they
    // cannot write legs (proven by preparedConditionStaysPrepared).
    function _._split(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _._merge(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _.moduleById(uint256) external => NONDET;
    function _.unsafeTransferFrom(address, address, uint256, uint256) external => NONDET;

    // pUSD moves route through these Solady library internals
    // (safeTransferFrom is (token, from, to, amount) — 3 addresses).
    function _.safeTransfer(address, address, uint256) internal => NONDET;
    function _.safeTransferFrom(address, address, address, uint256) internal => NONDET;
}

definition COMBINATORIAL() returns uint256 = 3;

/* =============================================================================
 * R1 — the taker token's condition IS the condition of the submitted legs
 *      (real prepareCondition + real bind check, below the saturation)
 * ============================================================================= */

/**
 * @title the taker token is bound to the prepared legs
 * @description The condition prepared atomically before matching is exactly the one encoded in the taker token id.
 * @link_property EXCHANGE-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/166a1ec040854b91b8a68d158a2bb979?anonymousKey=f590e4796ca9079f63ab7f5ce0a1131313ac8762
 */
rule bindPrefixTakerTokenBoundToPreparedLegs(env e) {
    Exchange.Order takerOrder;
    Exchange.PositionId[] inLegs;

    CombinatorialModule.ConditionId takerCid = CombinatorialModule.condIdOf(takerOrder.tokenId);
    CombinatorialModule.ConditionId legsCid = CombinatorialModule.getConditionId(inLegs);

    h_prepareAndBindCombinatorial@withrevert(e, takerOrder, inLegs);

    assert !lastReverted => takerCid == legsCid,"on success the taker tokenId's conditionId must equal the id of the legs prepared in the same tx";
    satisfy !lastReverted;
}

/* =============================================================================
 * R2 — success forces a combinatorial-module taker token
 * ============================================================================= */

/**
 * @title the taker token is combinatorial
 * @description The combinatorial entry point only accepts a taker token id on the combinatorial module.
 * @link_property EXCHANGE-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/166a1ec040854b91b8a68d158a2bb979?anonymousKey=f590e4796ca9079f63ab7f5ce0a1131313ac8762
 */
rule bindPrefixTakerTokenIsCombinatorial(env e) {
    Exchange.Order takerOrder;
    Exchange.PositionId[] inLegs;

    h_prepareAndBindCombinatorial@withrevert(e, takerOrder, inLegs);
    bool ok = !lastReverted;

    uint256 takerPid = CombinatorialModule.pidUnwrap(takerOrder.tokenId);
    uint256 m = CombinatorialModule.moduleIdOfPid(takerPid);

    assert ok => m == COMBINATORIAL(), "the binding check only accepts combinatorial-module taker tokens";
    satisfy ok;
}

/* =============================================================================
 * R3 — after success the taker's condition is prepared on the module
 * ============================================================================= */

/**
 * @title the taker's condition is prepared after the call
 * @description After the combinatorial entry point succeeds, the taker's condition is prepared.
 * @link_property EXCHANGE-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/166a1ec040854b91b8a68d158a2bb979?anonymousKey=f590e4796ca9079f63ab7f5ce0a1131313ac8762
 */
rule bindPrefixTakerConditionPreparedAfter(env e) {
    Exchange.Order takerOrder;
    Exchange.PositionId[] inLegs;

    h_prepareAndBindCombinatorial@withrevert(e, takerOrder, inLegs);
    bool ok = !lastReverted;

    uint256 takerPid = CombinatorialModule.pidUnwrap(takerOrder.tokenId);
    uint256 legCountPost = CombinatorialModule.legsLengthOfPid(takerPid);

    assert ok => legCountPost > 0, "on success the taker token's condition must be prepared (legs stored) on the CombinatorialModule";
    satisfy ok;
}

/* =============================================================================
 * R4 — REAL public entry: success forces a YES/NO taker outcome byte
 *      (calldata-only fact, immune to the entry's AUTO-havocs)
 * ============================================================================= */

/**
 * @title the taker outcome is YES or NO
 * @description The combinatorial entry point only accepts a taker token whose outcome index is a valid YES or NO leg.
 * @link_property EXCHANGE-PREPARE-COMBO-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/b1dbfa654554449e80e83a467bf8db90?anonymousKey=587790cef9cbf20851ffbd09e19c4c1532e7445c
 */
rule entryTakerOutcomeIsYesOrNo(env e) {
    Exchange.Order takerOrder;
    Exchange.Order[] makerOrders;
    uint256[] fills;
    uint256[] fees;
    Exchange.TakerAmounts ta;
    Exchange.PositionId[] inLegs;

    matchOrdersAndPrepareCombinatorial@withrevert(e, takerOrder, makerOrders, fills, fees, ta, inLegs);
    bool ok = !lastReverted;

    uint256 takerPid = CombinatorialModule.pidUnwrap(takerOrder.tokenId);
    uint256 o = CombinatorialModule.outcomeOfPid(takerPid);

    assert ok => o <= 1, "the taker token must be a YES or NO position (Exchange.sol:586)";
    satisfy ok;
}
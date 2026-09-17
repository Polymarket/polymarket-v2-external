/* =============================================================================
 * [FEE-CAP-01b] Per-fill fee never exceeds the max rate applied to cash value,
 * nor the party's collateral proceeds.
 *
 * The Buy-taker rate arm is proven by a single rule over the batch cash value (batchBuyCashValue = sumTaking - sumBuyFills)
 * on the complementary path all makers are sell, so sumBuyFills = 0 and the bound collapses to sumTaking. 
 * Rate 0 disables the rate arm by design (operator-trusted); the proceeds arm still holds at rate 0.
 *
 * Rate arm caps the percentage of the cash value.
 * Proceeds arm prevents charging more than what the party is getting paid.
 * ============================================================================= */

/*
 * MODULE
 * @module Exchange Collateral Conservation
 * @contract Exchange
 * @impact A match could mint or drain collateral, or pay a party the wrong amount
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * PROPERTIES
 * @property FEE-CAP-01b A per-fill fee never exceeds the maximum rate applied to the cash value, nor the collateral proceeds of the party paying it.
 */


methods {
    function MAX_FEE_RATE() external returns (uint256) envfree;

    // _computeStructHash assembly is not memory-safe and breaks selector recovery
    // (see Exchange-Solvency01). The hash only keys signatures/order-status, never fees.
    function _._hashOrder(Exchange.Order calldata) internal => NONDET;
    // Signature machinery (ecrecover, ERC1271 staticcall, create2) is orthogonal to fees.
    function _._isValidSignature(bytes32, Exchange.Order calldata) internal => NONDET;

    // Event-only assembly emitters.
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;
    function _._emitTakerEvents(bytes32, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;

    // Token/module movements never feed a fee check; module is not in the scene,
    // so summarize the Exchange's internal _split/_merge (external summary would not attach).
    function _._split(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _._merge(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _.unsafeTransferFrom(address, address, uint256, uint256) external => NONDET;
    function _.moduleById(uint256) external => NONDET;
    function _.prepareCondition(uint256[]) external => NONDET;

    // pUSD moves via Solady raw calls; balances never feed a fee check.
    function _.safeTransfer(address, address, uint256) internal => NONDET;
    function _.safeTransferFrom(address, address, address, uint256) internal => NONDET;
}

definition BPS() returns mathint = 10000;

// Mirrors _calculateTakingAmount : fill * takerAmount / makerAmount.
function takingOf(Exchange.Order order, uint256 fill) returns mathint {
    return to_mathint(fill) * to_mathint(order.takerAmount) / to_mathint(order.makerAmount);
}

// Mirrors _validateFeeRate's cashValue (Exchange.sol:1253-1254).
function cashValueOf(Exchange.Order order, uint256 fill) returns mathint {
    if (order.side == Exchange.Side.BUY) { return to_mathint(fill); }
    return takingOf(order, fill);
}

// Sum of per-maker takings = the complementary BUY taker's collateral spent (Exchange.sol:884).
function sumTaking(Exchange.Order[] orders, uint256[] fills) returns mathint {
    if (orders.length == 1) { return takingOf(orders[0], fills[0]); }
    if (orders.length == 2) { return takingOf(orders[0], fills[0]) + takingOf(orders[1], fills[1]); }
    if (orders.length == 3) { return takingOf(orders[0], fills[0]) + takingOf(orders[1], fills[1]) + takingOf(orders[2], fills[2]); }
    return 0;
}

function buyFillOf(Exchange.Order order, uint256 fill) returns mathint {
    if (order.side == Exchange.Side.BUY) { return to_mathint(fill); }
    return 0;
}

function sumBuyFills(Exchange.Order[] orders, uint256[] fills) returns mathint {
    if (orders.length == 1) { return buyFillOf(orders[0], fills[0]); }
    if (orders.length == 2) { return buyFillOf(orders[0], fills[0]) + buyFillOf(orders[1], fills[1]); }
    if (orders.length == 3) { return buyFillOf(orders[0], fills[0]) + buyFillOf(orders[1], fills[1]) + buyFillOf(orders[2], fills[2]); }
    return 0;
}

// Batch BUY taker's collateral spent, derived from the refund accounting: takerMakingAmount = Sum(taking) - Sum(BUY-maker fills).
function batchBuyCashValue(Exchange.Order[] orders, uint256[] fills) returns mathint {
    return sumTaking(orders, fills) - sumBuyFills(orders, fills);
}

// Scope bounds so the CVL mathint algebra below equals the EVM uint values.
function feeSetup(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    require takerOrder.makerAmount < 2^120 && takerOrder.takerAmount < 2^120, "scope <2^120";
    require ta.takerFillAmount < 2^120 && ta.takerReceiveAmount < 2^120 && ta.takerFeeAmount < 2^120, "scope <2^120";

    if (makerOrders.length >= 1) {
        require makerOrders[0].makerAmount < 2^120 && makerOrders[0].takerAmount < 2^120, "scope <2^120";
        require fills[0] < 2^120 && fees[0] < 2^120, "scope <2^120";
    }
    if (makerOrders.length >= 2) {
        require makerOrders[1].makerAmount < 2^120 && makerOrders[1].takerAmount < 2^120, "scope <2^120";
        require fills[1] < 2^120 && fees[1] < 2^120, "scope <2^120";
    }
    if (makerOrders.length >= 3) {
        require makerOrders[2].makerAmount < 2^120 && makerOrders[2].takerAmount < 2^120, "scope <2^120";
        require fills[2] < 2^120 && fees[2] < 2^120, "scope <2^120";
    }
}

// Drives either public entry; a plain (non-withrevert) call so every rule reasons
// over successful executions only and rule_sanity's vacuity check proves one exists.
function callMatch(env e, bool viaCombinatorial, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    if (viaCombinatorial) {
        Exchange.PositionId[] legs;
        matchOrdersAndPrepareCombinatorial(e, takerOrder, makerOrders, fills, fees, ta, legs);
    } else {
        matchOrders(e, takerOrder, makerOrders, fills, fees, ta);
    }
}

/**
 * @title the fee checker is exact
 * @description The public fee checker reverts exactly when a non-zero fee exceeds the enabled cap or the cap computation overflows.
 * @link_property FEE-CAP-01b
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4043ac4da9644c918142ca1eeace02c0?anonymousKey=78987d59226257750b7030fabc19699f9f3176a3
 */
rule validateFeeExactness(uint256 fee, uint256 cashValue) {
    env e;
    require e.msg.value == 0, "nonzero msg.value reverts regardless of fee logic";
    // Read the immutable rate before the call: any call, even envfree, resets lastReverted.
    mathint rate = to_mathint(MAX_FEE_RATE());
    mathint product = to_mathint(cashValue) * rate;

    validateFee@withrevert(e, fee, cashValue);
    bool reverted = lastReverted;

    assert reverted <=> (fee > 0 && rate > 0 && (product > max_uint256 || to_mathint(fee) > product / BPS()));
}

/**
 * @title a maker fee is capped by the rate
 * @description Every maker fill's fee is bounded by the maximum rate applied to its cash value, on both public entry points.
 * @link_property FEE-CAP-01b
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4043ac4da9644c918142ca1eeace02c0?anonymousKey=78987d59226257750b7030fabc19699f9f3176a3
 */
rule makerFeeCappedByRate(uint256 i, bool viaCombinatorial, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    feeSetup(takerOrder, makerOrders, fills, fees, ta);
    require i < makerOrders.length, "i picks one maker fill";
    require MAX_FEE_RATE() > 0, "rate 0 disables the rate arm by design";

    callMatch(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert to_mathint(fees[i]) <= cashValueOf(makerOrders[i], fills[i]) * to_mathint(MAX_FEE_RATE()) / BPS();
}

/**
 * @title a sell maker fee never exceeds proceeds
 * @description A selling maker's fee never exceeds the collateral proceeds of that fill, even at a zero rate.
 * @link_property FEE-CAP-01b
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4043ac4da9644c918142ca1eeace02c0?anonymousKey=78987d59226257750b7030fabc19699f9f3176a3
 */
rule sellMakerFeeSmallerOrEqualThanProceeds(uint256 i, bool viaCombinatorial, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    feeSetup(takerOrder, makerOrders, fills, fees, ta);
    require i < makerOrders.length, "i picks one maker fill";
    require makerOrders[i].side == Exchange.Side.SELL, "proceeds arm applies to collateral-receiving (SELL) fills";

    callMatch(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert to_mathint(fees[i]) <= takingOf(makerOrders[i], fills[i]);
}

/**
 * @title a sell taker fee is bounded on both arms
 * @description A selling taker's fee is bounded both by the maximum rate applied to its cash value and by its proceeds.
 * @link_property FEE-CAP-01b
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4043ac4da9644c918142ca1eeace02c0?anonymousKey=78987d59226257750b7030fabc19699f9f3176a3
 */
rule sellTakerFeeBounds(bool viaCombinatorial, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    feeSetup(takerOrder, makerOrders, fills, fees, ta);
    require takerOrder.side == Exchange.Side.SELL, "SELL taker: proceeds are takerReceiveAmount";

    callMatch(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert to_mathint(ta.takerFeeAmount) <= to_mathint(ta.takerReceiveAmount);
    assert MAX_FEE_RATE() > 0 => to_mathint(ta.takerFeeAmount) <= to_mathint(ta.takerReceiveAmount) * to_mathint(MAX_FEE_RATE()) / BPS();
}

/**
 * @title a buy taker fee is capped by the rate
 * @description A buying taker's fee is bounded by the maximum rate applied to the batch cash value derived from the refund accounting.
 * @link_property FEE-CAP-01b
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/4043ac4da9644c918142ca1eeace02c0?anonymousKey=78987d59226257750b7030fabc19699f9f3176a3
 */
rule buyTakerFeeCappedByRate_batch(bool viaCombinatorial, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    feeSetup(takerOrder, makerOrders, fills, fees, ta);
    require takerOrder.side == Exchange.Side.BUY, "BUY taker: rate arm uses collateral spent";
    require MAX_FEE_RATE() > 0, "rate 0 disables the rate arm by design";

    callMatch(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert to_mathint(ta.takerFeeAmount) <= batchBuyCashValue(makerOrders, fills) * to_mathint(MAX_FEE_RATE()) / BPS();
}

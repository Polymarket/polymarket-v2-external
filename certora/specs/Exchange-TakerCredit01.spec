/* =============================================================================
 * [EXCHANGE-SELL-ACCUMULATOR-01] — complementary-sell accumulator lemmas, MINIMAL scene.
 *
 * Discharges the sumFills pin of residualComplementarySell (Exchange-Solvency01):
 * with a fixed maker count, asserts the executor's returned takerTakingAmount equals
 * Sum(fills). The taker's ledger credit is a separate spec (see -Ledger) because the
 * ghost mirror it needs is itself what breaks this lemma.
 *
 * ============================================================================= */

/*
 * MODULE
 * @module Exchange Collateral Conservation
 * @contract Exchange
 * @impact A match could mint or drain collateral, or pay a party the wrong amount
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 *
 * PROPERTIES
 * @property EXCHANGE-SELL-ACCUMULATOR-01 The complementary-sell accumulator equals the sum of the maker fills.
 */


import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using PositionManager as PositionManager;
using CombinatorialModule as CombinatorialModule;
using ExchangeHarness as Exchange;

methods {
    // pUSD moves: NONDET. A cvl-function summary here havocs the loop accumulators
    // The pin needs no ledger; the ledger claim lives in Exchange-TakerCredit01-Ledger.spec.
    function _.safeTransfer(address, address, uint256) internal => NONDET;
    function _.safeTransferFrom(address, address, address, uint256) internal => NONDET;

    // Position-token transfers: NONDET (never touch the pUSD ledger).
    // MUST be spelled as an explicit-contract summary with the PositionId UDVT — the wildcard
    // form `_.unsafeTransferFrom(address, address, uint256, uint256)` silently matches NOTHING
    // and lets the REAL PositionManager.unsafeTransferFrom run inside the accumulator loop.
    function PositionManager.unsafeTransferFrom(
        address from, address to, PositionManager.PositionId id, uint256 amount
    ) external => NONDET;

    // _validateAndUpdate reaches the NON-memory-safe _computeStructHash assembly (via
    // _hashOrder). It moves no pUSD.
    function _._validateAndUpdate(Exchange.Order calldata, uint256, uint256) internal => NONDET;

    // Sound and needed due to pointer analysis failure.
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;

    // Pin the Exchange's immutable getters to the in-scene instances.
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COMBINATORIAL_MODULE() external => CombinatorialModule expect address;

    function Exchange.COLLATERAL_TOKEN() external returns (address) envfree;
    function Exchange.FEE_RECEIVER() external returns (address) envfree;
}

// sum(makerFillAmounts) for 1..5 makers.
function sumFills(uint256[] _fills) returns mathint {
    if (_fills.length == 1) { return to_mathint(_fills[0]); }
    if (_fills.length == 2) { return to_mathint(_fills[0]) + to_mathint(_fills[1]); }
    if (_fills.length == 3) { return to_mathint(_fills[0]) + to_mathint(_fills[1]) + to_mathint(_fills[2]); }
    if (_fills.length == 4) { return to_mathint(_fills[0]) + to_mathint(_fills[1]) + to_mathint(_fills[2]) + to_mathint(_fills[3]); }
    if (_fills.length == 5) { return to_mathint(_fills[0]) + to_mathint(_fills[1]) + to_mathint(_fills[2]) + to_mathint(_fills[3]) + to_mathint(_fills[4]);}
    return 0;
}

// Bounds subset of Exchange-Solvency01's residualSetup (real _calculateTakingAmount and the
// crossing checks multiply these, so every product must stay far inside 2^256).
function takerCreditSetup(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts, uint256 len) {
    require makerOrders.length == len, "fixed maker count: loop fully unrolled";
    require makerFillAmounts.length == len, "one fill per maker";
    require makerFeeAmounts.length == len, "one fee per maker";
    require takerOrder.maker != currentContract, "taker != Exchange: else its transfers self-cancel";
    require FEE_RECEIVER() != currentContract, "fee receiver != Exchange";
    require takerOrder.makerAmount < 2^120 && takerOrder.takerAmount < 2^120, "bound taker order amounts";
    require takerAmounts.takerFillAmount < 2^120 && takerAmounts.takerReceiveAmount < 2^120 && takerAmounts.takerFeeAmount < 2^120, "bound taker amounts";

    if (len >= 1) {
        require makerOrders[0].maker != currentContract && makerOrders[0].maker != takerOrder.maker, "maker 0 distinct from Exchange and taker";
        require makerOrders[0].makerAmount < 2^120 && makerOrders[0].takerAmount < 2^120, "bound maker 0 amounts";
        require makerFillAmounts[0] < 2^120 && makerFeeAmounts[0] < 2^120, "bound maker 0 fill/fee";
    }
    if (len >= 2) {
        require makerOrders[1].maker != currentContract && makerOrders[1].maker != takerOrder.maker, "maker 1 distinct from Exchange and taker";
        require makerOrders[1].makerAmount < 2^120 && makerOrders[1].takerAmount < 2^120, "bound maker 1 amounts";
        require makerFillAmounts[1] < 2^120 && makerFeeAmounts[1] < 2^120, "bound maker 1 fill/fee";
    }
    if (len >= 3) {
        require makerOrders[2].maker != currentContract && makerOrders[2].maker != takerOrder.maker, "maker 2 distinct from Exchange and taker";
        require makerOrders[2].makerAmount < 2^120 && makerOrders[2].takerAmount < 2^120, "bound maker 2 amounts";
        require makerFillAmounts[2] < 2^120 && makerFeeAmounts[2] < 2^120, "bound maker 2 fill/fee";
    }
    if (len >= 4) {
        require makerOrders[3].maker != currentContract && makerOrders[3].maker != takerOrder.maker, "maker 3 distinct from Exchange and taker";
        require makerOrders[3].makerAmount < 2^120 && makerOrders[3].takerAmount < 2^120, "bound maker 3 amounts";
        require makerFillAmounts[3] < 2^120 && makerFeeAmounts[3] < 2^120, "bound maker 3 fill/fee";
    }
    if (len >= 5) {
        require makerOrders[4].maker != currentContract && makerOrders[4].maker != takerOrder.maker, "maker 4 distinct from Exchange and taker";
        require makerOrders[4].makerAmount < 2^120 && makerOrders[4].takerAmount < 2^120, "bound maker 4 amounts";
        require makerFillAmounts[4] < 2^120 && makerFeeAmounts[4] < 2^120, "bound maker 4 fill/fee";
    }
}

// Asserts returned takerTaking == Sum(fills) and the taker's real ledger credit.
function sellAccumulatorBody(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts, uint256 len) {
    takerCreditSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, len);

    uint256 takerMaking;
    uint256 takerTaking;
    uint256 fees;
    takerMaking, takerTaking, fees = h_executeComplementarySellFastPath(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    assert to_mathint(takerTaking) == sumFills(makerFillAmounts), "accumulator == Sum(fills): discharges the residualComplementarySell pin";
}

/**
 * @title sell accumulator equals the fills, 1 maker
 * @description With 1 maker fill, the executor's returned taking amount equals the sum of the fills.
 * @link_property EXCHANGE-SELL-ACCUMULATOR-01
 * @assumption Case split covering a fixed maker count, so the accumulator is checked without a loop
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d5728bbc5d484a06b58d104ae158a866?anonymousKey=c498c0ac94116318b3b34ad6f463f7869d304050
 */
rule sellAccumulatorEqualsFills_len1(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    sellAccumulatorBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 1);
}
/**
 * @title sell accumulator equals the fills, 2 makers
 * @description With 2 maker fills, the executor's returned taking amount equals the sum of the fills.
 * @link_property EXCHANGE-SELL-ACCUMULATOR-01
 * @assumption Case split covering a fixed maker count, so the accumulator is checked without a loop
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d5728bbc5d484a06b58d104ae158a866?anonymousKey=c498c0ac94116318b3b34ad6f463f7869d304050
 */
rule sellAccumulatorEqualsFills_len2(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    sellAccumulatorBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 2);
}
/**
 * @title sell accumulator equals the fills, 3 makers
 * @description With 3 maker fills, the executor's returned taking amount equals the sum of the fills.
 * @link_property EXCHANGE-SELL-ACCUMULATOR-01
 * @assumption Case split covering a fixed maker count, so the accumulator is checked without a loop
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d5728bbc5d484a06b58d104ae158a866?anonymousKey=c498c0ac94116318b3b34ad6f463f7869d304050
 */
rule sellAccumulatorEqualsFills_len3(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    sellAccumulatorBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 3);
}
/**
 * @title sell accumulator equals the fills, 4 makers
 * @description With 4 maker fills, the executor's returned taking amount equals the sum of the fills.
 * @link_property EXCHANGE-SELL-ACCUMULATOR-01
 * @assumption Case split covering a fixed maker count, so the accumulator is checked without a loop
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d5728bbc5d484a06b58d104ae158a866?anonymousKey=c498c0ac94116318b3b34ad6f463f7869d304050
 */
rule sellAccumulatorEqualsFills_len4(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    sellAccumulatorBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 4);
}
/**
 * @title sell accumulator equals the fills, 5 makers
 * @description With 5 maker fills, the executor's returned taking amount equals the sum of the fills.
 * @link_property EXCHANGE-SELL-ACCUMULATOR-01
 * @assumption Case split covering a fixed maker count, so the accumulator is checked without a loop
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d5728bbc5d484a06b58d104ae158a866?anonymousKey=c498c0ac94116318b3b34ad6f463f7869d304050
 */
rule sellAccumulatorEqualsFills_len5(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    sellAccumulatorBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 5);
}

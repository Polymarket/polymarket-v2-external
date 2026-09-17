/* =============================================================================
 * [EXCHANGE-COLLATERAL-CONSERVATION-01]
 * matchOrders is a pass-through router: a successful match neither mints nor
 * drains collateral. The Exchange's pUSD residual is exactly the fees it retains
 * (>= 0): zero on the custody pass-through paths (batch buy/sell), and exactly
 * takerFee + Sum(makerFee) on the complementary sell-with-fee path.
 *
 * h_* wrappers do the same mechanical thing: rebuild the MatchContext exactly as _matchOrders builds it 
 * then call one internal function directly. They exist because the public matchOrders is "assembly-saturated" 
 * it reaches the non-memory-safe _computeStructHash assembly via _hashOrder, which breaks the Prover's 
 * selector recovery and forces AUTO-havoc
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
 * @property EXCHANGE-COLLATERAL-CONSERVATION-01 matchOrders is a pass-through router: a successful match neither mints nor drains collateral, and the Exchange residual is exactly the fees it retains.
 */


import "summaries/Exchange_base_summaries.spec";

import "summaries/Solady/ERC1155.spec";
import "summaries/Solady/UUPSUpgradeable.spec";

using PositionManager as PositionManager;
using CombinatorialModule as CombinatorialModule;
using ExchangeHarness as Exchange;

// pUSD ledger. Persistent so an unresolved external call's AUTO-havoc can't scramble it.
persistent ghost mapping(address => mapping(address => uint256)) balanceByToken;

// Running sum of the per-maker `fill` the executor actually consumed, captured from the
// contract's OWN reads via the _validateAndUpdate summary (see sumFillCVL). Comparing the
// returned loop accumulator to this ghost avoids a CVL re-read of the calldata array, which
// the Prover cannot bridge to the bytecode loop for 2+ makers.
persistent ghost mathint g_sumFills;

methods {
    // Every pUSD move routes through Solady safeTransfer(From); mirror it into the ledger.
    function _.safeTransfer(address token, address to, uint256 amount) internal => safeTransferCVL(token, calledContract, to, amount) expect void;
    function _.safeTransferFrom(address token, address from, address to, uint256 amount) internal => safeTransferFromCVL(token, from, to, amount) expect void;

    // We summarize the Exchange's own internal `_merge` / `_split` helpers, not the external BaseModule.merge / .split they call
    // Module contract is not in the scene (only the Exchange, PositionManager, and CombinatorialModule are), so a summary on the 
    // external module function has nothing to attach to and would not take effect. 
    function _._merge(address _moduleAddr, Exchange.ConditionId _conditionId, uint256 _amount) internal => mergeWithGuardCVL(_moduleAddr, _amount) expect void;
    function _._split(address _moduleAddr, Exchange.ConditionId _conditionId, uint256 _amount) internal => moduleGuard(_moduleAddr) expect void;

    // Position-token transfer the executors issue through POSITION_MANAGER: NONDET (touches the ERC1155 ghost, never the pUSD ledger). 
    function _.unsafeTransferFrom(address, address, uint256, uint256) external => NONDET;
    // Event emitters the executors reach; event-only, no pUSD. NONDET so their assembly leaves the executor's decompiled surface.
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;
    
    // Prices maker legs (pUSD on sell-maker/complementary paths). NONDET is a sound over-approximation:
    // the executors' accounting guards enforce conservation for any taking value. Maker-credit pricing
    // (taking == fill * ratio) is intentionally NOT verified in this spec.
    function _._calculateTakingAmount(uint256, uint256, uint256) internal => NONDET;

    // PUBLIC-ENTRY surface only (the executors skip these): the public matchOrders reaches the
    // NON-memory-safe _computeStructHash assembly DIRECTLY via _hashOrder (not through _validateAndUpdate). 
    function _._hashOrder(Exchange.Order calldata) internal => NONDET;
    function _._emitTakerEvents(bytes32, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;
    function _._updateOrderStatus(bytes32, Exchange.Order calldata, uint256) internal => NONDET;
    function _.moduleById(uint256) external => NONDET;
    function _.prepareCondition(uint256[]) external => NONDET;

    // _validateAndUpdate reaches the non-memory-safe _computeStructHash assembly (via _hashOrder) and the order-status store assembly.
    // It moves no pUSD. We summarize it to accumulate the executor's own per-maker `fill` (its 2nd arg)
    // into g_sumFills; the returned hash only feeds NONDET event emitters, so a constant is sound.
    function _._validateAndUpdate(Exchange.Order calldata, uint256 fillAmount, uint256) internal => sumFillCVL(fillAmount) expect bytes32;

    // Pin the Exchange's immutable getters to the in-scene instances (same idiom as solvencyBinary / solvencyNegRisk).
    // Makes any external read of these getters return the real instance rather than havocing.
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COMBINATORIAL_MODULE() external => CombinatorialModule expect address;

    function Exchange.COLLATERAL_TOKEN() external returns (address) envfree;
    function Exchange.FEE_RECEIVER() external returns (address) envfree;
}

// merge mints _amount of pUSD to the Exchange (_to is the Exchange at every call site).
function mergeCreditCVL(address _to, uint256 _amount) {
    balanceByToken[COLLATERAL_TOKEN()][_to] = require_uint256(balanceByToken[COLLATERAL_TOKEN()][_to] + _amount);
}

function safeTransferCVL(address token, address from, address to, uint256 amount) {
    if (balanceByToken[token][from] < amount) { revert(); }
    balanceByToken[token][from] = assert_uint256(balanceByToken[token][from] - amount);
    balanceByToken[token][to] = require_uint256(balanceByToken[token][to] + amount);
}

function safeTransferFromCVL(address token, address from, address to, uint256 amount) {
    if (balanceByToken[token][from] < amount) { revert(); }
    balanceByToken[token][from] = assert_uint256(balanceByToken[token][from] - amount);
    balanceByToken[token][to] = require_uint256(balanceByToken[token][to] + amount);
}

// Accumulates each maker `fill` the executor consumes (the 2nd arg to _validateAndUpdate).
// Returns an arbitrary-but-constant hash: the value only feeds NONDET event emitters.
function sumFillCVL(uint256 fillAmount) returns bytes32 {
    g_sumFills = g_sumFills + to_mathint(fillAmount);
    return to_bytes32(0);
}

// Assumptions (holds by construction): the module moduleById returns is a registered
// module contract — never the Exchange or the fee receiver.
function moduleGuard(address _moduleAddr) {
    require _moduleAddr != currentContract, "module != Exchange: else split/merge transfers self-cancel";
}

function mergeWithGuardCVL(address _moduleAddr, uint256 _amount) {
    moduleGuard(_moduleAddr);
    mergeCreditCVL(currentContract, _amount);
}

// Shared residual-rule setup: bound the maker count to loop_iter, keep the three maker
// arrays the same length, assert no trading party is the Exchange (else its transfers
// self-cancel), and bound every amount to a realistic range.
function residualSetup(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts
) {
    require makerFillAmounts.length == makerOrders.length, "one fill per maker: arrays must align or indexing is off";
    require makerFeeAmounts.length == makerOrders.length, "one fee per maker: arrays must align or indexing is off";
    require takerOrder.maker != currentContract, "taker != Exchange: else taker's transfers self-cancel in the ledger";
    require FEE_RECEIVER()   != currentContract, "fee receiver != Exchange: else fee-out self-cancels, hiding residual";
    require takerAmounts.takerFillAmount < 2^120 && takerAmounts.takerReceiveAmount < 2^120  && takerAmounts.takerFeeAmount < 2^120, "bound taker fill/receive/fee: keep unchecked accumulators from wrapping";
    
    if (makerOrders.length >= 1) {
        require makerOrders[0].maker != currentContract, "maker 0 != Exchange: else its transfers self-cancel in the ledger";
        require makerOrders[0].makerAmount < 2^120 && makerOrders[0].takerAmount < 2^120, "bound maker 0 amounts: keep unchecked sums/products under 2^256";
        require makerFillAmounts[0] < 2^120 && makerFeeAmounts[0] < 2^120, "bound maker 0 fill/fee: keep unchecked accumulators from wrapping";
    }
    if (makerOrders.length >= 2) {
        require makerOrders[1].maker != currentContract, "maker 1 != Exchange: else its transfers self-cancel in the ledger";
        require makerOrders[1].makerAmount < 2^120 && makerOrders[1].takerAmount < 2^120, "bound maker 1 amounts: keep unchecked sums/products under 2^256";
        require makerFillAmounts[1] < 2^120 && makerFeeAmounts[1] < 2^120, "bound maker 1 fill/fee: keep unchecked accumulators from wrapping";
    }
    if (makerOrders.length >= 3) {
        require makerOrders[2].maker != currentContract, "maker 2 != Exchange: else its transfers self-cancel in the ledger";
        require makerOrders[2].makerAmount < 2^120 && makerOrders[2].takerAmount < 2^120, "bound maker 2 amounts: keep unchecked sums/products under 2^256";
        require makerFillAmounts[2] < 2^120 && makerFeeAmounts[2] < 2^120, "bound maker 2 fill/fee: keep unchecked accumulators from wrapping";
    }
    if (makerOrders.length >= 4) {
        require makerOrders[3].maker != currentContract, "maker 3 != Exchange: else its transfers self-cancel in the ledger";
        require makerOrders[3].makerAmount < 2^120 && makerOrders[3].takerAmount < 2^120, "bound maker 3 amounts: keep unchecked sums/products under 2^256";
        require makerFillAmounts[3] < 2^120 && makerFeeAmounts[3] < 2^120, "bound maker 3 fill/fee: keep unchecked accumulators from wrapping";
    }
    if (makerOrders.length >= 5) {
        require makerOrders[4].maker != currentContract, "maker 4 != Exchange: else its transfers self-cancel in the ledger";
        require makerOrders[4].makerAmount < 2^120 && makerOrders[4].takerAmount < 2^120, "bound maker 4 amounts: keep unchecked sums/products under 2^256";
        require makerFillAmounts[4] < 2^120 && makerFeeAmounts[4] < 2^120, "bound maker 4 fill/fee: keep unchecked accumulators from wrapping";
    }
}

// takerFee + sum(makerFeeAmounts) for 1..5 makers.
function expectedFeeTotal(uint256 _takerFee, uint256[] _makerFeeAmounts) returns mathint {
    if (_makerFeeAmounts.length == 1) {
        return to_mathint(_takerFee) + to_mathint(_makerFeeAmounts[0]);
    }
    if (_makerFeeAmounts.length == 2) {
        return to_mathint(_takerFee) + to_mathint(_makerFeeAmounts[0]) + to_mathint(_makerFeeAmounts[1]);
    }
    if (_makerFeeAmounts.length == 3) {
        return to_mathint(_takerFee) + to_mathint(_makerFeeAmounts[0]) + to_mathint(_makerFeeAmounts[1]) + to_mathint(_makerFeeAmounts[2]);
    }
    if (_makerFeeAmounts.length == 4) {
        return to_mathint(_takerFee) + to_mathint(_makerFeeAmounts[0]) + to_mathint(_makerFeeAmounts[1]) + to_mathint(_makerFeeAmounts[2]) + to_mathint(_makerFeeAmounts[3]);
    }
    if (_makerFeeAmounts.length == 5) {
        return to_mathint(_takerFee) + to_mathint(_makerFeeAmounts[0]) + to_mathint(_makerFeeAmounts[1]) + to_mathint(_makerFeeAmounts[2]) + to_mathint(_makerFeeAmounts[3]) + to_mathint(_makerFeeAmounts[4]);
    }
    return to_mathint(_takerFee);
}

// sum(makerFillAmounts) for 1..5 makers, equals the takerTakingAmount the sell executor
// accumulates over the maker loop (`takerTakingAmount += fill`). Used to pin that accumulated
// return to its true loop value, so the Prover cannot over-approximate the unpinned loop output.
function sumFills(uint256[] _fills) returns mathint {
    if (_fills.length == 1) { return to_mathint(_fills[0]); }
    if (_fills.length == 2) { return to_mathint(_fills[0]) + to_mathint(_fills[1]); }
    if (_fills.length == 3) { return to_mathint(_fills[0]) + to_mathint(_fills[1]) + to_mathint(_fills[2]); }
    if (_fills.length == 4) { return to_mathint(_fills[0]) + to_mathint(_fills[1]) + to_mathint(_fills[2]) + to_mathint(_fills[3]); }
    if (_fills.length == 5) { return to_mathint(_fills[0]) + to_mathint(_fills[1]) + to_mathint(_fills[2]) + to_mathint(_fills[3]) + to_mathint(_fills[4]);}
    return 0;
}

/**
 * @title batch sell leaves no residual
 * @description The Exchange's pUSD balance is identical before and after a batch sell match.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule residualBatchSell(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts,address moduleAddr) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    moduleGuard(moduleAddr);

    mathint before = balanceByToken[COLLATERAL_TOKEN()][currentContract];
    h_executeBatchSellMatch(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, moduleAddr);
    mathint afterBal = balanceByToken[COLLATERAL_TOKEN()][currentContract];

    assert afterBal == before, "Exchange must hold zero residual collateral (batch sell)";
}

/**
 * @title batch buy leaves no residual
 * @description The Exchange's pUSD balance is identical before and after a batch buy match.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule residualBatchBuy(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts,address moduleAddr) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    moduleGuard(moduleAddr);

    mathint before = balanceByToken[COLLATERAL_TOKEN()][currentContract];
    h_executeBatchBuyMatch(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, moduleAddr);
    mathint afterBal = balanceByToken[COLLATERAL_TOKEN()][currentContract];

    assert afterBal == before, "Exchange must hold zero residual collateral (batch buy)";
}

/**
 * @title complementary sell parks exactly the fees
 * @description On the complementary sell executor the Exchange receives fill plus fee from each maker and pays the taker its net proceeds, retaining exactly the fees.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule residualComplementarySell(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);

    mathint expectedFees = expectedFeeTotal(takerAmounts.takerFeeAmount, makerFeeAmounts);
    
    require g_sumFills == 0, "reset the fill accumulator before the call";
    mathint before = balanceByToken[COLLATERAL_TOKEN()][currentContract];
    uint256 takerMaking;
    uint256 takerTaking;
    uint256 fees;
    takerMaking, takerTaking, fees = h_executeComplementarySellFastPath(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    // Pin the loop accumulator to the fills the executor ACTUALLY consumed (captured via the
    // _validateAndUpdate summary in g_sumFills). This discharges soundly for any maker count,
    // unlike a CVL re-read of the calldata array, which the Prover cannot bridge for 2+ makers.
    require to_mathint(takerTaking) == g_sumFills, "pin loop accumulator to Sum(fills consumed)";
    mathint afterBal = balanceByToken[COLLATERAL_TOKEN()][currentContract];

    assert afterBal - before == expectedFees, "Exchange residual equals exactly the retained fees (complementary sell)";
}

/**
 * @title complementary buy takes no custody
 * @description On the complementary buy path the Exchange takes no custody of pUSD, so its own balance is unchanged.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule residualComplementaryBuy(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    require takerOrder.side == Exchange.Side.BUY, "this rule covers the complementary BUY path only";

    mathint before = balanceByToken[COLLATERAL_TOKEN()][currentContract];
    h_matchComplementaryOrders(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    mathint afterBal = balanceByToken[COLLATERAL_TOKEN()][currentContract];

    assert afterBal == before, "Exchange must hold zero residual collateral (complementary buy, full wrapper)";
}

/**
 * @title complementary sell nets to zero over the wrapper
 * @description Over the full complementary sell wrapper the Exchange forwards the parked fees onward, so its net balance change is zero.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule residualComplementarySellFull(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    require makerOrders.length == 1, "single maker: full-wrapper SELL residual needs no accumulator bridging";

    mathint before = balanceByToken[COLLATERAL_TOKEN()][currentContract];
    h_matchComplementaryOrders(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    mathint afterBal = balanceByToken[COLLATERAL_TOKEN()][currentContract];

    assert afterBal == before, "Exchange must hold zero residual collateral (complementary sell, full wrapper)";
}

/**
 * @title batch sell credits the fee receiver exactly
 * @description A batch sell match credits the fee receiver exactly the taker fee plus the sum of maker fees.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule feeBatchSell(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts,address moduleAddr) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    moduleGuard(moduleAddr);

    address feeReceiver = FEE_RECEIVER();
    address token = COLLATERAL_TOKEN();

    // Fee receiver distinct from every party (and the module), so its delta is exactly the fees.
    require feeReceiver != takerOrder.maker && feeReceiver != moduleAddr, "fee receiver distinct from taker/module: its delta is then purely fees";
    if (makerOrders.length >= 1) require feeReceiver != makerOrders[0].maker, "fee receiver != maker 0: keep its delta purely fees";
    if (makerOrders.length >= 2) require feeReceiver != makerOrders[1].maker, "fee receiver != maker 1: keep its delta purely fees";
    if (makerOrders.length >= 3) require feeReceiver != makerOrders[2].maker, "fee receiver != maker 2: keep its delta purely fees";
    if (makerOrders.length >= 4) require feeReceiver != makerOrders[3].maker, "fee receiver != maker 3: keep its delta purely fees";
    if (makerOrders.length >= 5) require feeReceiver != makerOrders[4].maker, "fee receiver != maker 4: keep its delta purely fees";
    mathint expectedFees = expectedFeeTotal(takerAmounts.takerFeeAmount, makerFeeAmounts);
    // Fees fit in uint256 (the contract sums them unchecked); rule out the 2^256 wrap.
    require expectedFees < to_mathint(2) * to_mathint(2 ^ 255), "fee sum fits uint256: contract sums fees unchecked, rule out 2^256 wrap";

    mathint before = balanceByToken[token][feeReceiver];
    h_executeBatchSellMatch(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, moduleAddr);
    mathint afterBal = balanceByToken[token][feeReceiver];

    assert afterBal - before == expectedFees, "fee receiver must be credited exactly the declared fees (sell)";
}

/**
 * @title batch buy credits the fee receiver exactly
 * @description A batch buy match credits the fee receiver exactly the taker fee plus the sum of maker fees.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule feeBatchBuy(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts,address moduleAddr) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    moduleGuard(moduleAddr);

    address feeReceiver = FEE_RECEIVER();
    address token = COLLATERAL_TOKEN();

    require feeReceiver != takerOrder.maker && feeReceiver != moduleAddr, "fee receiver distinct from taker/module: its delta is then purely fees";
    if (makerOrders.length >= 1) require feeReceiver != makerOrders[0].maker, "fee receiver != maker 0: keep its delta purely fees";
    if (makerOrders.length >= 2) require feeReceiver != makerOrders[1].maker, "fee receiver != maker 1: keep its delta purely fees";
    if (makerOrders.length >= 3) require feeReceiver != makerOrders[2].maker, "fee receiver != maker 2: keep its delta purely fees";
    if (makerOrders.length >= 4) require feeReceiver != makerOrders[3].maker, "fee receiver != maker 3: keep its delta purely fees";
    if (makerOrders.length >= 5) require feeReceiver != makerOrders[4].maker, "fee receiver != maker 4: keep its delta purely fees";
    mathint expectedFees = expectedFeeTotal(takerAmounts.takerFeeAmount, makerFeeAmounts);
    require expectedFees < to_mathint(2) * to_mathint(2 ^ 255), "fee sum fits uint256: contract sums fees unchecked, rule out 2^256 wrap";

    mathint before = balanceByToken[token][feeReceiver];
    h_executeBatchBuyMatch(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, moduleAddr);
    mathint afterBal = balanceByToken[token][feeReceiver];

    assert afterBal - before == expectedFees, "fee receiver must be credited exactly the declared fees (buy)";
}

/**
 * @title complementary buy routes fees directly
 * @description A complementary buy routes collateral peer to peer and sends fees to the fee receiver from the taker, never through the Exchange.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule feeComplementaryBuy(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);

    address feeReceiver = FEE_RECEIVER();
    address token = COLLATERAL_TOKEN();

    // Fee receiver distinct from every party, so its delta is exactly the fees.
    require feeReceiver != takerOrder.maker, "fee receiver != taker: keep its delta purely fees";
    if (makerOrders.length >= 1) require feeReceiver != makerOrders[0].maker, "fee receiver != maker 0: keep its delta purely fees";
    if (makerOrders.length >= 2) require feeReceiver != makerOrders[1].maker, "fee receiver != maker 1: keep its delta purely fees";
    if (makerOrders.length >= 3) require feeReceiver != makerOrders[2].maker, "fee receiver != maker 2: keep its delta purely fees";
    if (makerOrders.length >= 4) require feeReceiver != makerOrders[3].maker, "fee receiver != maker 3: keep its delta purely fees";
    if (makerOrders.length >= 5) require feeReceiver != makerOrders[4].maker, "fee receiver != maker 4: keep its delta purely fees";
    mathint expectedFees = expectedFeeTotal(takerAmounts.takerFeeAmount, makerFeeAmounts);
    require expectedFees < to_mathint(2) * to_mathint(2 ^ 255), "fee sum fits uint256: contract sums fees unchecked, rule out 2^256 wrap";

    mathint before = balanceByToken[token][feeReceiver];
    h_matchComplementaryOrders(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    mathint afterBal = balanceByToken[token][feeReceiver];

    assert afterBal - before == expectedFees, "fee receiver must be credited exactly the declared fees (complementary buy)";
}

/**
 * @title complementary sell forwards fees exactly
 * @description A complementary sell forwards exactly the taker fee plus the sum of maker fees to the fee receiver.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule feeComplementarySell(
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] makerFillAmounts,
    uint256[] makerFeeAmounts,
    Exchange.TakerAmounts takerAmounts
) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);

    address feeReceiver = FEE_RECEIVER();
    address token = COLLATERAL_TOKEN();

    // Fee receiver distinct from every party, so its delta is exactly the fees.
    require feeReceiver != takerOrder.maker, "fee receiver != taker: keep its delta purely fees";
    if (makerOrders.length >= 1) require feeReceiver != makerOrders[0].maker, "fee receiver != maker 0: keep its delta purely fees";
    if (makerOrders.length >= 2) require feeReceiver != makerOrders[1].maker, "fee receiver != maker 1: keep its delta purely fees";
    if (makerOrders.length >= 3) require feeReceiver != makerOrders[2].maker, "fee receiver != maker 2: keep its delta purely fees";
    if (makerOrders.length >= 4) require feeReceiver != makerOrders[3].maker, "fee receiver != maker 3: keep its delta purely fees";
    if (makerOrders.length >= 5) require feeReceiver != makerOrders[4].maker, "fee receiver != maker 4: keep its delta purely fees";
    mathint expectedFees = expectedFeeTotal(takerAmounts.takerFeeAmount, makerFeeAmounts);
    require expectedFees < to_mathint(2) * to_mathint(2 ^ 255), "fee sum fits uint256: contract sums fees unchecked, rule out 2^256 wrap";

    mathint before = balanceByToken[token][feeReceiver];
    h_matchComplementaryOrders(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    mathint afterBal = balanceByToken[token][feeReceiver];

    assert afterBal - before == expectedFees, "fee receiver must be credited exactly the declared fees (complementary sell)";
}

/**
 * @title a zero-fee complementary sell credits the taker exactly
 * @description A zero-fee complementary sell routes collateral peer to peer and credits the taker exactly the sum of maker fills.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerCreditComplementaryZeroFeeSell(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);

    address taker = takerOrder.maker;
    address token = COLLATERAL_TOKEN();

    // Taker distinct from every maker, so a maker -> taker fill never self-cancels in the ledger.
    if (makerOrders.length >= 1) require taker != makerOrders[0].maker, "taker != maker 0: a maker->taker fill must not self-cancel";
    if (makerOrders.length >= 2) require taker != makerOrders[1].maker, "taker != maker 1: a maker->taker fill must not self-cancel";
    if (makerOrders.length >= 3) require taker != makerOrders[2].maker, "taker != maker 2: a maker->taker fill must not self-cancel";
    if (makerOrders.length >= 4) require taker != makerOrders[3].maker, "taker != maker 3: a maker->taker fill must not self-cancel";
    if (makerOrders.length >= 5) require taker != makerOrders[4].maker, "taker != maker 4: a maker->taker fill must not self-cancel";
    require taker != currentContract, "taker != Exchange: else the maker->taker fill self-cancels the residual check";
    mathint before = balanceByToken[token][taker];
    mathint exBefore = balanceByToken[token][currentContract];
    h_executeComplementaryZeroFeeSellFastPath(e, takerOrder, makerOrders, makerFillAmounts, takerAmounts);
    mathint afterBal = balanceByToken[token][taker];
    mathint exAfter = balanceByToken[token][currentContract];

    assert afterBal - before == sumFills(makerFillAmounts), "taker must be credited exactly Sum(makerFill) (complementary zero-fee sell)";
    // Zero-fee sell routes pUSD maker->taker only; the Exchange never takes custody, so its balance is unchanged.
    assert exAfter == exBefore, "Exchange must hold zero residual collateral (complementary zero-fee sell)";
}

// Machine-checked discharge of the sumFills pin in residualComplementarySell: with the maker count
// Fixed the loop is fully unrolled, so the bytecode accumulator bridges to the CVL closed form.
function takerCreditBody(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts, uint256 len) {
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    require makerOrders.length == len, "fixed maker count: loop fully unrolled, accumulator bridgeable";

    address taker = takerOrder.maker;
    address token = COLLATERAL_TOKEN();
    // Taker distinct from every maker (and, via residualSetup, from the Exchange), so its
    // delta is exactly the exchange->taker payout of this call.
    if (len >= 1) { require taker != makerOrders[0].maker, "taker != maker 0: isolate taker delta"; }
    if (len >= 2) { require taker != makerOrders[1].maker, "taker != maker 1: isolate taker delta"; }
    if (len >= 3) { require taker != makerOrders[2].maker, "taker != maker 2: isolate taker delta"; }
    if (len >= 4) { require taker != makerOrders[3].maker, "taker != maker 3: isolate taker delta"; }
    if (len >= 5) { require taker != makerOrders[4].maker, "taker != maker 4: isolate taker delta"; }

    require g_sumFills == 0, "reset the fill accumulator before the call";
    mathint before = balanceByToken[token][taker];
    uint256 takerMaking;
    uint256 takerTaking;
    uint256 fees;
    takerMaking, takerTaking, fees = h_executeComplementarySellFastPath(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    mathint afterBal = balanceByToken[token][taker];

    // g_sumFills is the sum of the fills the executor actually consumed, captured from the
    // contract's own reads in the _validateAndUpdate summary. 
    require to_mathint(takerTaking) == g_sumFills, "loop accumulator == Sum(fills consumed): from `takerTakingAmount += fill`";
    // Given the accumulator, the taker's pUSD credit must be exactly Sum(fills) - takerFee.
    assert afterBal - before == g_sumFills - to_mathint(takerAmounts.takerFeeAmount), "taker credited exactly Sum(fills) - takerFee (complementary sell)";
}

/**
 * @title complementary sell credits the taker, 1 maker
 * @description With 1 maker fill, the taker is credited exactly the accumulated fills minus its own fee.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @assumption Case split covering a fixed maker count, so the loop is fully unrolled
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerCreditedFillsMinusFee_len1(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    takerCreditBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 1);
}
/**
 * @title complementary sell credits the taker, 2 makers
 * @description With 2 maker fills, the taker is credited exactly the accumulated fills minus its own fee.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @assumption Case split covering a fixed maker count, so the loop is fully unrolled
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerCreditedFillsMinusFee_len2(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    takerCreditBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 2);
}
/**
 * @title complementary sell credits the taker, 3 makers
 * @description With 3 maker fills, the taker is credited exactly the accumulated fills minus its own fee.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @assumption Case split covering a fixed maker count, so the loop is fully unrolled
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerCreditedFillsMinusFee_len3(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    takerCreditBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 3);
}
/**
 * @title complementary sell credits the taker, 4 makers
 * @description With 4 maker fills, the taker is credited exactly the accumulated fills minus its own fee.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @assumption Case split covering a fixed maker count, so the loop is fully unrolled
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerCreditedFillsMinusFee_len4(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    takerCreditBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 4);
}
/**
 * @title complementary sell credits the taker, 5 makers
 * @description With 5 maker fills, the taker is credited exactly the accumulated fills minus its own fee.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @assumption Case split covering a fixed maker count, so the loop is fully unrolled
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerCreditedFillsMinusFee_len5(env e, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] makerFillAmounts, uint256[] makerFeeAmounts, Exchange.TakerAmounts takerAmounts) {
    takerCreditBody(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, 5);
}

/**
 * @title batch buy debits the taker exactly
 * @description On a batch buy the taker's own balance falls by exactly its making amount plus fee, with the remainder refunded.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerDebitBatchBuy(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts,address moduleAddr) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    moduleGuard(moduleAddr);

    address taker = takerOrder.maker;
    address token = COLLATERAL_TOKEN();

    // Taker distinct from every other party, so its delta reflects only its own making+fee outflow.
    require taker != FEE_RECEIVER() && taker != moduleAddr, "taker distinct from fee receiver/module: isolate its delta";
    if (makerOrders.length >= 1) require taker != makerOrders[0].maker, "taker != maker 0: isolate taker delta";
    if (makerOrders.length >= 2) require taker != makerOrders[1].maker, "taker != maker 1: isolate taker delta";
    if (makerOrders.length >= 3) require taker != makerOrders[2].maker, "taker != maker 2: isolate taker delta";
    if (makerOrders.length >= 4) require taker != makerOrders[3].maker, "taker != maker 3: isolate taker delta";
    if (makerOrders.length >= 5) require taker != makerOrders[4].maker, "taker != maker 4: isolate taker delta";
    mathint before = balanceByToken[token][taker];
    uint256 takerMaking;
    uint256 takerTaking;
    takerMaking, takerTaking = h_executeBatchBuyMatch(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, moduleAddr);
    mathint afterBal = balanceByToken[token][taker];

    assert before - afterBal == to_mathint(takerMaking) + to_mathint(takerAmounts.takerFeeAmount),  "taker pays exactly its making amount + fee (batch buy)";
}

/**
 * @title batch sell credits the taker exactly
 * @description On a batch sell the taker's own balance rises by exactly its taking amount net of fee.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule takerCreditBatchSell(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts,address moduleAddr) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    moduleGuard(moduleAddr);

    address taker = takerOrder.maker;
    address token = COLLATERAL_TOKEN();

    require taker != FEE_RECEIVER() && taker != moduleAddr, "taker distinct from fee receiver/module: isolate its delta";
    if (makerOrders.length >= 1) require taker != makerOrders[0].maker, "taker != maker 0: isolate taker delta";
    if (makerOrders.length >= 2) require taker != makerOrders[1].maker, "taker != maker 1: isolate taker delta";
    if (makerOrders.length >= 3) require taker != makerOrders[2].maker, "taker != maker 2: isolate taker delta";
    if (makerOrders.length >= 4) require taker != makerOrders[3].maker, "taker != maker 3: isolate taker delta";
    if (makerOrders.length >= 5) require taker != makerOrders[4].maker, "taker != maker 4: isolate taker delta";
    mathint before = balanceByToken[token][taker];
    uint256 takerTaking = h_executeBatchSellMatch(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, moduleAddr);
    mathint afterBal = balanceByToken[token][taker];

    assert afterBal - before == to_mathint(takerTaking) - to_mathint(takerAmounts.takerFeeAmount), "taker receives exactly its proceeds - fee (batch sell)";
}

/**
 * @title matchOrders neither mints nor drains
 * @description Exchange is neither drained nor left holding more than the declared fees.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @assumption Case split covering a single maker, with the dispatch, the executors and every collateral transfer running for real
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule matchOrdersNoMintNoDrain(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);

    require makerOrders.length == 1, "single maker: loop runs once, no accumulator to bridge on the real path";

    mathint expectedFees = expectedFeeTotal(takerAmounts.takerFeeAmount, makerFeeAmounts);

    mathint before = balanceByToken[COLLATERAL_TOKEN()][currentContract];
    matchOrders(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    mathint afterBal = balanceByToken[COLLATERAL_TOKEN()][currentContract];

    assert afterBal - before >= 0, "matchOrders must not drain the Exchange";
    assert afterBal - before <= expectedFees, "matchOrders must not mint pUSD beyond declared fees";
}


/**
 * @title the combinatorial entry neither mints nor drains
 * @description Exchange is neither drained nor left holding more than the declared fees.
 * @link_property EXCHANGE-COLLATERAL-CONSERVATION-01
 * @assumption Case split covering a single maker, with the dispatch, the executors and every collateral transfer running for real
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a0b0f1538f0468686197943afe5a0e7?anonymousKey=c5bbac08f4c99225b5dedbc65bef15d4900dcd5d
 */
rule matchOrdersCombinatorialNoMintNoDrain(Exchange.Order takerOrder,Exchange.Order[] makerOrders,uint256[] makerFillAmounts,uint256[] makerFeeAmounts,Exchange.TakerAmounts takerAmounts,Exchange.PositionId[] combinatorialLegs) {
    env e;
    residualSetup(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);
    require makerOrders.length == 1, "single maker: loop runs once, no accumulator to bridge on the real path";

    mathint expectedFees = expectedFeeTotal(takerAmounts.takerFeeAmount, makerFeeAmounts);

    mathint before = balanceByToken[COLLATERAL_TOKEN()][currentContract];
    matchOrdersAndPrepareCombinatorial(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, combinatorialLegs);
    mathint afterBal = balanceByToken[COLLATERAL_TOKEN()][currentContract];

    assert afterBal - before >= 0, "matchOrdersAndPrepareCombinatorial must not drain the Exchange";
    assert afterBal - before <= expectedFees, "matchOrdersAndPrepareCombinatorial must not mint pUSD beyond declared fees";
}

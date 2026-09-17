/* =============================================================================
 * [EXCHANGE-TAKER-AMOUNT-01] Taker receives exactly the operator-declared
 * takerReceiveAmount on every path.
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
 * @property EXCHANGE-TAKER-AMOUNT-01 The taker receives exactly the operator-declared receive amount on every path.
 */


using ExchangeHarness as Exchange;

methods {
    function Exchange.COLLATERAL_TOKEN() external returns (address) envfree;
    function Exchange.FEE_RECEIVER() external returns (address) envfree;

    // Non-memory-safe _computeStructHash assembly breaks selector recovery
    // the hash only keys order-status/signature slots.
    function _._hashOrder(Exchange.Order calldata) internal => NONDET;
    // Signature machinery (ecrecover, ERC1271 staticcall, create2) is orthogonal
    // to settlement amounts; NONDET also strips its assembly.
    function _._isValidSignature(bytes32, Exchange.Order calldata) internal => NONDET;

    // Event-only assembly emitters.
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;
    function _._emitTakerEvents(bytes32, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;

    // Module boundary: no module is in the scene; the internal _split/_merge
    // wrappers are summarized so the external module call is never emitted.
    function _._split(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _._merge(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _.moduleById(uint256) external => NONDET;
    function _.prepareCondition(uint256[]) external => NONDET;

    // pUSD ledger: every collateral move routes through these two Solady library
    // functions; `calledContract` is the payer on the 3-arg form (the Exchange).
    function _.safeTransfer(address token, address to, uint256 amount) internal => cashTransferCVL(token, calledContract, to, amount) expect void;
    function _.safeTransferFrom(address token, address from, address to, uint256 amount) internal => cashTransferCVL(token, from, to, amount) expect void;
    // Position-token ledger: the only PositionManager mutator the Exchange calls.
    // Wildcard external summary — fires at the h_ wrapper level where sites resolve.
    // At the public entries sighash recovery fails and the call AUTO-havocs (void =>
    // ghost-invisible), so position-side asserts must live at h_ wrapper level.
    function _.unsafeTransferFrom(address from, address to, uint256 id, uint256 amount) external => posTransferCVL(from, to, id, amount) expect void;
}

/*--------------------------------------------------------------
                        ASSET LEDGERS
--------------------------------------------------------------*/

// Persistent: immune to the AUTO-havocs in the public-entry rule; mathint.
persistent ghost mapping(address => mapping(address => mathint)) cashBal; // [token][holder]
persistent ghost mapping(address => mapping(uint256 => mathint)) posBal;  // [holder][positionId]

// Mirrors an ERC20 transfer (needed because it intercepts internal-call boundary): insufficient-balance revert, exact move.
// from == to nets to zero (sequential sub/add on the same key), matching Solidity.
// Omits the allowance revert on transferFrom: fewer reverts = more executions = sound.
function cashTransferCVL(address token, address from, address to, uint256 amount) {
    if (cashBal[token][from] < to_mathint(amount)) { revert(); }
    cashBal[token][from] = cashBal[token][from] - amount;
    cashBal[token][to] = cashBal[token][to] + amount;
}

// Mirrors PositionManager.unsafeTransferFrom ((needed because it intercepts internal-call boundary).
// Omits the caller-authorization revert:  sound over-approximation.
function posTransferCVL(address from, address to, uint256 id, uint256 amount) {
    if (to == 0) { revert(); }
    if (posBal[from][id] < to_mathint(amount)) { revert(); }
    posBal[from][id] = posBal[from][id] - amount;
    posBal[to][id] = posBal[to][id] + amount;
}

// Rule-side accessor: takerOrder.tokenId (PositionId UDVT) coerces to uint256 at
// the CVL-function boundary.
function posBalOf(address holder, uint256 id) returns mathint {
    return posBal[holder][id];
}

/*--------------------------------------------------------------
                        SHARED SETUP
--------------------------------------------------------------*/

// Shared preconditions: production-shape guards + prover-performance bounds.
function takerSetup(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills) {
    require fills.length == makerOrders.length, "arrays aligned";
    require takerOrder.makerAmount < 2^120 && takerOrder.takerAmount < 2^120, "bound amounts";

    if (makerOrders.length >= 1) {
        // A self-matched leg nets to zero in a ledger delta, so the gross credit is unobservable.
        require makerOrders[0].maker != takerOrder.maker, "exclude self-match";
        // Perf only: same magnitude bound as the taker amounts.
        require fills[0] < 2^120, "bound fill";
        require makerOrders[0].makerAmount < 2^120 && makerOrders[0].takerAmount < 2^120, "bound amounts";
    }
    // Same guards for makers 1 and 2 (loop_iter 3 caps the maker count).
    if (makerOrders.length >= 2) {
        require makerOrders[1].maker != takerOrder.maker, "exclude self-match";
        require fills[1] < 2^120, "bound fill";
        require makerOrders[1].makerAmount < 2^120 && makerOrders[1].takerAmount < 2^120, "bound amounts";
    }
    if (makerOrders.length >= 3) {
        require makerOrders[2].maker != takerOrder.maker, "exclude self-match";
        require fills[2] < 2^120, "bound fill";
        require makerOrders[2].makerAmount < 2^120 && makerOrders[2].takerAmount < 2^120, "bound amounts";
    }
}

// Sum(fills) closed form for up to 3 makers (loop_iter 3).
function sumFills(uint256[] fills) returns mathint {
    if (fills.length == 1) { return to_mathint(fills[0]); }
    if (fills.length == 2) { return to_mathint(fills[0]) + to_mathint(fills[1]); }
    if (fills.length == 3) { return to_mathint(fills[0]) + to_mathint(fills[1]) + to_mathint(fills[2]); }
    return 0;
}

/*--------------------------------------------------------------
                    BUY SIDE (position ledger)
--------------------------------------------------------------*/

/**
 * @title complementary buy pays the taker exactly
 * @description On the complementary buy path the taker receives exactly the sum of the fills in position tokens.
 * @link_property EXCHANGE-TAKER-AMOUNT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7e9c11d35abd471fb466e6ccf25242ec?anonymousKey=1701aa4520725605c8e217c4fb2e5a0bf7823f24
 */
rule takerBuyComplementary(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    takerSetup(takerOrder, makerOrders, fills);
    // _isAllComplementary guarantees maker.tokenId == taker.tokenId before this executor runs.
    if (makerOrders.length >= 1) { require makerOrders[0].tokenId == takerOrder.tokenId, "complementary id"; }
    if (makerOrders.length >= 2) { require makerOrders[1].tokenId == takerOrder.tokenId, "complementary id"; }
    if (makerOrders.length >= 3) { require makerOrders[2].tokenId == takerOrder.tokenId, "complementary id"; }

    mathint balPre = posBalOf(takerOrder.maker, takerOrder.tokenId);
    h_executeComplementaryBuyFastPath(e, takerOrder, makerOrders, fills, fees, ta);
    mathint balPost = posBalOf(takerOrder.maker, takerOrder.tokenId);

    assert balPost - balPre == sumFills(fills), "taker credited Sum(fills)";
}

/**
 * @title batch buy pays the taker exactly
 * @description On a batch buy the taker receives exactly the declared receive amount in position tokens.
 * @link_property EXCHANGE-TAKER-AMOUNT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7e9c11d35abd471fb466e6ccf25242ec?anonymousKey=1701aa4520725605c8e217c4fb2e5a0bf7823f24
 */
rule takerBuyBatch(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta, address moduleAddr) {
    env e;
    takerSetup(takerOrder, makerOrders, fills);
    require takerOrder.maker != currentContract, "exclude taker==Exchange";

    mathint balPre = posBalOf(takerOrder.maker, takerOrder.tokenId);
    h_executeBatchBuyMatch(e, takerOrder, makerOrders, fills, fees, ta, moduleAddr);
    mathint balPost = posBalOf(takerOrder.maker, takerOrder.tokenId);

    assert balPost - balPre == to_mathint(ta.takerReceiveAmount), "taker credited takerReceiveAmount";
}

/*--------------------------------------------------------------
                    SELL SIDE (pUSD ledger)
--------------------------------------------------------------*/

/**
 * @title zero-fee complementary sell pays the taker exactly
 * @description On the zero-fee complementary sell path the taker receives exactly the sum of the fills in collateral.
 * @link_property EXCHANGE-TAKER-AMOUNT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7e9c11d35abd471fb466e6ccf25242ec?anonymousKey=1701aa4520725605c8e217c4fb2e5a0bf7823f24
 */
rule takerSellComplementaryZeroFee(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, Exchange.TakerAmounts ta) {
    env e;
    takerSetup(takerOrder, makerOrders, fills);

    address token = COLLATERAL_TOKEN();
    mathint balPre = cashBal[token][takerOrder.maker];
    h_executeComplementaryZeroFeeSellFastPath(e, takerOrder, makerOrders, fills, ta);
    mathint balPost = cashBal[token][takerOrder.maker];

    assert balPost - balPre == sumFills(fills), "taker credited Sum(fills)";
}

/**
 * @title fee-carrying complementary sell pays the taker exactly
 * @description On the fee-carrying complementary sell path the taker receives exactly its taking amount net of the taker fee.
 * @link_property EXCHANGE-TAKER-AMOUNT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7e9c11d35abd471fb466e6ccf25242ec?anonymousKey=1701aa4520725605c8e217c4fb2e5a0bf7823f24
 */
rule takerSellComplementaryWithFee(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    takerSetup(takerOrder, makerOrders, fills);
    require takerOrder.maker != currentContract, "exclude taker==Exchange";

    address token = COLLATERAL_TOKEN();
    mathint balPre = cashBal[token][takerOrder.maker];
    uint256 making;
    uint256 taking;
    uint256 pooledFees;
    making, taking, pooledFees = h_executeComplementarySellFastPath(e, takerOrder, makerOrders, fills, fees, ta);
    mathint balPost = cashBal[token][takerOrder.maker];

    assert balPost - balPre == to_mathint(taking) - to_mathint(ta.takerFeeAmount), "taker credited taking - fee";
}

/**
 * @title batch sell pays the taker exactly
 * @description On a batch sell the taker receives exactly the declared receive amount net of the taker fee.
 * @link_property EXCHANGE-TAKER-AMOUNT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7e9c11d35abd471fb466e6ccf25242ec?anonymousKey=1701aa4520725605c8e217c4fb2e5a0bf7823f24
 */
rule takerSellBatch(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta, address moduleAddr) {
    env e;
    takerSetup(takerOrder, makerOrders, fills);
    require takerOrder.maker != currentContract, "exclude taker==Exchange";
    require takerOrder.maker != FEE_RECEIVER(), "exclude taker==feeReceiver";

    address token = COLLATERAL_TOKEN();
    mathint balPre = cashBal[token][takerOrder.maker];
    h_executeBatchSellMatch(e, takerOrder, makerOrders, fills, fees, ta, moduleAddr);
    mathint balPost = cashBal[token][takerOrder.maker];

    assert balPost - balPre == to_mathint(ta.takerReceiveAmount) - to_mathint(ta.takerFeeAmount), "taker credited receive - fee";
}

/*--------------------------------------------------------------
        PUBLIC-ENTRY CLOSURE (SELL, real entry points)
--------------------------------------------------------------*/

/**
 * @title the public entries pay the taker exactly
 * @description Driving the real matching entry points end to end, the taker receives exactly the declared receive amount net of the taker fee.
 * @link_property EXCHANGE-TAKER-AMOUNT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7e9c11d35abd471fb466e6ccf25242ec?anonymousKey=1701aa4520725605c8e217c4fb2e5a0bf7823f24
 */
rule takerSellPublicEntries(bool viaCombinatorial, Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    takerSetup(takerOrder, makerOrders, fills);
    require takerOrder.maker != currentContract, "exclude taker==Exchange";
    require makerOrders.length == 1, "single maker keeps VC tractable";
    // BUY has no public closure: position ledger is blind here (see methods block).
    require takerOrder.side == Exchange.Side.SELL, "SELL taker";
    require takerOrder.maker != FEE_RECEIVER(), "exclude taker==feeReceiver";

    address token = COLLATERAL_TOKEN();
    mathint balPre = cashBal[token][takerOrder.maker];
    if (viaCombinatorial) {
        Exchange.PositionId[] legs;
        matchOrdersAndPrepareCombinatorial(e, takerOrder, makerOrders, fills, fees, ta, legs);
    } else {
        matchOrders(e, takerOrder, makerOrders, fills, fees, ta);
    }
    mathint balPost = cashBal[token][takerOrder.maker];

    assert balPost - balPre == to_mathint(ta.takerReceiveAmount) - to_mathint(ta.takerFeeAmount), "taker credited receive - fee";
}

/*--------------------------------------------------------------
   COMPLEMENTARY BINDING
--------------------------------------------------------------*/

/**
 * @title the buy credit is bound to the declared amount
 * @description At the complementary matching step the taker's credit is bound to the declared receive amount.
 * @link_property EXCHANGE-TAKER-AMOUNT-01
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7e9c11d35abd471fb466e6ccf25242ec?anonymousKey=1701aa4520725605c8e217c4fb2e5a0bf7823f24
 */
rule takerBuyComplementaryBinding(Exchange.Order takerOrder, Exchange.Order[] makerOrders, uint256[] fills, uint256[] fees, Exchange.TakerAmounts ta) {
    env e;
    takerSetup(takerOrder, makerOrders, fills);
    require takerOrder.side == Exchange.Side.BUY, "BUY taker";
    require makerOrders.length == 1, "single maker avoids accumulator decoupling";
    require makerOrders[0].tokenId == takerOrder.tokenId, "complementary id";

    mathint balPre = posBalOf(takerOrder.maker, takerOrder.tokenId);
    h_matchComplementaryOrders(e, takerOrder, makerOrders, fills, fees, ta);
    mathint balPost = posBalOf(takerOrder.maker, takerOrder.tokenId);

    assert balPost - balPre == to_mathint(ta.takerReceiveAmount), "taker credited takerReceiveAmount";
}

/* =============================================================================
 * [ORDER-FILL-MONOTONE-01]
 * Order fill is monotone and bounded:
 *   (A) orderStatus.remaining is monotonically non-increasing across fills;
 *   (B) cumulative fills never exceed the order's makerAmount;
 *   (C) the `filled` flag, once true, is never cleared.
 * ============================================================================= */

/*
 * MODULE
 * @module Exchange Order Accounting
 * @contract Exchange
 * @impact An order could be overfilled or refilled after completion, draining the maker beyond what they signed
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 5 iterations
 * PROPERTIES
 * @property ORDER-FILL-MONOTONE-01 Order fill is monotone and bounded: remaining never rises, cumulative fills never exceed the order amount, and the filled flag is never cleared.
 */


using ExchangeHarness as Exchange;

methods {
    // Order key: CONSTANT => one fixed bytes32 for every call in a run.
    // SOUND for a per-slot property: collapsing distinct orders onto one slot only adds aliasing,
    // which makes the guards stricter, never weaker, it cannot hide a monotonicity/latch violation.
    function _._hashOrder(Exchange.Order calldata order) internal => CONSTANT;

    // Gates only (revert-or-nothing); dropping them is conservative and never touches orderStatus.
    function _._validateSignature(bytes32, Exchange.Order calldata order) internal => NONDET;
    function _._isValidSignature(bytes32, Exchange.Order calldata order) internal => NONDET;
    function _._isValidEOASignature(bytes32, address, bytes memory) internal => NONDET;
    function _._isValidERC1271(address, bytes32, bytes memory) internal => NONDET;

    // orderStatus-irrelevant moves / emits / non-linear math: NONDET (also strips their assembly).
    function _.unsafeTransferFrom(address, address, uint256, uint256) external => NONDET;
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata order, uint256, uint256, uint256) internal => NONDET;
    function _._emitTakerEvents(bytes32, Exchange.Order calldata order, uint256, uint256, uint256) internal => NONDET;
    function _._calculateTakingAmount(uint256, uint256, uint256) internal => NONDET;
    function _._split(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _._merge(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _.moduleById(uint256) external => NONDET;
    function _.prepareCondition(uint256[]) external => NONDET;

    // Real reader used by the rules to observe the packed slot (assembly proven by storePackingFaithful).
    function Exchange.getOrderStatus(bytes32) external returns (Exchange.OrderStatus) envfree;
    function Exchange.MAX_FEE_RATE() external returns (uint256) envfree;
}

// Effective remaining: a still-untouched slot (raw 0) means the full makerAmount is fillable.
function effectiveRemaining(uint256 rawRemaining, uint256 makerAmount) returns mathint {
    return rawRemaining == 0 ? to_mathint(makerAmount) : to_mathint(rawRemaining);
}

/*--------------------------------------------------------------
    PACKING FAITHFULNESS
--------------------------------------------------------------*/

/**
 * @title the order status packing is faithful
 * @description The packed order status encodes the filled flag as remaining == 0 and preserves the remaining bits.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule storePackingFaithful(bytes32 orderHash, uint256 remaining) {
    env e;
    // 248-bit field: remaining is stored in the upper bits of a 256-bit slot (shl 8).
    require remaining < 2 ^ 248, "remaining fits 248 bits: it shares one slot with the 8-bit filled flag";

    h_storeOrderStatus(e, orderHash, remaining);
    Exchange.OrderStatus status = getOrderStatus(orderHash);

    assert status.remaining == remaining, "reader must decode the stored remaining exactly";
    assert status.filled == (remaining == 0), "filled latch is exactly remaining == 0";
}

/*--------------------------------------------------------------
    (A) MONOTONE DECREASE  +  (B) BOUNDED BY makerAmount
--------------------------------------------------------------*/

/**
 * @title maker fills decrease remaining
 * @description On the maker path one fill lowers remaining by exactly the fill amount and never below zero, so the consumed amount is bounded by the order amount.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule fillMonotoneDecreasing_makerPath(Exchange.Order order, uint256 fillAmount, uint256 fee) {
    env e;
    require order.makerAmount < 2 ^ 248, "makerAmount fits the uint248 remaining field: else the shl(8) store truncates";
    Exchange.OrderStatus pre = getOrderStatus(h_hashOrder(e, order));
    mathint effBefore = effectiveRemaining(pre.remaining, order.makerAmount);

    bytes32 h = h_validateAndUpdate(e, order, fillAmount, fee);
    Exchange.OrderStatus post = getOrderStatus(h);

    // (A) effective remaining never rises.
    assert to_mathint(post.remaining) <= effBefore, "remaining must be non-increasing (maker path)";
    // (B) this fill consumes exactly fillAmount of the effective remaining, so cumulative fills
    //     can never exceed the starting effective remaining (<= makerAmount on an untouched order).
    assert effBefore - to_mathint(post.remaining) == to_mathint(fillAmount), "one fill consumes exactly fillAmount";
}

/**
 * @title taker fills decrease remaining
 * @description The complementary taker path decreases remaining by exactly the fill amount through the other store caller.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule fillMonotoneDecreasing_takerPath(Exchange.Order order, uint256 fillAmount) {
    env e;
    require order.makerAmount < 2 ^ 248, "makerAmount fits the uint248 remaining field: else the shl(8) store truncates";
    Exchange.OrderStatus pre = getOrderStatus(h_hashOrder(e, order));
    mathint effBefore = effectiveRemaining(pre.remaining, order.makerAmount);

    h_updateOrderStatus(e, order, fillAmount);
    Exchange.OrderStatus post = getOrderStatus(h_hashOrder(e, order));

    assert to_mathint(post.remaining) <= effBefore, "remaining must be non-increasing (taker path)";
    assert effBefore - to_mathint(post.remaining) == to_mathint(fillAmount), "one fill consumes exactly fillAmount";
}

/**
 * @title cumulative fills stay bounded
 * @description Two sequential maker fills consume no more than the starting remaining amount.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule cumulativeFillsBounded(Exchange.Order order, uint256 fill1, uint256 fee1, uint256 fill2, uint256 fee2) {
    env e;
    require order.makerAmount < 2 ^ 248, "makerAmount fits the uint248 remaining field: else the shl(8) store truncates";
    Exchange.OrderStatus pre = getOrderStatus(h_hashOrder(e, order));
    require pre.remaining == 0 && !pre.filled, "start from a fresh order: cap is the full makerAmount";
    mathint cap = to_mathint(order.makerAmount);

    bytes32 h1 = h_validateAndUpdate(e, order, fill1, fee1);
    bytes32 h2 = h_validateAndUpdate(e, order, fill2, fee2);
    Exchange.OrderStatus post = getOrderStatus(h2);

    // Same order -> same slot (CONSTANT hash), so the two fills accumulate on one remaining.
    assert cap - to_mathint(post.remaining) == to_mathint(fill1) + to_mathint(fill2), "fills accumulate on one slot";
    assert to_mathint(fill1) + to_mathint(fill2) <= cap, "cumulative fills never exceed makerAmount";
}

/**
 * @title an overfill reverts
 * @description Attempting to fill more than the supplied order amount always reverts.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule overfillReverts(Exchange.Order order, uint256 fill1, uint256 fee1, uint256 fill2, uint256 fee2) {
    env e;
    require order.makerAmount < 2 ^ 248, "makerAmount fits the uint248 remaining field: else the shl(8) store truncates";
    Exchange.OrderStatus pre = getOrderStatus(h_hashOrder(e, order));
    require pre.remaining == 0 && !pre.filled, "start from a fresh order: effective cap is the full makerAmount";

    h_validateAndUpdate@withrevert(e, order, fill1, fee1);
    require !lastReverted, "first fill must succeed: otherwise the slot stays fresh and the overfill call is unconstrained";

    // Overfill: fill2 strictly exceeds the remaining capacity (makerAmount - fill1) after the first fill.
    require fill2 > order.makerAmount - fill1, "fill2 exceeds remaining capacity: this is the overfill the guard must reject";

    h_validateAndUpdate@withrevert(e, order, fill2, fee2);

    assert lastReverted, "overfilling makerAmount must revert (the fillAmount > remaining guard)";
}

// Methods excluded from the parametric latch rule below, each for a sound reason:
//  - h_storeOrderStatus / h_updateOrderStatus: raw, unguarded harness hooks that write the packed
//    slot directly (no filled-latch check). Production only reaches the store through the guarded
//    _validateAndUpdate (maker) or the _validateOrder-gated taker path (both covered by the rules
//    here), so these test-only hooks — which by design can re-open a slot — are out of scope.
//  - upgradeToAndCall: UUPS upgrade delegatecalls arbitrary implementation code, havoc'ing all
//    storage (including the filled flag). Owner-only upgrade, not an order fill.
//  - ownership-handover trio: writes keccak-derived owner slots the prover may not separate from
//    the orderStatus mapping slot (spurious CEX); they provably never touch orderStatus.
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:h_storeOrderStatus(bytes32,uint256).selector
    || f.selector == sig:h_updateOrderStatus(Exchange.Order,uint256).selector
    || f.selector == sig:upgradeToAndCall(address,bytes).selector
    || f.selector == sig:requestOwnershipHandover().selector
    || f.selector == sig:cancelOwnershipHandover().selector
    || f.selector == sig:completeOwnershipHandover(address).selector;

/*--------------------------------------------------------------
    (C) FILLED IS IRREVERSIBLE
--------------------------------------------------------------*/

/**
 * @title the filled latch is never cleared
 * @description No in-scope method clears a set filled flag, so no entry point can re-open a filled order.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule filledLatchNeverCleared(method f, bytes32 orderHash) filtered { f -> !OUT_OF_SCOPE(f) } {
    // (C) only constrains orders whose latch is already set; readback keys the same slot f writes.
    require getOrderStatus(orderHash).filled, "precondition: the observed slot's filled latch is already set";

    env e;
    calldataarg args;
    f(e, args);

    assert getOrderStatus(orderHash).filled, "no in-scope method may clear a set filled latch";
}

/**
 * @title a filled maker order cannot be refilled
 * @description Once filled, the maker-path validation reverts, so no further store can run and the latch can never be cleared.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule filledLatchIrreversible_makerPath(Exchange.Order order, uint256 fillAmount, uint256 fee) {
    env e;
    require getOrderStatus(h_hashOrder(e, order)).filled, "precondition: order already filled";

    h_validateAndUpdate@withrevert(e, order, fillAmount, fee);

    assert lastReverted, "a filled order must reject any further maker fill";
}

/**
 * @title a filled taker order cannot be rematched
 * @description A filled taker order cannot be matched again through the standard public entry point.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule filledLatchIrreversible_publicEntry(
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] makerFillAmounts,
    uint256[] makerFeeAmounts,
    Exchange.TakerAmounts takerAmounts
) {
    env e;
    require getOrderStatus(h_hashOrder(e, takerOrder)).filled, "precondition: taker order already filled";

    matchOrders@withrevert(e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts);

    assert lastReverted, "matchOrders must reject a filled taker order";
}

/**
 * @title a filled taker order cannot be rematched combinatorially
 * @description A filled taker order cannot be matched again through the combinatorial public entry point either.
 * @link_property ORDER-FILL-MONOTONE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/66d523e43b8d41febf48e82252fb25c0?anonymousKey=37ee8464ee3b1035623d18f0a980213c00a96592
 */
rule filledLatchIrreversible_publicEntryCombinatorial(
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] makerFillAmounts,
    uint256[] makerFeeAmounts,
    Exchange.TakerAmounts takerAmounts,
    Exchange.PositionId[] combinatorialLegs
) {
    env e;
    require getOrderStatus(h_hashOrder(e, takerOrder)).filled, "precondition: taker order already filled";

    matchOrdersAndPrepareCombinatorial@withrevert(
        e, takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, combinatorialLegs
    );

    assert lastReverted, "matchOrdersAndPrepareCombinatorial must reject a filled taker order";
}


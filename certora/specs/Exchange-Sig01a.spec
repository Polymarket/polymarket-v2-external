/* =============================================================================
 * [EXCHANGE-SIG-01a] DISPATCH LAYER
 * An order fills only if preapproved[hash] == true or the signature verifier
 * accepted the order's own hash, where the hash is computed internally as a
 * deterministic function of the 11 signed order fields (signature excluded,
 * matching the EIP-712 struct hash).
 *
 * The verifier (_isValidSignature) is over-approximated by an arbitrary-but-
 * fixed per-hash verdict ghost: this spec proves no fill path bypasses the
 * consent gate.
 * ============================================================================= */

/*
 * MODULE
 * @module Exchange Order Authorization
 * @contract Exchange
 * @impact An order could be filled without its maker consent, spending someone else balance
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property EXCHANGE-SIG-01a An order fills only if it was preapproved or the verifier accepted a signature over the order own hash.
 */


methods {
    function preapproved(bytes32) external returns (bool) envfree;
    function getOrderStatus(bytes32) external returns (Exchange.OrderStatus) envfree;

    // The constructor reads POSITION_MANAGER.COLLATERAL_TOKEN()
    function _.COLLATERAL_TOKEN() external => NONDET;

    // Deterministic ghost function of the 11 signed order fields
    // (signature excluded, exactly like ORDER_TYPEHASH). 
    function _._hashOrder(Exchange.Order calldata order) internal => hashOrderCVL(order) expect bytes32;

    // Over-approximated as an arbitrary-but-fixed verdict per hash.
    // _validateSignature stays concrete, its branching and its preapproved[] read are what we verify.
    function _._isValidSignature(bytes32 orderHash, Exchange.Order calldata order) internal => isValidSigCVL(orderHash) expect bool;

    // Event-only assembly emitters.
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;
    function _._emitTakerEvents(bytes32, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;

    // Token/module movements never touch orderStatus or preapproved.
    function _._split(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _._merge(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _.unsafeTransferFrom(address, address, uint256, uint256) external => NONDET;
    function _.moduleById(uint256) external => NONDET;
    function _.prepareCondition(uint256[]) external => NONDET;

    // pUSD moves via Solady raw calls; balances never feed the consent gate.
    function _.safeTransfer(address, address, uint256) internal => NONDET;
    function _.safeTransferFrom(address, address, address, uint256) internal => NONDET;
}

/*--------------------------------------------------------------
                    CONSENT MODEL (GHOSTS)
--------------------------------------------------------------*/

// Arbitrary-but-fixed order hash per signed-field tuple.
// Persistent: never havoced, so the rule-side and summary-side applications agree.
persistent ghost gOrderHash(uint256, address, address, uint256, uint256, uint256, uint8, uint8, uint256, bytes32, bytes32) returns bytes32;

// Arbitrary-but-fixed verifier verdict per hash. Never written: constant per run,
// so "the verifier said yes for h" is a well-defined per-run fact the asserts can name.
persistent ghost mapping(bytes32 => bool) sigOkGhost;

function sideKey(Exchange.Side s) returns uint8 {
    if (s == Exchange.Side.BUY) { return 0; }
    return 1;
}

function sigTypeKey(Exchange.SignatureType t) returns uint8 {
    if (t == Exchange.SignatureType.EOA) { return 0; }
    if (t == Exchange.SignatureType.POLY_PROXY) { return 1; }
    if (t == Exchange.SignatureType.POLY_GNOSIS_SAFE) { return 2; }
    return 3;
}

// PositionId UDVT coerces to uint256 at the CVL-function boundary.
function tokenIdKey(uint256 id) returns uint256 {
    return id;
}

// _hashOrder summary: deterministic ghost function of the 11 signed order fields.
function hashOrderCVL(Exchange.Order order) returns bytes32 {
    return gOrderHash(
        order.salt, order.maker, order.signer, tokenIdKey(order.tokenId), order.makerAmount,
        order.takerAmount, sideKey(order.side), sigTypeKey(order.signatureType),
        order.timestamp, order.metadata, order.builder
    );
}

// _isValidSignature summary: over-approximated as an arbitrary-but-fixed verdict per hash.
function isValidSigCVL(bytes32 orderHash) returns bool {
    return sigOkGhost[orderHash];
}

// Methods excluded from the parametric rules because they havoc storage.
definition OUT_OF_SCOPE(method f) returns bool =
    f.selector == sig:upgradeToAndCall(address,bytes).selector
    || f.selector == sig:requestOwnershipHandover().selector
    || f.selector == sig:cancelOwnershipHandover().selector
    || f.selector == sig:completeOwnershipHandover(address).selector;

/*--------------------------------------------------------------
        D1 — GLOBAL CHOKE POINT (every method, every hash)
--------------------------------------------------------------*/

/**
 * @title a fill requires consent
 * @description Any change to any order's fill status requires either preapproval or an accepted signature.
 * @link_property EXCHANGE-SIG-01a
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/62bae99572254f5a8c18f945eeabb905?anonymousKey=664247876e2713e20a5adcc6362b75aedaf1ddde
 */
rule fillRequiresConsent(method f, bytes32 h) filtered { f -> !OUT_OF_SCOPE(f) } {
    env e;
    calldataarg args;

    bool preBefore = preapproved(h);
    bool sigOk = sigOkGhost[h];
    Exchange.OrderStatus pre = getOrderStatus(h);

    f(e, args);

    Exchange.OrderStatus post = getOrderStatus(h);
    bool changed = pre.filled != post.filled || pre.remaining != post.remaining;

    assert changed => (preBefore || sigOk),"an order's fill status may change only with preapproval or verifier consent";
}

/*--------------------------------------------------------------
        D2 — ENTRY-ANCHORED CONSENT (taker and every maker)
--------------------------------------------------------------*/

// Drives either public entry; plain (non-withrevert) call so the rules reason over
// successful executions only and rule_sanity proves one exists.
function callMatch(
    env e,
    bool viaCombinatorial,
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] fills,
    uint256[] fees,
    Exchange.TakerAmounts ta
) {
    if (viaCombinatorial) {
        Exchange.PositionId[] legs;
        matchOrdersAndPrepareCombinatorial(e, takerOrder, makerOrders, fills, fees, ta, legs);
    } else {
        matchOrders(e, takerOrder, makerOrders, fills, fees, ta);
    }
}

/**
 * @title a taker fill requires consent
 * @description Consent is required on every successful taker fill.
 * @link_property EXCHANGE-SIG-01a
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/62bae99572254f5a8c18f945eeabb905?anonymousKey=664247876e2713e20a5adcc6362b75aedaf1ddde
 */
rule takerFillRequiresConsent(
    bool viaCombinatorial,
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] fills,
    uint256[] fees,
    Exchange.TakerAmounts ta
) {
    env e;
    bytes32 th = hashOrderCVL(takerOrder);
    bool preBefore = preapproved(th);

    callMatch(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert preBefore || sigOkGhost[th],"a taker order fills only with preapproval or verifier consent";
    assert takerOrder.signature.length == 0 => preBefore,"an unsigned taker order fills only if its hash is preapproved";
}

/**
 * @title a maker fill requires consent
 * @description Consent is required on every successful maker fill, for an arbitrary maker index.
 * @link_property EXCHANGE-SIG-01a
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/62bae99572254f5a8c18f945eeabb905?anonymousKey=664247876e2713e20a5adcc6362b75aedaf1ddde
 */
rule makerFillRequiresConsent(
    uint256 i,
    bool viaCombinatorial,
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] fills,
    uint256[] fees,
    Exchange.TakerAmounts ta
) {
    env e;
    require i < makerOrders.length, "i picks one maker order";
    bytes32 mh = hashOrderCVL(makerOrders[i]);
    bool preBefore = preapproved(mh);

    callMatch(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert preBefore || sigOkGhost[mh],"a maker order fills only with preapproval or verifier consent";
    assert makerOrders[i].signature.length == 0 => preBefore,"an unsigned maker order fills only if its hash is preapproved";
}

/*--------------------------------------------------------------
        D3 — PREAPPROVAL IS NOT A BACKDOOR
--------------------------------------------------------------*/

/**
 * @title preapproval requires a signature
 * @description A preapproval flag turns true only inside the preapprove entry point, and only after the verifier accepted the hash.
 * @link_property EXCHANGE-SIG-01a
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/62bae99572254f5a8c18f945eeabb905?anonymousKey=664247876e2713e20a5adcc6362b75aedaf1ddde
 */
rule preapprovalOnlyViaSignedPreapprove(method f, bytes32 h) filtered { f -> !OUT_OF_SCOPE(f) } {
    env e;
    calldataarg args;
    bool pre = preapproved(h);

    f(e, args);

    bool post = preapproved(h);
    assert (!pre && post) => f.selector == sig:preapproveOrder(Exchange.Order).selector,"only preapproveOrder can grant a preapproval";
    assert (!pre && post) => sigOkGhost[h],"preapproval is granted only after the verifier accepted the hash";
}

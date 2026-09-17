/* =============================================================================
 * [EXCHANGE-USER-PAUSE-01] User pause is self-service, block-delayed, and
 * blocks the user's orders once effective.
 * ============================================================================= */

/*
 * MODULE
 * @module Exchange Order Authorization
 * @contract Exchange
 * @impact An order could be filled without its maker consent, spending someone else balance
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 *
 * PROPERTIES
 * @property EXCHANGE-USER-PAUSE-01 User pause is self-service, block-delayed, and blocks the user orders once effective.
 */


methods {
    function userPausedBlockAt(address) external returns (uint256) envfree;
    function userPauseBlockInterval() external returns (uint256) envfree;
    function isAdmin(address) external returns (bool) envfree;
    function isUserPaused(address) external returns (bool);

    // The constructor reads POSITION_MANAGER.COLLATERAL_TOKEN(); NONDET keeps the
    // invariant's initial-state check free of AUTO havoc.
    function _.COLLATERAL_TOKEN() external => NONDET;

    // _computeStructHash assembly is not memory-safe and breaks selector recovery.
    // The hash keys signatures/order-status, never the pause check, which reads only order.maker.
    function _._hashOrder(Exchange.Order calldata) internal => NONDET;
    // Signature machinery (ecrecover, ERC1271 staticcall, create2). The pause check
    // in _validateOrder runs before signature validation, so NONDET cannot mask it.
    function _._isValidSignature(bytes32, Exchange.Order calldata) internal => NONDET;

    // Event-only assembly emitters.
    function _._emitFeeCharged(address, uint256) internal => NONDET;
    function _._emitOrderFilled(bytes32, address, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;
    function _._emitTakerEvents(bytes32, Exchange.Order calldata, uint256, uint256, uint256) internal => NONDET;

    // Token/module movements never touch userPausedBlockAt.
    function _._split(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _._merge(address, Exchange.ConditionId, uint256) internal => NONDET;
    function _.unsafeTransferFrom(address, address, uint256, uint256) external => NONDET;
    function _.moduleById(uint256) external => NONDET;
    function _.prepareCondition(uint256[]) external => NONDET;

    // pUSD moves via Solady raw calls; balances never feed the pause check.
    function _.safeTransfer(address, address, uint256) internal => NONDET;
    function _.safeTransferFrom(address, address, address, uint256) internal => NONDET;
}

// Mirrors the internal constant Exchange.MAX_PAUSE_BLOCK_INTERVAL.
definition MAX_PAUSE_BLOCK_INTERVAL() returns mathint = 302400;

definition OUT_OF_SCOPE(method f) returns bool = f.selector == sig:upgradeToAndCall(address,bytes).selector;

/*--------------------------------------------------------------
                 PAUSE / UNPAUSE EXACT SEMANTICS
--------------------------------------------------------------*/

/**
 * @title pauseUser is exact
 * @description pauseUser reverts when a pause is already scheduled and otherwise schedules exactly the current block plus the interval, touching nobody else.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule pauseUserExactness(address other) {
    env e;
    uint256 pre = userPausedBlockAt(e.msg.sender);
    uint256 otherPre = userPausedBlockAt(other);
    mathint interval = userPauseBlockInterval();

    pauseUser@withrevert(e);
    bool reverted = lastReverted;

    assert reverted <=> (pre != 0 || e.msg.value > 0 || to_mathint(e.block.number) + interval > max_uint256);
    assert !reverted => to_mathint(userPausedBlockAt(e.msg.sender)) == to_mathint(e.block.number) + interval;
    assert (!reverted && other != e.msg.sender) => userPausedBlockAt(other) == otherPre;
}

/**
 * @title unpauseUser is exact
 * @description unpauseUser always succeeds and clears exactly the caller's own pause slot.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule unpauseUserExactness(address other) {
    env e;
    uint256 otherPre = userPausedBlockAt(other);

    unpauseUser@withrevert(e);
    bool reverted = lastReverted;

    assert reverted <=> e.msg.value > 0;
    assert !reverted => userPausedBlockAt(e.msg.sender) == 0;
    assert (!reverted && other != e.msg.sender) => userPausedBlockAt(other) == otherPre;
}

/*--------------------------------------------------------------
                        DELAY SEMANTICS
--------------------------------------------------------------*/

/**
 * @title the paused predicate is exact
 * @description In every state the paused predicate is exactly that the slot is set and its block has been reached.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule isUserPausedDefinition(address u) {
    env e;
    uint256 pausedAt = userPausedBlockAt(u);
    assert isUserPaused(e, u) <=> (pausedAt != 0 && to_mathint(e.block.number) >= to_mathint(pausedAt));
}

/**
 * @title the pause delay window holds
 * @description After pauseUser the user is not paused at any block before the scheduled one and paused at every block from it onward.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule pauseUserDelayWindow {
    env e1;
    env e2;
    require e1.block.number >= 1, "post-genesis block";

    mathint interval = userPauseBlockInterval();
    pauseUser(e1);

    bool pausedAtE2 = isUserPaused(e2, e1.msg.sender);

    assert to_mathint(e2.block.number) < to_mathint(e1.block.number) + interval => !pausedAtE2;
    assert to_mathint(e2.block.number) >= to_mathint(e1.block.number) + interval => pausedAtE2;
}

/**
 * @title a zero interval pauses immediately
 * @description With a zero interval the pause takes effect in the calling block.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule pauseUserIntervalZeroIsImmediate {
    env e;
    require userPauseBlockInterval() == 0, "deviation case: zero interval";
    require e.block.number >= 1, "post-genesis block";

    pauseUser(e);

    assert isUserPaused(e, e.msg.sender);
}

/*--------------------------------------------------------------
              PAUSED ORDERS CANNOT BE FILLED
--------------------------------------------------------------*/

// Drives either public entry with @withrevert, returns whether it reverted.
function callMatchWithRevert(
    env e,
    bool viaCombinatorial,
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] fills,
    uint256[] fees,
    Exchange.TakerAmounts ta
) returns bool {
    if (viaCombinatorial) {
        Exchange.PositionId[] legs;
        matchOrdersAndPrepareCombinatorial@withrevert(e, takerOrder, makerOrders, fills, fees, ta, legs);
    } else {
        matchOrders@withrevert(e, takerOrder, makerOrders, fills, fees, ta);
    }
    return lastReverted;
}

/**
 * @title a paused maker order cannot be filled
 * @description Any match including a maker order whose maker is paused at call time reverts.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule pausedMakerOrderCannotBeFilled(
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
    require isUserPaused(e, makerOrders[i].maker), "the chosen maker is paused at call time";

    bool reverted = callMatchWithRevert(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert reverted;
}

/**
 * @title a paused taker order cannot be filled
 * @description Any match whose taker is paused at call time reverts.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule pausedTakerOrderCannotBeFilled(
    bool viaCombinatorial,
    Exchange.Order takerOrder,
    Exchange.Order[] makerOrders,
    uint256[] fills,
    uint256[] fees,
    Exchange.TakerAmounts ta
) {
    env e;
    require isUserPaused(e, takerOrder.maker), "the taker is paused at call time";

    bool reverted = callMatchWithRevert(e, viaCombinatorial, takerOrder, makerOrders, fills, fees, ta);

    assert reverted;
}

/*--------------------------------------------------------------
                  PAUSE STORAGE AUTHORIZATION
--------------------------------------------------------------*/

/**
 * @title only the user moves their pause slot
 * @description A pause slot is set only by its own user through pauseUser, cleared only through unpauseUser, and never modified in place.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule userPauseAuthorization(method f, address u) filtered { f -> !OUT_OF_SCOPE(f) } {
    env e;
    calldataarg args;
    uint256 pre = userPausedBlockAt(u);
    mathint intervalPre = userPauseBlockInterval();

    f(e, args);

    uint256 post = userPausedBlockAt(u);

    assert post != pre => e.msg.sender == u;
    assert (pre != 0 && post == 0) => f.selector == sig:unpauseUser().selector;
    assert (pre == 0 && post != 0) => f.selector == sig:pauseUser().selector && to_mathint(post) == to_mathint(e.block.number) + intervalPre;
    assert (pre != 0 && post != 0) => post == pre;
}

/*--------------------------------------------------------------
                       INTERVAL CAP
--------------------------------------------------------------*/

/**
 * @title the interval setter is admin-only and capped
 * @description The pause interval can only be set by an admin and only to a value within the cap.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
rule setUserPauseBlockIntervalExactness(uint256 v) {
    env e;
    bool admin = isAdmin(e.msg.sender);

    setUserPauseBlockInterval@withrevert(e, v);
    bool reverted = lastReverted;

    assert reverted <=> (!admin || to_mathint(v) > MAX_PAUSE_BLOCK_INTERVAL() || e.msg.value > 0);
    assert !reverted => userPauseBlockInterval() == v;
}

/**
 * @title the interval stays within the cap
 * @description The configured pause interval never exceeds its cap in any reachable state.
 * @link_property EXCHANGE-USER-PAUSE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0499cdb2e9254edbaa76ed2934dd3e19?anonymousKey=15a836ab23932f85b2f7567f151914ba7fdffd38
 */
invariant intervalCapped()
    to_mathint(userPauseBlockInterval()) <= MAX_PAUSE_BLOCK_INTERVAL()
    filtered { f -> !OUT_OF_SCOPE(f) }

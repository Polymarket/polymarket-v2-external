/* =============================================================================
 * ACCESS-URI-PAYOUT-01 — uri / getPayout revert for unregistered modules
 *
 * uri(pid) and getPayout(pid, _) revert (with ModuleNotRegistered) exactly when
 * the position's module is unregistered, i.e. moduleById[pid.moduleId()] == 0 —
 * a loud failure instead of calling into address(0) or returning a default.
 * ============================================================================= */

/*
 * MODULE
 * @module PositionManager Access Control
 * @contract PositionManager
 * @impact A contract that is not the position module could mint or burn it, forging unbacked positions
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 *
 * PROPERTIES
 * @property ACCESS-URI-PAYOUT-01 uri and getPayout revert for a position whose module is not registered, instead of calling into the zero address.
 */


using PositionManagerHarness as PositionManager;

methods {
    function moduleById(uint256) external returns (address) envfree;
    function moduleIdOf(uint256) external returns (uint256) envfree;
    // Module payout call in getPayout: unresolved (module is arbitrary storage). A CVL summary
    // returning a well-formed uint256 gives a non-reverting arbitrary return, isolating PositionManager's
    // own logic in the success rule. .
    function _.getPayout(PositionManager.PositionId pid, uint256 amount) external =>
        payoutSummary(calledContract, pid, amount) expect uint256;
}

/*--------------------------------------------------------------
                     MODULE-CALL GHOSTS
--------------------------------------------------------------*/

/// Number of module getPayout calls the summary observed (pinned to 0 pre-call in the forward rule).
ghost mathint g_payoutCallCount;
/// Address the summarized module call was dispatched to.
ghost address g_payoutCallee;
/// Position id forwarded to the module.
ghost uint256 g_payoutPid;
/// Amount forwarded to the module.
ghost uint256 g_payoutAmount;
/// Value the module call returned (and that getPayout should return unchanged).
ghost uint256 g_payoutReturn;

/// Arbitrary, well-sized uint256 return for the unresolved module payout call; records the call.
function payoutSummary(address _callee, uint256 _pid, uint256 _amount) returns uint256 {
    uint256 v;
    g_payoutCallCount = g_payoutCallCount + 1;
    g_payoutCallee = _callee;
    g_payoutPid = _pid;
    g_payoutAmount = _amount;
    g_payoutReturn = v;
    return v;
}

/*--------------------------------------------------------------
                              uri
--------------------------------------------------------------*/

/**
 * @title uri reverts for an unregistered module
 * @description uri reverts when the position's module is not registered.
 * @link_property ACCESS-URI-PAYOUT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e836d75aebf5410caa7132c564ebd3a4?anonymousKey=af8d5c5ef25436b301d6c4e965116fd44256deaa
 */
rule uriRevertsWhenUnregistered(env e, uint256 pid) {
    require moduleById(moduleIdOf(pid)) == 0, "precondition: module for pid is unregistered";

    uri@withrevert(e, pid);

    assert lastReverted, "uri did not revert for an unregistered module";
}

/**
 * @title uri succeeds for a registered module
 * @description For a registered module uri does not revert; the registration guard is its only revert cause.
 * @link_property ACCESS-URI-PAYOUT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e836d75aebf5410caa7132c564ebd3a4?anonymousKey=af8d5c5ef25436b301d6c4e965116fd44256deaa
 */
rule uriSucceedsWhenRegistered(env e, uint256 pid) {
    require moduleById(moduleIdOf(pid)) != 0, "precondition: module for pid is registered";
    require e.msg.value == 0, "view call carries no value";

    uri@withrevert(e, pid);

    assert !lastReverted, "uri reverted despite a registered module";
}

/*--------------------------------------------------------------
                           getPayout
--------------------------------------------------------------*/

/**
 * @title getPayout reverts for an unregistered module
 * @description getPayout reverts when the position's module is not registered, before ever calling the module.
 * @link_property ACCESS-URI-PAYOUT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e836d75aebf5410caa7132c564ebd3a4?anonymousKey=af8d5c5ef25436b301d6c4e965116fd44256deaa
 */
rule getPayoutRevertsWhenUnregistered(env e, uint256 pid, uint256 amount) {
    require moduleById(moduleIdOf(pid)) == 0, "precondition: module for pid is unregistered";

    getPayout@withrevert(e, pid, amount);

    assert lastReverted, "getPayout did not revert for an unregistered module";
}

/**
 * @title getPayout forwards to a registered module
 * @description For a registered module getPayout forwards to it exactly once with the arguments unchanged and returns its result verbatim.
 * @link_property ACCESS-URI-PAYOUT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e836d75aebf5410caa7132c564ebd3a4?anonymousKey=af8d5c5ef25436b301d6c4e965116fd44256deaa
 */
rule getPayoutSucceedsWhenRegistered(env e, uint256 pid, uint256 amount) {
    require moduleById(moduleIdOf(pid)) != 0, "precondition: module for pid is registered";
    require e.msg.value == 0, "view call carries no value";
    require g_payoutCallCount == 0, "no module call observed before this getPayout";

    uint256 ret = getPayout@withrevert(e, pid, amount);

    assert !lastReverted, "getPayout reverted in PositionManager despite a registered module";
    assert g_payoutCallCount == 1, "getPayout must call the module exactly once";
    assert g_payoutCallee == moduleById(moduleIdOf(pid)), "must dispatch to the registered module";
    assert g_payoutPid == pid, "position id must be forwarded unchanged";
    assert g_payoutAmount == amount, "amount must be forwarded unchanged";
    assert ret == g_payoutReturn, "getPayout must return the module's result verbatim";
}

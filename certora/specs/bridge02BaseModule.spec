/* =============================================================================
 * BRIDGE-02 — mintFromBridge / burnFromBridge functional correctness (SHARED RULES)
 *
 * mintFromBridge(to, pid, amount):
 *   - callable only by the bridge (onlyBridge => _checkRoles(BRIDGE_ROLE))
 *   - credits EXACTLY `amount` of `pid` to `to`, raises supply by `amount`,
 *     and touches no other balance. amount == 0 is a no-op.
 * burnFromBridge(pids[], amounts[]):
 *   - callable only by the bridge
 *   - burns EXACTLY the specified amount of each position FROM THE MODULE,
 *     lowers supply accordingly, and touches no other balance.
 * ============================================================================= */

import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";
import "summaries/PositionManager_base_summaries.spec";

// PositionManager is in both scenes; it carries the shared PositionId UDVT.
using PositionManager as PositionManager;

methods {
    /* ---- harness pure helper: typed PositionId -> ghostBalance key (defined on both harnesses) ---- */
    function pidUnwrap(PositionManager.PositionId) external returns (uint256) envfree;

    /* ---- OwnableRoles read + write wiring: makes onlyBridge consult the ghost ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// BRIDGE_ROLE == _ROLE_3 == bit 3 == ghostHasRole3[currentContract][user].
definition isBridge(env e) returns bool = ghostHasRole3[currentContract][e.msg.sender];

/* =============================================================================
 *                              mintFromBridge
 * ============================================================================= */

// Only an address holding the bridge role can mint: no role => the call reverts.
rule mintFromBridgeOnlyBridge(env e, address to, PositionManager.PositionId pid, uint256 amount) {
    mintFromBridge@withrevert(e, to, pid, amount);
    assert !isBridge(e) => lastReverted;
}

// A successful mint credits EXACTLY `amount` of `pid` to `to` and raises supply by `amount`.
rule mintFromBridgeCreditsRecipient(env e, address to, PositionManager.PositionId pid, uint256 amount) {
    require isBridge(e), "e.msg.sender is the bridge";
    uint256 id = pidUnwrap(pid);
    mathint balBefore = ghostBalance[to][id];
    mathint supBefore = ghostSupply[id];

    mintFromBridge(e, to, pid, amount);

    assert ghostBalance[to][id] == balBefore + amount;
    assert ghostSupply[id] == supBefore + amount;
}

// A mint touches no balance other than (to, pid).
rule mintFromBridgeNoOtherBalanceChange(
    env e, address to, PositionManager.PositionId pid, uint256 amount, address other, uint256 otherId
) {
    require other != to || otherId != pidUnwrap(pid), "other is not to destination or otherId is not pidUnwrap(pid)";
    mathint before = ghostBalance[other][otherId];

    mintFromBridge(e, to, pid, amount);

    assert ghostBalance[other][otherId] == before;
}

/* =============================================================================
 *                              burnFromBridge
 * ============================================================================= */

// Only an address holding the bridge role can burn: no role => the call reverts.
rule burnFromBridgeOnlyBridge(env e, PositionManager.PositionId[] pids, uint256[] amounts) {
    burnFromBridge@withrevert(e, pids, amounts);
    assert !isBridge(e) => lastReverted;
}

// A successful burn debits the module (positions are pre-transferred to it) by exactly
// the total amount targeting each id, and lowers supply by the same amount. 
rule burnFromBridgeDebitsModule(
    env e, PositionManager.PositionId[] pids, uint256[] amounts, uint256 id
) {
    require pids.length <= 5 && pids.length == amounts.length, "pids.length is less than 5 and pids.length is == amounts.length";
    mathint balBefore = ghostBalance[currentContract][id];
    mathint supBefore = ghostSupply[id];

    // Aliasing-aware: total debit to `id` is the sum over every index that targets it.
    mathint e0 = (pids.length > 0 && pidUnwrap(pids[0]) == id) ? to_mathint(amounts[0]) : 0;
    mathint e1 = (pids.length > 1 && pidUnwrap(pids[1]) == id) ? to_mathint(amounts[1]) : 0;
    mathint e2 = (pids.length > 2 && pidUnwrap(pids[2]) == id) ? to_mathint(amounts[2]) : 0;
    mathint e3 = (pids.length > 3 && pidUnwrap(pids[3]) == id) ? to_mathint(amounts[3]) : 0;
    mathint e4 = (pids.length > 4 && pidUnwrap(pids[4]) == id) ? to_mathint(amounts[4]) : 0;
    mathint expected = e0 + e1 + e2 + e3 + e4;

    burnFromBridge(e, pids, amounts);

    assert ghostBalance[currentContract][id] == balBefore - expected;
    assert ghostSupply[id] == supBefore - expected;
}

// A burn only ever debits the module (the batchBurn caller); no other holder is touched.
rule burnFromBridgeNoOtherAddressChange(
    env e, PositionManager.PositionId[] pids, uint256[] amounts, address other, uint256 otherId
) {
    require pids.length <= 5 && pids.length == amounts.length, "pids.length is less than 5 and pids.length is == amounts.length";
    require other != currentContract, "other is not the current contract";
    mathint before = ghostBalance[other][otherId];

    burnFromBridge(e, pids, amounts);

    assert ghostBalance[other][otherId] == before;
}

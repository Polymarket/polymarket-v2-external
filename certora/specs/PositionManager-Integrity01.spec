/* =============================================================================
 * PM-INT-RULE-01 — mint / batchMint / burn / batchBurn integrity
 *
 * mint(to, pid, amount)        credits EXACTLY `amount` of `pid` to `to`.
 * batchMint(to, ids, amts)     credits EXACTLY the per-id sum of `amts` to `to`.
 * burn(pid, amount)            debits  EXACTLY `amount` of `pid` from the caller.
 * batchBurn(ids, amts)         debits  EXACTLY the per-id sum of `amts` from the caller.
 *
 * ============================================================================= */

/*
 * MODULE
 * @module PositionManager Token Integrity
 * @contract PositionManager
 * @impact mint and burn could move amounts other than requested, so position supply would stop matching the collateral behind it
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property PM-INT-RULE-01 mint, batchMint, burn and batchBurn move exactly the requested amounts and revert exactly on their documented causes.
 */


using PositionManager as PositionManager;

methods {
    function balanceOf(address, uint256) external returns (uint256) envfree;
    function isApprovedForAll(address, address) external returns (bool) envfree;
    function moduleById(uint256) external returns (address) envfree;
    function crossModuleAuth(address) external returns (bool) envfree;
}

/// Top 8 bits of a position id (Ids.sol MODULE_SHIFT = 248).
definition moduleIdOf(uint256 pid) returns uint256 = pid >> 248;

/*--------------------------------------------------------------
                             MINT
--------------------------------------------------------------*/

/**
 * @title mint integrity
 * @description mint credits the recipient with exactly the requested amount and changes nothing else.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 */
rule mintIntegrity(env e, address to, uint256 pid, uint256 amount) {
    address u; uint256 id;   // arbitrary observer balance
    address o; address op;   // arbitrary approval pair
    uint256 m; address a;    // arbitrary registry entries

    mathint toBefore    = balanceOf(to, pid);
    mathint otherBefore = balanceOf(u, id);
    bool approvalBefore = isApprovedForAll(o, op);
    address modBefore   = moduleById(m);
    bool authBefore     = crossModuleAuth(a);

    mint(e, to, pid, amount);

    assert to_mathint(balanceOf(to, pid)) == toBefore + amount;
    assert !(u == to && id == pid) => to_mathint(balanceOf(u, id)) == otherBefore;
    assert isApprovedForAll(o, op) == approvalBefore;
    assert moduleById(m) == modBefore && crossModuleAuth(a) == authBefore;
}

/**
 * @title mint revert causes
 * @description mint reverts exactly when the caller is unauthorized, the recipient is zero, the balance would overflow, or value was sent.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 */
rule mintReverts(env e, address to, uint256 pid, uint256 amount) {
    bool authorized = moduleById(moduleIdOf(pid)) == e.msg.sender || crossModuleAuth(e.msg.sender);
    mathint toBefore = balanceOf(to, pid);

    mint@withrevert(e, to, pid, amount);

    assert lastReverted <=> (!authorized || to == 0 || toBefore + amount > max_uint256 || e.msg.value != 0);
}

/*--------------------------------------------------------------
                           BATCH MINT
--------------------------------------------------------------*/

/**
 * @title batchMint integrity
 * @description batchMint credits the recipient with exactly the per-id sum of the amounts and changes nothing else.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 * @dev Duplicate ids compound: the check sums all matching indices.
 */
rule batchMintIntegrity(env e, address to, uint256[] ids, uint256[] amounts) {
    require ids.length <= 3, "bounded batch: exact unrolling at loop_iter 3";

    address u; uint256 id;   // arbitrary observer balance
    address o; address op;   // arbitrary approval pair
    uint256 m; address a;    // arbitrary registry entries

    mathint before      = balanceOf(u, id);
    bool approvalBefore = isApprovedForAll(o, op);
    address modBefore   = moduleById(m);
    bool authBefore     = crossModuleAuth(a);

    // expected credit to (u, id): sum of amounts[i] with ids[i] == id, only when u == to
    mathint delta = (u == to && ids.length > 0 && ids[0] == id ? to_mathint(amounts[0]) : 0)
        + (u == to && ids.length > 1 && ids[1] == id ? to_mathint(amounts[1]) : 0)
        + (u == to && ids.length > 2 && ids[2] == id ? to_mathint(amounts[2]) : 0);

    batchMint(e, to, ids, amounts);

    assert to_mathint(balanceOf(u, id)) == before + delta;
    assert isApprovedForAll(o, op) == approvalBefore;
    assert moduleById(m) == modBefore && crossModuleAuth(a) == authBefore;
}

/**
 * @title batchMint revert causes
 * @description batchMint reverts exactly when the caller is unauthorized, the lengths mismatch, the recipient is zero, any id would overflow, or value was sent.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 */
rule batchMintReverts(env e, address to, uint256[] ids, uint256[] amounts) {
    require ids.length <= 3, "len<=3: exact unroll";

    // authorized == crossModuleAuth, or caller owns the module of every id in the batch.
    // Mirrors onlyModuleByPositionIds: the first non-owned id reverts unless crossModuleAuth is set.
    bool authorized = crossModuleAuth(e.msg.sender)
        || ((ids.length > 0 => moduleById(moduleIdOf(ids[0])) == e.msg.sender)
            && (ids.length > 1 => moduleById(moduleIdOf(ids[1])) == e.msg.sender)
            && (ids.length > 2 => moduleById(moduleIdOf(ids[2])) == e.msg.sender));

    // Per-id credited total (duplicate ids compound)
    mathint t0 = (amounts.length > 0 && ids.length > 0 ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 1 && ids.length > 1 && ids[1] == ids[0] ? to_mathint(amounts[1]) : 0)
        + (amounts.length > 2 && ids.length > 2 && ids[2] == ids[0] ? to_mathint(amounts[2]) : 0);
    mathint t1 = (amounts.length > 1 && ids.length > 1 ? to_mathint(amounts[1]) : 0)
        + (amounts.length > 0 && ids.length > 0 && ids[0] == ids[1] ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 2 && ids.length > 2 && ids[2] == ids[1] ? to_mathint(amounts[2]) : 0);
    mathint t2 = (amounts.length > 2 && ids.length > 2 ? to_mathint(amounts[2]) : 0)
        + (amounts.length > 0 && ids.length > 0 && ids[0] == ids[2] ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 1 && ids.length > 1 && ids[1] == ids[2] ? to_mathint(amounts[1]) : 0);

    bool overflow = (ids.length > 0 && to_mathint(balanceOf(to, ids[0])) + t0 > max_uint256)
        || (ids.length > 1 && to_mathint(balanceOf(to, ids[1])) + t1 > max_uint256)
        || (ids.length > 2 && to_mathint(balanceOf(to, ids[2])) + t2 > max_uint256);

    batchMint@withrevert(e, to, ids, amounts);

    assert lastReverted
        <=> (!authorized || ids.length != amounts.length || to == 0 || overflow || e.msg.value != 0);
}

/*--------------------------------------------------------------
                             BURN
--------------------------------------------------------------*/

/**
 * @title burn integrity
 * @description burn debits the caller by exactly the requested amount and changes nothing else.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 */
rule burnIntegrity(env e, uint256 pid, uint256 amount) {
    address u; uint256 id;   // arbitrary observer balance
    address o; address op;   // arbitrary approval pair
    uint256 m; address a;    // arbitrary registry entries

    mathint callerBefore = balanceOf(e.msg.sender, pid);
    mathint otherBefore  = balanceOf(u, id);
    bool approvalBefore  = isApprovedForAll(o, op);
    address modBefore    = moduleById(m);
    bool authBefore      = crossModuleAuth(a);

    burn(e, pid, amount);

    assert to_mathint(balanceOf(e.msg.sender, pid)) == callerBefore - amount;
    assert !(u == e.msg.sender && id == pid) => to_mathint(balanceOf(u, id)) == otherBefore;
    assert isApprovedForAll(o, op) == approvalBefore;
    assert moduleById(m) == modBefore && crossModuleAuth(a) == authBefore;
}

/**
 * @title burn revert causes
 * @description burn reverts exactly when the caller is unauthorized, the balance is insufficient, or value was sent.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 */
rule burnReverts(env e, uint256 pid, uint256 amount) {
    bool authorized = moduleById(moduleIdOf(pid)) == e.msg.sender || crossModuleAuth(e.msg.sender);
    mathint callerBefore = balanceOf(e.msg.sender, pid);

    burn@withrevert(e, pid, amount);

    assert lastReverted <=> (!authorized || callerBefore < to_mathint(amount) || e.msg.value != 0);
}

/*--------------------------------------------------------------
                           BATCH BURN
--------------------------------------------------------------*/

/**
 * @title batchBurn integrity
 * @description batchBurn debits the caller by exactly the per-id sum of the amounts and changes nothing else.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 */
rule batchBurnIntegrity(env e, uint256[] ids, uint256[] amounts) {
    require ids.length <= 3, "bounded batch: exact unrolling at loop_iter 3";

    address u; uint256 id;   // arbitrary observer balance
    address o; address op;   // arbitrary approval pair
    uint256 m; address a;    // arbitrary registry entries

    mathint before      = balanceOf(u, id);
    bool approvalBefore = isApprovedForAll(o, op);
    address modBefore   = moduleById(m);
    bool authBefore     = crossModuleAuth(a);

    // expected debit from (u, id): sum of amounts[i] with ids[i] == id, only when u == caller
    mathint delta = (u == e.msg.sender && ids.length > 0 && ids[0] == id ? to_mathint(amounts[0]) : 0)
        + (u == e.msg.sender && ids.length > 1 && ids[1] == id ? to_mathint(amounts[1]) : 0)
        + (u == e.msg.sender && ids.length > 2 && ids[2] == id ? to_mathint(amounts[2]) : 0);

    batchBurn(e, ids, amounts);

    assert to_mathint(balanceOf(u, id)) == before - delta;
    assert isApprovedForAll(o, op) == approvalBefore;
    assert moduleById(m) == modBefore && crossModuleAuth(a) == authBefore;
}

/**
 * @title batchBurn revert causes
 * @description batchBurn reverts exactly when the caller is unauthorized, the lengths mismatch, any id has an insufficient balance, or value was sent.
 * @link_property PM-INT-RULE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/af27c9fc52964e7c9cf88ab2837a3ad3?anonymousKey=d6c443747befae749dfac6cb8d00ce8d898c0af6
 */
rule batchBurnReverts(env e, uint256[] ids, uint256[] amounts) {
    require ids.length <= 3, "len<=3: exact unroll";

    // authorized == crossModuleAuth, or caller owns the module of every id in the batch.
    // Mirrors onlyModuleByPositionIds: the first non-owned id reverts unless crossModuleAuth is set.
    bool authorized = crossModuleAuth(e.msg.sender)
        || ((ids.length > 0 => moduleById(moduleIdOf(ids[0])) == e.msg.sender)
            && (ids.length > 1 => moduleById(moduleIdOf(ids[1])) == e.msg.sender)
            && (ids.length > 2 => moduleById(moduleIdOf(ids[2])) == e.msg.sender));

    // Per-id debited total (duplicate ids compound).
    mathint t0 = (amounts.length > 0 && ids.length > 0 ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 1 && ids.length > 1 && ids[1] == ids[0] ? to_mathint(amounts[1]) : 0)
        + (amounts.length > 2 && ids.length > 2 && ids[2] == ids[0] ? to_mathint(amounts[2]) : 0);
    mathint t1 = (amounts.length > 1 && ids.length > 1 ? to_mathint(amounts[1]) : 0)
        + (amounts.length > 0 && ids.length > 0 && ids[0] == ids[1] ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 2 && ids.length > 2 && ids[2] == ids[1] ? to_mathint(amounts[2]) : 0);
    mathint t2 = (amounts.length > 2 && ids.length > 2 ? to_mathint(amounts[2]) : 0)
        + (amounts.length > 0 && ids.length > 0 && ids[0] == ids[2] ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 1 && ids.length > 1 && ids[1] == ids[2] ? to_mathint(amounts[1]) : 0);

    bool insufficient = (ids.length > 0 && to_mathint(balanceOf(e.msg.sender, ids[0])) < t0)
        || (ids.length > 1 && to_mathint(balanceOf(e.msg.sender, ids[1])) < t1)
        || (ids.length > 2 && to_mathint(balanceOf(e.msg.sender, ids[2])) < t2);

    batchBurn@withrevert(e, ids, amounts);

    assert lastReverted <=> (!authorized || ids.length != amounts.length || insufficient || e.msg.value != 0);
}

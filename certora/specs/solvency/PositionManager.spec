// PositionManager solvency + supply conservation spec
//
// The solvency model

/*
 * MODULE
 * @module PositionManager Solvency
 * @contract PositionManager
 * @impact Position supply could move outside the mint and burn entry points, creating unbacked positions
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 *
 * PROPERTIES
 * @property PM-GLOB-SOLVENCY PositionManager preserves the collateral backing of every outstanding position it has minted, under every possible market resolution.
 * @property PM-SUPPLY-01 Position supply changes only through the mint and burn entry points.
 */

import "BinarySolvencyBase.spec";

/**
 * @title solvency preserved
 * @description Every PositionManager method preserves the backing inequality between counted assets and the sum of pUSD supply and worst-case liability.
 * @link_property PM-GLOB-SOLVENCY
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/34d8aa9c438740309342af6c7622fd37?anonymousKey=3a73df38e141fe419335c89db4bc08b3fc6a1e9d
 */
use rule solvencyPreserved;

methods {
    function balanceOf(address, uint256) external returns (uint256) envfree;
}

// ------------------------------------------------------------
// ERC1155 supply conservation
// ------------------------------------------------------------

// The six entry points that can move a position balance. Every other method leaves it fixed, so the
// witness at the end of the rule is a real demand exactly where a change is possible.
definition isBalanceMover(method f) returns bool =
    f.selector == sig:mint(address,PositionManager.PositionId,uint256).selector
    || f.selector == sig:batchMint(address,PositionManager.PositionId[],uint256[]).selector
    || f.selector == sig:burn(PositionManager.PositionId,uint256).selector
    || f.selector == sig:batchBurn(PositionManager.PositionId[],uint256[]).selector
    || f.selector == sig:unsafeTransferFrom(address,address,PositionManager.PositionId,uint256).selector
    || f.selector
        == sig:unsafeBatchTransferFrom(address,address,PositionManager.PositionId[],uint256[]).selector
    || f.selector == sig:safeTransferFrom(address,address,uint256,uint256,bytes).selector
    || f.selector == sig:safeBatchTransferFrom(address,address,uint256[],uint256[],bytes).selector;

/**
 * @title position supply changes only through mint and burn
 * @description Position supply per id changes only through the mint and burn entry points.
 * @link_property PM-SUPPLY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/34d8aa9c438740309342af6c7622fd37?anonymousKey=3a73df38e141fe419335c89db4bc08b3fc6a1e9d
 */
rule positionSupplyConservation(env e, method f, calldataarg args) filtered { f -> !f.isView } {
    uint256 id;
    address holder;
    uint256 balanceBefore = balanceOf(holder, id);

    f(e, args);

    uint256 balanceAfter = balanceOf(holder, id);

    assert balanceBefore < balanceAfter => (
        f.selector == sig:mint(address,PositionManager.PositionId,uint256).selector
        || f.selector == sig:batchMint(address,PositionManager.PositionId[],uint256[]).selector
        || f.selector == sig:unsafeTransferFrom(address,address,PositionManager.PositionId,uint256).selector
        || f.selector
            == sig:unsafeBatchTransferFrom(address,address,PositionManager.PositionId[],uint256[]).selector
        || f.selector == sig:safeTransferFrom(address,address,uint256,uint256,bytes).selector
        || f.selector == sig:safeBatchTransferFrom(address,address,uint256[],uint256[],bytes).selector
    ), "a balance rose outside mint, batchMint and the transfer entry points";

    assert balanceBefore > balanceAfter => (
        f.selector == sig:burn(PositionManager.PositionId,uint256).selector
        || f.selector == sig:batchBurn(PositionManager.PositionId[],uint256[]).selector
        || f.selector == sig:unsafeTransferFrom(address,address,PositionManager.PositionId,uint256).selector
        || f.selector
            == sig:unsafeBatchTransferFrom(address,address,PositionManager.PositionId[],uint256[]).selector
        || f.selector == sig:safeTransferFrom(address,address,uint256,uint256,bytes).selector
        || f.selector == sig:safeBatchTransferFrom(address,address,uint256[],uint256[],bytes).selector
    ), "a balance fell outside burn, batchBurn and the transfer entry points";

    satisfy balanceBefore != balanceAfter || !isBalanceMover(f);
}

// ------------------------------------------------------------
// Transfer exactness
// ------------------------------------------------------------

/**
 * @title an unsafe transfer moves exactly the requested amount
 * @description unsafeTransferFrom debits the sender and credits the recipient by exactly the requested amount, and moves no other balance cell.
 * @link_property PM-SUPPLY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/34d8aa9c438740309342af6c7622fd37?anonymousKey=3a73df38e141fe419335c89db4bc08b3fc6a1e9d
 */
rule unsafeTransferIsExact(
    env e, address from, address to, PositionManager.PositionId pid, uint256 amount,
    address other, uint256 q
) {
    require from != to, "a self-transfer is a no-op; the moving case is the one worth pinning";
    uint256 id = assert_uint256(pid);

    // any cell outside the two legs of this transfer
    require !(other == from && q == id) && !(other == to && q == id), "an untouched cell";

    mathint fromBefore = to_mathint(balanceOf(from, id));
    mathint toBefore = to_mathint(balanceOf(to, id));
    mathint otherBefore = to_mathint(balanceOf(other, q));

    unsafeTransferFrom(e, from, to, pid, amount);

    assert to_mathint(balanceOf(from, id)) == fromBefore - amount, "the sender loses exactly the amount";
    assert to_mathint(balanceOf(to, id)) == toBefore + amount, "the recipient gains exactly the amount";
    assert to_mathint(balanceOf(other, q)) == otherBefore, "no other balance cell moves";
}

/**
 * @title an unsafe batch transfer conserves the pair
 * @description unsafeBatchTransferFrom leaves the sender-plus-recipient total unchanged for every id, and moves no third party.
 * @link_property PM-SUPPLY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/34d8aa9c438740309342af6c7622fd37?anonymousKey=3a73df38e141fe419335c89db4bc08b3fc6a1e9d
 */
rule unsafeBatchTransferConservesThePair(
    env e, address from, address to, PositionManager.PositionId[] pids, uint256[] amounts,
    address other, uint256 q
) {
    require from != to, "a self-transfer is a no-op; the moving case is the one worth pinning";
    require other != from && other != to, "a third party to this transfer";

    mathint pairBefore = to_mathint(balanceOf(from, q)) + to_mathint(balanceOf(to, q));
    mathint otherBefore = to_mathint(balanceOf(other, q));

    unsafeBatchTransferFrom(e, from, to, pids, amounts);

    assert to_mathint(balanceOf(from, q)) + to_mathint(balanceOf(to, q)) == pairBefore,
        "a batch transfer creates and destroys nothing across the two parties";
    assert to_mathint(balanceOf(other, q)) == otherBefore, "a batch transfer moves no third party";
}

/**
 * @title a safe transfer moves exactly the requested amount
 * @description safeTransferFrom debits the sender and credits the recipient by exactly the requested amount, and moves no other balance.
 * @link_property PM-SUPPLY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/34d8aa9c438740309342af6c7622fd37?anonymousKey=3a73df38e141fe419335c89db4bc08b3fc6a1e9d
 */
rule safeTransferIsExact(
    env e, address from, address to, uint256 id, uint256 amount, bytes data,
    address other, uint256 q
) {
    require from != to, "a self-transfer is a no-op; the moving case is the one worth pinning";

    // any cell outside the two legs of this transfer
    require !(other == from && q == id) && !(other == to && q == id), "an untouched cell";

    mathint fromBefore = to_mathint(balanceOf(from, id));
    mathint toBefore = to_mathint(balanceOf(to, id));
    mathint otherBefore = to_mathint(balanceOf(other, q));

    safeTransferFrom(e, from, to, id, amount, data);

    assert to_mathint(balanceOf(from, id)) == fromBefore - amount, "the sender loses exactly the amount";
    assert to_mathint(balanceOf(to, id)) == toBefore + amount, "the recipient gains exactly the amount";
    assert to_mathint(balanceOf(other, q)) == otherBefore, "no other balance cell moves";
}

/**
 * @title a safe batch transfer conserves the pair
 * @description safeBatchTransferFrom leaves the sender-plus-recipient total unchanged for every id, and moves no third party.
 * @link_property PM-SUPPLY-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/34d8aa9c438740309342af6c7622fd37?anonymousKey=3a73df38e141fe419335c89db4bc08b3fc6a1e9d
 */
rule safeBatchTransferConservesThePair(
    env e, address from, address to, uint256[] ids, uint256[] amounts, bytes data,
    address other, uint256 q
) {
    require from != to, "a self-transfer is a no-op; the moving case is the one worth pinning";
    require other != from && other != to, "a third party to this transfer";

    mathint pairBefore = to_mathint(balanceOf(from, q)) + to_mathint(balanceOf(to, q));
    mathint otherBefore = to_mathint(balanceOf(other, q));

    safeBatchTransferFrom(e, from, to, ids, amounts, data);

    assert to_mathint(balanceOf(from, q)) + to_mathint(balanceOf(to, q)) == pairBefore,
        "a safe batch transfer creates and destroys nothing across the two parties";
    assert to_mathint(balanceOf(other, q)) == otherBefore, "a safe batch transfer moves no third party";
}

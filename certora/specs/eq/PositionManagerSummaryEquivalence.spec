/*
 * PositionManager summary equivalence rules.
 *
 * These rules certify that the auth-aware token summaries in
 * certora/specs/summaries/PositionManager_full_summaries.spec faithfully model the real
 * PositionManager assembly (revert + effect), so the solvency spec can soundly rely on
 * them. The summaries themselves live in that shared file; this spec is rules-only.
 */

import "../summaries/Solady/SafeTransferLib.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";

// Ghost model + core CVL helpers + the auth-aware wrappers under test.
import "../summaries/PositionManager_full_summaries.spec";

using PositionManager as PositionManager;

methods {
    // Real storage reads
    function balanceOf(address, uint256) external returns (uint256) envfree;
    function isApprovedForAll(address, address) external returns (bool) envfree;
}

/*--------------------------------------------------------------
                    mint summary faithfulness
--------------------------------------------------------------*/

/// @title mintWithAuthCVL faithfully models the real PositionManager.mint (revert + effect).
rule mintSummaryEquivalence(env e, address to, uint256 posId, uint256 amount, address holder, uint256 q) {
    // Couple the ghost to REAL storage on every key we observe.
    require ghostBalance[to][posId] == to_mathint(balanceOf(to, posId));
    require ghostBalance[holder][q] == to_mathint(balanceOf(holder, q));

    mathint supplyBefore = ghostSupply[posId];

    mint@withrevert(e, to, posId, amount);
    bool realRev = lastReverted;

    mintWithAuthCVL@withrevert(e, to, posId, amount);
    bool summaryRev = lastReverted;

    mathint supplyAfter = ghostSupply[posId];

    // (1) Revert equivalence.
    assert realRev == summaryRev, "mint summary: revert must match the real mint (incl auth + value)";

    // (2) Effect on every non-reverting execution.
    assert !realRev => to_mathint(balanceOf(to, posId)) == ghostBalance[to][posId],
        "mint summary: minted balance must match the real mint";
    assert !realRev => to_mathint(balanceOf(holder, q)) == ghostBalance[holder][q],
        "mint summary: untouched balance must stay coupled to the ghost (frame)";
    assert !realRev => supplyAfter == supplyBefore + amount,
        "mint summary: total supply is not updated correctly";

    satisfy !realRev;
}

/*--------------------------------------------------------------
                    burn summary faithfulness
--------------------------------------------------------------*/

/// @title burnWithAuthCVL faithfully models the real PositionManager.burn (revert + effect).
rule burnSummaryEquivalence(env e, uint256 posId, uint256 amount, address holder, uint256 q) {
    // Couple the burned key (so the wrapper's sufficient-balance check matches reality) and observed key.
    require ghostBalance[e.msg.sender][posId] == to_mathint(balanceOf(e.msg.sender, posId));
    require ghostBalance[holder][q] == to_mathint(balanceOf(holder, q));

    mathint supplyBefore = ghostSupply[posId];

    burn@withrevert(e, posId, amount);
    bool realRev = lastReverted;

    burnWithAuthCVL@withrevert(e, posId, amount);
    bool summaryRev = lastReverted;

    mathint supplyAfter = ghostSupply[posId];

    assert realRev == summaryRev, "burn summary: revert must match the real burn (incl auth + value)";
    assert !realRev => to_mathint(balanceOf(holder, q)) == ghostBalance[holder][q],
        "burn summary: balance must match the real burn";

    assert !realRev => supplyAfter == supplyBefore - amount,
        "burn summary: total supply is not updated correctly";

    satisfy !realRev;
}

/*--------------------------------------------------------------
            unsafeTransferFrom summary faithfulness
--------------------------------------------------------------*/

/// @title transferWithAuthCVl faithfully models unsafeTransferFrom.
rule transferOperatorSummaryEquivalence(
    env e, address from, address to, uint256 id, uint256 amount, address holder, uint256 q
) {
    require ghostApproved[from][e.msg.sender] == isApprovedForAll(from, e.msg.sender);
    require ghostBalance[from][id] == to_mathint(balanceOf(from, id));
    require ghostBalance[to][id] == to_mathint(balanceOf(to, id));
    require ghostBalance[holder][q] == to_mathint(balanceOf(holder, q));

    mathint supplyBefore = ghostSupply[id];

    unsafeTransferFrom@withrevert(e, from, to, id, amount);
    bool realRev = lastReverted;

    transferWithAuthCVL@withrevert(e, from, to, id, amount);
    bool summaryRev = lastReverted;

    mathint supplyAfter = ghostSupply[id];

    assert realRev == summaryRev,
        "transfer summary (operator): revert must match the real unsafeTransferFrom (incl approval auth)";
    assert !realRev => to_mathint(balanceOf(holder, q)) == ghostBalance[holder][q],
        "transfer summary (operator): balance must match the real unsafeTransferFrom";
    assert supplyBefore == supplyAfter,
        "transfer summary (operator): transfer should not change supply";

    satisfy !realRev;
}

/*--------------------------------------------------------------
                  batchMint summary faithfulness
--------------------------------------------------------------*/

/// @title batchMintWithAuthCVL faithfully models the real batchMint (revert + effect).
rule batchMintSummaryEquivalence(env e, address to, uint256[] ids, uint256[] amounts, address holder, uint256 q) {
    require ids.length <= 3;
    require amounts.length <= 3;   // allow length mismatch -> tests the ArrayLengthsMismatch revert
    require ghostBalance[holder][q] == to_mathint(balanceOf(holder, q));
    // Couple every minted key so the wrapper's per-element overflow check matches reality.
    if (ids.length > 0) { require ghostBalance[to][ids[0]] == to_mathint(balanceOf(to, ids[0])); }
    if (ids.length > 1) { require ghostBalance[to][ids[1]] == to_mathint(balanceOf(to, ids[1])); }
    if (ids.length > 2) { require ghostBalance[to][ids[2]] == to_mathint(balanceOf(to, ids[2])); }

    batchMint@withrevert(e, to, ids, amounts);
    bool realRev = lastReverted;

    batchMintWithAuthCVL@withrevert(e, to, ids, amounts);
    bool summaryRev = lastReverted;

    assert realRev == summaryRev, "batchMint summary: revert must match the real batchMint (incl auth + value)";
    assert !realRev => to_mathint(balanceOf(holder, q)) == ghostBalance[holder][q],
        "batchMint summary: balance must match the real batchMint";

    satisfy !realRev;
}

/*--------------------------------------------------------------
                  batchBurn summary faithfulness
--------------------------------------------------------------*/

/// @title batchBurnWithAuthCVL faithfully models the real batchBurn (revert + effect).
rule batchBurnSummaryEquivalence(env e, uint256[] ids, uint256[] amounts, address holder, uint256 q) {
    require ids.length <= 3;
    require amounts.length <= 3;   // allow length mismatch -> tests the ArrayLengthsMismatch revert
    require ghostBalance[holder][q] == to_mathint(balanceOf(holder, q));
    // Couple every burned key so the wrapper's per-element sufficient-balance check matches reality.
    if (ids.length > 0) { require ghostBalance[e.msg.sender][ids[0]] == to_mathint(balanceOf(e.msg.sender, ids[0])); }
    if (ids.length > 1) { require ghostBalance[e.msg.sender][ids[1]] == to_mathint(balanceOf(e.msg.sender, ids[1])); }
    if (ids.length > 2) { require ghostBalance[e.msg.sender][ids[2]] == to_mathint(balanceOf(e.msg.sender, ids[2])); }

    batchBurn@withrevert(e, ids, amounts);
    bool realRev = lastReverted;

    batchBurnWithAuthCVL@withrevert(e, ids, amounts);
    bool summaryRev = lastReverted;

    assert realRev == summaryRev, "batchBurn summary: revert must match the real batchBurn (incl auth + value)";
    assert !realRev => to_mathint(balanceOf(holder, q)) == ghostBalance[holder][q],
        "batchBurn summary: balance must match the real batchBurn";

    satisfy !realRev;
}

/*--------------------------------------------------------------
            unsafeBatchTransferFrom summary faithfulness
--------------------------------------------------------------*/

/// @title batchTransferWithAuthCVL faithfully models the real unsafeBatchTransferFrom (revert + effect).
rule batchTransferSummaryEquivalence(
    env e, address from, address to, uint256[] ids, uint256[] amounts, address holder, uint256 q
) {
    require ids.length <= 3;
    require amounts.length <= 3;   // allow length mismatch -> tests the ArrayLengthsMismatch revert
    require ghostApproved[from][e.msg.sender] == isApprovedForAll(from, e.msg.sender);
    require ghostBalance[holder][q] == to_mathint(balanceOf(holder, q));
    // Couple every from-side key (insufficient) and to-side key (overflow) so the wrapper's per-element
    // checks match reality.
    if (ids.length > 0) { require ghostBalance[from][ids[0]] == to_mathint(balanceOf(from, ids[0])); require ghostBalance[to][ids[0]] == to_mathint(balanceOf(to, ids[0])); }
    if (ids.length > 1) { require ghostBalance[from][ids[1]] == to_mathint(balanceOf(from, ids[1])); require ghostBalance[to][ids[1]] == to_mathint(balanceOf(to, ids[1])); }
    if (ids.length > 2) { require ghostBalance[from][ids[2]] == to_mathint(balanceOf(from, ids[2])); require ghostBalance[to][ids[2]] == to_mathint(balanceOf(to, ids[2])); }

    unsafeBatchTransferFrom@withrevert(e, from, to, ids, amounts);
    bool realRev = lastReverted;

    batchTransferWithAuthCVL@withrevert(e, from, to, ids, amounts);
    bool summaryRev = lastReverted;

    assert realRev == summaryRev,
        "batch transfer summary: revert must match the real unsafeBatchTransferFrom (incl approval auth)";
    assert !realRev => to_mathint(balanceOf(holder, q)) == ghostBalance[holder][q],
        "batch transfer summary: balance must match the real unsafeBatchTransferFrom";

    satisfy !realRev;
}
/* =============================================================================
 * COMBO-SPLIT-MERGE-01 — Combinatorial split/merge are exact inverses and
 *                        conserve collateral against the YES/NO pair.
 *
 * split(_to, c, amount):
 *   - mints `amount` of the combinatorial YES position (pid = pidOf(c,0)) to _to[0]
 *   - mints `amount` of the combinatorial NO  position (pid = pidOf(c,1)) to _to[1]
 *   - burns `amount` pUSD collateral
 * merge(_to, c, amount):
 *   - mints `amount` pUSD collateral to _to
 *   - burns `amount` of the YES + NO pair (held by the module)
 * ============================================================================= */

/*
 * MODULE
 * @module CombinatorialModule Position Lifecycle
 * @contract CombinatorialModule
 * @impact split, merge or wrap could break the pairing between a conjunction and its complement, so the pair would redeem for more collateral than created it
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 3 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 * PROPERTIES
 * @property COMBO-SPLIT-MERGE-01 Combinatorial split and merge are exact inverses and conserve collateral against the YES and NO pair.
 */


// Solady ERC1155 ghost model: ghostBalance / ghostSupply + mintCVL / burnByCVL helpers.
import "summaries/Solady/ERC1155.spec";

using CombinatorialModuleHarness as CombinatorialModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;

methods {
    // harness pure helpers (envfree)
    function pidOf(CombinatorialModule.ConditionId, uint256) external returns (uint256) envfree;
    function condModuleId(CombinatorialModule.ConditionId) external returns (uint256) envfree;

    // module immutable wiring (mirrors solvencyBinary / bridgeBinary)
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;

    // PositionManager position-token mutators (split mints, merge batch-burns).
    // External summaries: the assembly bodies have no internal calls to attach to.
    function _.mint(address _to, uint256 _positionId, uint256 _amount) external => mintCVL(_to, _positionId, _amount) expect void;
    function _.batchBurn(uint256[] _positionIds, uint256[] _amounts) external with (env e) => batchBurnPositionCVL(e, _positionIds, _amounts) expect void;

    // pUSD collateral supply: distinct sighashes from PositionManager's mint(address,uint256,uint256) / burn(uint256,uint256).
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_to, _amount) expect void;
    function _.burn(uint256 _amount) external => ctBurnCVL(_amount) expect void;
}

// batchBurn: unrolled (loop bound 3). Burns from the caller (the module holds the legs);
// by = 0 mirrors Solady's 3-arg _batchBurn wrapper (no operator-approval check).
function batchBurnPositionCVL(env e, uint256[] positionIds, uint256[] amounts) {
    if (positionIds.length > 0) { burnByCVL(0, e.msg.sender, positionIds[0], amounts[0]); }
    if (positionIds.length > 1) { burnByCVL(0, e.msg.sender, positionIds[1], amounts[1]); }
    if (positionIds.length > 2) { burnByCVL(0, e.msg.sender, positionIds[2], amounts[2]); }
}

// Net pUSD supply: split burns it (-amount), merge mints it (+amount) used by the conservation + inverse rules.
ghost mathint ghostCollatSupply;

// Per-recipient pUSD credited by merge's mint (mint-side only; burn is module-side), read ONLY by mergeEffects to pin recipient correctness.
// The inverse rules never read it, so collateral may legitimately be minted to any recipient on merge without breaking the round-trip.
ghost mapping(address => mathint) ctBalance;

// CollateralToken.mint(to, amount): merge mints collateral out => +supply, +recipient.
function ctMintCVL(address to, uint256 amount) {
    ghostCollatSupply = ghostCollatSupply + to_mathint(amount);
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

// CollateralToken.burn(amount): split burns collateral in => -supply.
function ctBurnCVL(uint256 amount) {
    ghostCollatSupply = ghostCollatSupply - to_mathint(amount);
}

definition COMBINATORIAL() returns uint256 = 3;

/* =============================================================================
 *                              split — exact effects
 * ============================================================================= */

/**
 * @title combinatorial split effects
 * @description A successful split raises the YES and NO supplies by the amount, credits the two recipients, and burns exactly that much collateral.
 * @link_property COMBO-SPLIT-MERGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2ff833c22650411cba0053ed70cc3606?anonymousKey=266e367e29ea5dcce1e24b0f425c749406cd0a3a
 */
rule splitEffects(env e, address[] to, CombinatorialModule.ConditionId c, uint256 amount, address other) {
    require to[0] != other, "other is not the YES leg recipient";
    require to[1] != other, "other is not the NO leg recipient";

    uint256 yesPid = pidOf(c, 0);
    uint256 noPid = pidOf(c, 1);

    mathint yesSupBefore = ghostSupply[yesPid];
    mathint noSupBefore = ghostSupply[noPid];
    mathint collatBefore = ghostCollatSupply;
    mathint yesBalBefore = ghostBalance[to[0]][yesPid];
    mathint noBalBefore = ghostBalance[to[1]][noPid];

    // A third party's position balances before split.
    mathint yesBalBeforeOther = ghostBalance[other][yesPid];
    mathint noBalBeforeOther = ghostBalance[other][noPid];

    split(e, to, c, amount);

    // YES/NO position ids always differ (outcome byte 0 vs 1), so the supply moves are independent.
    assert ghostSupply[yesPid] == yesSupBefore + amount;
    assert ghostSupply[noPid] == noSupBefore + amount;
    assert ghostCollatSupply == collatBefore - amount;

    // When to[0] == to[1] the legs are still distinct ids, so each credit is exact.
    assert ghostBalance[to[0]][yesPid] == yesBalBefore + amount;
    assert ghostBalance[to[1]][noPid] == noBalBefore + amount;

    // Isolation: no third party's position balances move.
    assert ghostBalance[other][yesPid] == yesBalBeforeOther;
    assert ghostBalance[other][noPid] == noBalBeforeOther;
}

/**
 * @title split only operates on combinatorial conditions
 * @description split rejects any condition that is not a combinatorial one.
 * @link_property COMBO-SPLIT-MERGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2ff833c22650411cba0053ed70cc3606?anonymousKey=266e367e29ea5dcce1e24b0f425c749406cd0a3a
 */
rule splitOnlyCombinatorial(env e, address[] to, CombinatorialModule.ConditionId c, uint256 amount) {
    split@withrevert(e, to, c, amount);
    assert !lastReverted => condModuleId(c) == COMBINATORIAL();
}

/* =============================================================================
 *                              merge — exact effects
 * ============================================================================= */

/**
 * @title combinatorial merge effects
 * @description A successful merge lowers the YES and NO supplies by the amount, debits the module's pre-transferred legs, and mints exactly that much collateral.
 * @link_property COMBO-SPLIT-MERGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2ff833c22650411cba0053ed70cc3606?anonymousKey=266e367e29ea5dcce1e24b0f425c749406cd0a3a
 */
rule mergeEffects(env e, address to, CombinatorialModule.ConditionId c, uint256 amount, address other) {
    require other != to, "other is not the collateral recipient";
    require other != currentContract, "other is not the module holding the legs";

    uint256 yesPid = pidOf(c, 0);
    uint256 noPid = pidOf(c, 1);

    mathint yesSupBefore = ghostSupply[yesPid];
    mathint noSupBefore = ghostSupply[noPid];
    mathint collatBefore = ghostCollatSupply;
    mathint yesBalBefore = ghostBalance[currentContract][yesPid];
    mathint noBalBefore = ghostBalance[currentContract][noPid];

    // Collateral recipient credit + a third party's balances before merge.
    mathint ctBalBefore = ctBalance[to];
    mathint ctBalBeforeOther = ctBalance[other];
    mathint yesBalBeforeOther = ghostBalance[other][yesPid];
    mathint noBalBeforeOther = ghostBalance[other][noPid];

    merge(e, to, c, amount);

    assert ghostSupply[yesPid] == yesSupBefore - amount;
    assert ghostSupply[noPid] == noSupBefore - amount;
    assert ghostCollatSupply == collatBefore + amount;
    assert ghostBalance[currentContract][yesPid] == yesBalBefore - amount;
    assert ghostBalance[currentContract][noPid] == noBalBefore - amount;

    // Recipient correctness: exactly `amount` pUSD is credited to `to`.
    assert ctBalance[to] == ctBalBefore + amount;

    // Isolation: no third party's collateral or position balances move.
    assert ctBalance[other] == ctBalBeforeOther;
    assert ghostBalance[other][yesPid] == yesBalBeforeOther;
    assert ghostBalance[other][noPid] == noBalBeforeOther;
}

/* =============================================================================
 *                  split then merge is the identity (exact inverse)
 * ============================================================================= */

/**
 * @title split then merge restores the state
 * @description split followed by merge restores the position supplies, the module leg balances and the collateral supply to their pre-split values.
 * @link_property COMBO-SPLIT-MERGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2ff833c22650411cba0053ed70cc3606?anonymousKey=266e367e29ea5dcce1e24b0f425c749406cd0a3a
 */
rule splitThenMergeIsInverse(
    env e, address[] to, CombinatorialModule.ConditionId c, uint256 amount, address mergeTo
) {
    // Route both freshly-minted legs to the module so merge can burn them.
    require to[0] == currentContract && to[1] == currentContract, "both split legs are minted to the module";

    uint256 yesPid = pidOf(c, 0);
    uint256 noPid = pidOf(c, 1);

    mathint yesSupBefore = ghostSupply[yesPid];
    mathint noSupBefore = ghostSupply[noPid];
    mathint collatBefore = ghostCollatSupply;
    mathint yesBalBefore = ghostBalance[currentContract][yesPid];
    mathint noBalBefore = ghostBalance[currentContract][noPid];

    split(e, to, c, amount);
    merge(e, mergeTo, c, amount);

    assert ghostSupply[yesPid] == yesSupBefore;
    assert ghostSupply[noPid] == noSupBefore;
    assert ghostCollatSupply == collatBefore;
    assert ghostBalance[currentContract][yesPid] == yesBalBefore;
    assert ghostBalance[currentContract][noPid] == noBalBefore;
}

/* =============================================================================
 *                  merge then split is the identity (exact inverse)
 * ============================================================================= */

/**
 * @title merge then split restores the state
 * @description merge followed by split re-mints the pair and re-burns the collateral, restoring the pre-merge state.
 * @link_property COMBO-SPLIT-MERGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2ff833c22650411cba0053ed70cc3606?anonymousKey=266e367e29ea5dcce1e24b0f425c749406cd0a3a
 */
rule mergeThenSplitIsInverse(
    env e, address[] to, CombinatorialModule.ConditionId c, uint256 amount
) {
    require to[0] == currentContract && to[1] == currentContract, "module already holds both legs to merge";

    uint256 yesPid = pidOf(c, 0);
    uint256 noPid = pidOf(c, 1);

    mathint yesSupBefore = ghostSupply[yesPid];
    mathint noSupBefore = ghostSupply[noPid];
    mathint collatBefore = ghostCollatSupply;
    mathint yesBalBefore = ghostBalance[currentContract][yesPid];
    mathint noBalBefore = ghostBalance[currentContract][noPid];

    merge(e, currentContract, c, amount);
    split(e, to, c, amount);

    assert ghostSupply[yesPid] == yesSupBefore;
    assert ghostSupply[noPid] == noSupBefore;
    assert ghostCollatSupply == collatBefore;
    assert ghostBalance[currentContract][yesPid] == yesBalBefore;
    assert ghostBalance[currentContract][noPid] == noBalBefore;
}

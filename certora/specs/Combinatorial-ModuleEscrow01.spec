/* =============================================================================
 * [MODULE-ESCROW-01] — CombinatorialModule scene wiring
 * Rules live in ModuleEscrow01-BaseModule.spec; this file carries only the
 * CombinatorialModule scene: harness `using`, payout/yes-basket taming, filters.
 * ============================================================================= */

/*
 * MODULE
 * @module CombinatorialModule Global Solvency
 * @contract CombinatorialModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 3 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 *
 * PROPERTIES
 * @property COMBO-MODULE-ESCROW-01 No CombinatorialModule function increases the module's own pUSD balance, or its balance of any position id, beyond what the caller explicitly directed to it.
 */


import "ModuleEscrow01-BaseModule.spec";

using CombinatorialModuleHarness as CombinatorialModule;

methods {
    /* ---- payout oracle: the per-leg mulDiv product chain blows up the solver
     * and its cross-module getResult read is unresolved in this scene.
     * The payout value is irrelevant to escrow — it is minted to `_to`, never retained —
     * so an unconstrained value is a sound over-approximation. ---- */
    function _._getPositionPayout(CombinatorialModule.PositionId _positionId, uint256 _amount) internal => positionPayoutNondetCVL(_positionId, _amount) expect uint256;
    function _._getConditionPayout(CombinatorialModule.PositionId _leg) internal => condPayoutNondetCVL(_leg) expect (bool, uint256);

    /* ---- YES-basket builders: their mstore-length assembly poisons selector
     * recovery, forcing the following PM mint/batchBurn into AUTO-havoc.
     * yesBasketCVL keeps those PM calls summarized and tracked. ---- */
    function _._prepareYesBasketPositionIds(CombinatorialModule.PositionId[] memory _fullLegs) internal => yesBasketCVL(_fullLegs) expect (CombinatorialModule.PositionId[] memory);
    function _._getYesBasketPositionIds(CombinatorialModule.PositionId[] memory _fullLegs) internal =>  yesBasketCVL(_fullLegs) expect (CombinatorialModule.PositionId[] memory);

    /* ---- _trimArray: same mstore-length assembly poisoning — compress's trailing
     * CT.mint / PM.mint / PM.burn call sites all AUTO-havoc without this ---- */
    function _._trimArray(CombinatorialModule.PositionId[] memory _arr, uint256 _length) internal => trimArrayCVL(_arr, _length) expect (CombinatorialModule.PositionId[] memory);
}

// Unconstrained payout stand-ins (unassigned CVL locals are nondeterministic).
function positionPayoutNondetCVL(CombinatorialModule.PositionId _positionId, uint256 _amount) returns uint256 {
    uint256 payout;
    return payout;
}

// Unconstrained condPayout (unassigned CVL locals are nondeterministic).
function condPayoutNondetCVL(CombinatorialModule.PositionId _leg) returns (bool, uint256) {
    bool resolved;
    uint256 numerator;
    return (resolved, numerator);
}

// Clean stand-in for the YES-basket position-id builders .
function yesBasketCVL(CombinatorialModule.PositionId[] fullLegs) returns CombinatorialModule.PositionId[] {
    CombinatorialModule.PositionId[] res;
    require res.length == fullLegs.length, "one basket position id per leg";
    return res;
}

// Clean stand-in for _trimArray (mstore-length assembly removed): a fresh array of
// the trimmed length. Element values are unconstrained — irrelevant to escrow, the
// resulting position is minted to `_to` either way. Drops the _length <= _arr.length revert 
function trimArrayCVL(CombinatorialModule.PositionId[] arr, uint256 len) returns CombinatorialModule.PositionId[] {
    CombinatorialModule.PositionId[] res;
    require res.length == len, "trim returns the length-`len` prefix";
    return res;
}

definition EXCLUDED(method f) returns bool =
    f.isView
    || f.isPure
    || f.selector == sig:requestOwnershipHandover().selector
    || f.selector == sig:cancelOwnershipHandover().selector
    || f.selector == sig:completeOwnershipHandover(address).selector;

/**
 * @title module never accumulates collateral
 * @description The module's own pUSD balance grows by at most the amount the caller explicitly directed to it.
 * @link_property COMBO-MODULE-ESCROW-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/5f12047666084268b360ddfef163e43a?anonymousKey=68b39069e0407172ef0e4505416f94e810a2da75
 */
use rule moduleNeverAccumulatesCollateral filtered { f -> !EXCLUDED(f) }
/**
 * @title module never accumulates positions
 * @description The module's own balance of every position id grows by at most the amount the caller explicitly minted to it for that id.
 * @link_property COMBO-MODULE-ESCROW-01
 * @status VERIFIED
 * @report Combinatorial-ModuleEscrow01 https://prover.certora.com/output/10505052/5f12047666084268b360ddfef163e43a?anonymousKey=68b39069e0407172ef0e4505416f94e810a2da75
 * @report Combinatorial-ModuleEscrow01-mergeOnEvent https://prover.certora.com/output/10505052/9c4457689bf9408090daa8c63097461b?anonymousKey=208ac9e64a2113adc63e52ca261c4448b89c975a
 */
use rule moduleNeverAccumulatesPositions filtered { f -> !EXCLUDED(f) }

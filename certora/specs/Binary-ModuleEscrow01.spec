/* =============================================================================
 * [MODULE-ESCROW-01] — BinaryModule scene wiring
 * Rules live in ModuleEscrow01-BaseModule.spec; this file carries only the
 * BinaryModule scene: harness `using`, legacy-CTF firewall, links, filters.
 * ============================================================================= */

/*
 * MODULE
 * @module BinaryModule Global Solvency
 * @contract BinaryModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 * PROPERTIES
 * @property BINARY-MODULE-ESCROW-01 No BinaryModule function increases the module's own pUSD balance, or its balance of any position id, beyond what the caller explicitly directed to it.
 */


import "ModuleEscrow01-BaseModule.spec";
import "summaries/CTFHelpers_summaries.spec";

using BinaryModuleHarness as BinaryModule;
using ConditionalTokens as ConditionalTokens;

methods {
    /* ---- legacy immutable wiring ---- */
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    /* ---- legacy/migration firewall ----
     * NONDET keeps the legacy-CTF subtree out of the scene. The one
     * tracked-asset write on the migration path, POSITION_MANAGER.batchMint,
     * stays real and is intercepted by the tracked summaries. ---- */
    function _._resolveMigrationCondition(BinaryModule.ConditionId) internal => NONDET;
    function _._redeemLegacyPositions(bytes32) internal => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;
    // Legacy CTF/USDC.e flows are out of scope for this property.
    function ConditionalTokens.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;
    function ConditionalTokens.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    function _.unwrap(address, uint256) external => NONDET;
}

// PositionManager and CollateralToken intentionally NOT linked (so the ghost
// summaries fire); CONDITIONAL_TOKENS linked so the harness constructor resolves.
links {
    BinaryModule.CONDITIONAL_TOKENS => ConditionalTokens;
}

// Solady's ownership-handover functions are assembly-only and havoced by the prover; 
// they cannot move collateral or positions.
definition EXCLUDED(method f) returns bool =
    f.isView
    || f.isPure
    || f.selector == sig:requestOwnershipHandover().selector
    || f.selector == sig:cancelOwnershipHandover().selector
    || f.selector == sig:completeOwnershipHandover(address).selector
    // Equivalence-proof harness wrapper (BinaryMigrationResolutionEquivalence); not a production entry point
    || f.selector == sig:finalizeMigrationResolutionModel(BinaryModule.ConditionId).selector;

/**
 * @title module never accumulates collateral
 * @description The module's own pUSD balance grows by at most the amount the caller explicitly directed to it.
 * @link_property BINARY-MODULE-ESCROW-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/149bb30fd7404709b8b56004bb14c03d?anonymousKey=4598a644a01c906ec5a8011237accc77fee9a15f
 */
use rule moduleNeverAccumulatesCollateral filtered { f -> !EXCLUDED(f) }
/**
 * @title module never accumulates positions
 * @description The module's own balance of every position id grows by at most the amount the caller explicitly minted to it for that id.
 * @link_property BINARY-MODULE-ESCROW-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/149bb30fd7404709b8b56004bb14c03d?anonymousKey=4598a644a01c906ec5a8011237accc77fee9a15f
 */
use rule moduleNeverAccumulatesPositions filtered { f -> !EXCLUDED(f) }

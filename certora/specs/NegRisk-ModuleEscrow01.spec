/* =============================================================================
 * [MODULE-ESCROW-01] — NegRiskModule scene wiring
 * Rules live in ModuleEscrow01-BaseModule.spec. This file carries only the
 * NegRiskModule scene: harness `using`, legacy-CTF firewall, links, filters.
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Global Solvency
 * @contract NegRiskModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 * PROPERTIES
 * @property NEGRISK-MODULE-ESCROW-01 No NegRiskModule function increases the module's own pUSD balance, or its balance of any position id, beyond what the caller explicitly directed to it.
 */


import "ModuleEscrow01-BaseModule.spec";
import "summaries/CTFHelpers_summaries.spec";
import "summaries/Solady/SafeTransferLib.spec";

using NegRiskModuleHarness as NegRiskModule;
using ConditionalTokens as ConditionalTokens;
using DummyERC20Impl as Wcol;

methods {
    /* ---- legacy id derivation -> NONDET (feeds only legacy lookups) ---- */
    // (CTHelpers.getCollectionId is owned by CTFHelpers_summaries.spec — do not redeclare.)
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;

    /* ---- legacy/migration firewall : these paths move only legacy CTF positions and USDC.e, never pUSD
     * nor PositionManager balances; POSITION_MANAGER.batchMint stays real. ---- */
    function _._resolveMigrationCondition(NegRiskModule.ConditionId) internal => NONDET;
    function _._redeemLegacyPositions(bytes32) internal => NONDET;
    function _._settleLegacyCollateralToVault() internal => NONDET;
    // EXACT receiver, not `_.`: wildcard summaries apply only to unresolved calls, and
    // CONDITIONAL_TOKENS is linked. The real Gnosis mergePositions body was inlined and
    // its calldata-passed `collateralToken.transfer(msg.sender, ...)` AUTO-havoc'd the
    // ghosts (spurious migratePositions CEX). Exact summaries override resolved calls too.
    function ConditionalTokens.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;
    function ConditionalTokens.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;

    // wrapped-collateral wrap/unwrap move USDC.e, not pUSD -> NONDET.
    function _.wrap(address _asset, address _to, uint256 _amount) external => NONDET;
    function _.unwrap(address _asset, address _to, uint256 _amount) external => NONDET;
}

// PositionManager and CollateralToken intentionally NOT linked (so the ghost
// summaries fire); legacy immutables linked so the harness constructor resolves.
links {
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;
    NegRiskModule.WRAPPED_COLLATERAL_TOKEN => Wcol;
}

// Solady's ownership-handover functions are assembly-only and havoced by the
// prover; they cannot move collateral or positions.
definition EXCLUDED(method f) returns bool =
    f.isView
    || f.isPure
    || f.selector == sig:requestOwnershipHandover().selector
    || f.selector == sig:cancelOwnershipHandover().selector
    || f.selector == sig:completeOwnershipHandover(address).selector
    // Equivalence-proof harness wrappers (NegRiskMigrationEquivalence); not production entry points
    || f.selector == sig:redeemIfResolvedDuringMigrateReal(NegRiskModule.ConditionId,bytes32).selector
    || f.selector == sig:legacyMintedKey(bytes32,uint256).selector;

/**
 * @title module never accumulates collateral
 * @description The module's own pUSD balance grows by at most the amount the caller explicitly directed to it.
 * @link_property NEGRISK-MODULE-ESCROW-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0cced238403d4e42b11c81a8a2de817c?anonymousKey=f1957a6e052ddac6c9bff81598949b89eea364f1
 */
use rule moduleNeverAccumulatesCollateral filtered { f -> !EXCLUDED(f) }
/**
 * @title module never accumulates positions
 * @description The module's own balance of every position id grows by at most the amount the caller explicitly minted to it for that id.
 * @link_property NEGRISK-MODULE-ESCROW-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/0cced238403d4e42b11c81a8a2de817c?anonymousKey=f1957a6e052ddac6c9bff81598949b89eea364f1
 */
use rule moduleNeverAccumulatesPositions filtered { f -> !EXCLUDED(f) }

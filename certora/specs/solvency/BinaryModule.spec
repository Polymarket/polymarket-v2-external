// Used by certora/confs/solvency/BinaryModule.conf — every method except the two
// migratePositions. Those run as dedicated
// case-split rules (their one-VC parametric form times out at two array elements):
//   * certora/confs/solvency/BinaryModuleMigrate.conf ->
//     solvency/BinaryModuleMigrate.spec — migratePositions(bytes32[],uint256[],uint256[]);
//   * certora/confs/solvency/BinaryModuleMigrateFrom.conf ->
//     solvency/BinaryModuleMigrateFrom.spec — migratePositions(address,bytes32[],uint256[],uint256[]).

/*
 * MODULE
 * @module BinaryModule Global Solvency
 * @contract BinaryModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 *
 * PROPERTIES
 * @property BINARY-GLOB-SOLVENCY BinaryModule preserves the collateral backing of every outstanding position it has minted, under every possible market resolution.
 */

import "BinarySolvencyBase.spec";

/**
 * @title solvency preserved
 * @description BinaryModule preserves the backing inequality between counted assets and the sum of pUSD supply and worst-case liability.
 * @link_property BINARY-GLOB-SOLVENCY
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7006d400229a4fd696d029db94436f74?anonymousKey=0ad68e969033aa3de505c81565bbad9f7c5f27e4
 */
use rule solvencyPreserved;

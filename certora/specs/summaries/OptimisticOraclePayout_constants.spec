// ============================================================
// OptimisticOraclePayout_constants.spec — shared constants for the oracle family
//
// Definitions only: no methods block, no ghosts, no `using`, so this file can be imported by
// both the single-contract pure scene and the multi-contract concrete scene.
//
// Mirrors src/oracle/libraries/OptimisticOraclePayoutLib.sol and
// OracleAggregator.MarketType. Kept as CVL literals (not read from the contracts) so a
// constant changed in the source is a rule failure, not a silently-tracked value.
// ============================================================

definition YES_PRICE() returns mathint = 1000000000000000000;    // 1e18
definition NO_PRICE() returns mathint = 0;
definition P3_PRICE() returns mathint = 500000000000000000;      // 0.5e18
// type(int256).min — UMA's "too early / unresolvable" price.
definition P4_PRICE() returns mathint =
    -57896044618658097711785492504343953926634992332820282019728792003956564819968;
definition RESULT_DENOMINATOR() returns mathint = 1000000;

// OracleAggregator.MarketType
definition BINARY() returns uint8 = 0;
definition INCREMENTAL_NEGRISK() returns uint8 = 1;
definition ATOMIC_NEGRISK() returns uint8 = 2;

// Arity bit field of a raw request id, restated with integer division so the rules stay out of
// bitvector theory (house style, cf. accesscontrol/PositionManager.spec). ARITY_SHIFT = 104,
// ARITY_MASK = 0xFFFF (src/libraries/Ids.sol). Cross-checked against the production library by
// `arityExtractionMatchesLibrary` in OOReporterPure.spec.
definition arityOfBits(uint256 raw) returns mathint = (raw / 2^104) % 2^16;

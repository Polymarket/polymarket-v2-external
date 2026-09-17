// ============================================================
// CTFHelpers_summaries.spec — summaries for the legacy CTFHelpers library
//
// CTFHelpers.partition() builds the binary partition array [1, 2] in raw
// assembly (manual free-memory-pointer bump). That breaks the prover's
// pointer analysis (error code 1277565207) at every call site that forwards
// the array to the legacy ConditionalTokens contract — namely
// _redeemLegacyPositions (Binary/NegRisk migration mixins) and
// BaseMigrationMixin._mergeComplementaryLegacyPositions — leaving those
// external calls unresolved (havoc'd) even when ConditionalTokens is linked
// in the scene. Summarizing partition() with an equivalent CVL array
// restores precise call resolution.
//
// CTFHelpers.positionIds() needs no summary: it allocates via `new
// uint256[](2)` (no assembly); its CTHelpers.getCollectionId calls are
// NONDET-summarized below.
//
// This file is also the single owner of the legacy CTHelpers math summaries
// (sqrt, getCollectionId) — declared once here because CVL rejects duplicate
// summaries across an import closure.
// ============================================================

methods {
    function _.partition() internal => partitionCVL() expect (uint256[] memory);

    function _.sqrt(uint256) internal => NONDET;
    function _.getCollectionId(bytes32, bytes32, uint256) internal => NONDET;
}

// partition() always returns the fixed binary partition [0b01, 0b10].
// `result` is a fresh nondeterministic array pinned to [1, 2] via requires.
function partitionCVL() returns uint256[] {
    uint256[] result;
    require result.length == 2, "partition() always returns a 2-element array";
    require result[0] == 1, "partition()[0] is the YES index set 0b01";
    require result[1] == 2, "partition()[1] is the NO index set 0b10";
    return result;
}

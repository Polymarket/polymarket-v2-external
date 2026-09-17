// ============================================================
// OOReporterModule_base_summaries.spec — shared wiring for the concrete oracle scene
//
// Design rule for this family: START CONCRETE. Nothing here replaces production behaviour —
// there is no ghost model, no NONDET of a business function, and in particular
//   * OracleAggregator.reportResult / finalize run their REAL bodies (including
//     `_validateResult` and the real `keccak256(abi.encode(result))` bookkeeping), and
//   * Solady's EnumerableSetLib reporter set is read as REAL storage (no ghost set).
// The only entries below are CALL RESOLUTION: the module reaches the aggregator through the
// `aggregator` STORAGE variable, and the aggregator reaches its resolution target through the
// `targetContract` config field, so both call sites are address-symbolic and therefore
// unresolved at build time. `DISPATCHER(true)` routes them to the single scene contract that
// implements each sighash instead of letting the Prover havoc.
//
// `ooReporter` is an immutable, so UMA's production reporter is wired with `links` and needs
// no summary at all.
//
// Refinement discipline: every summary added to this file later must be justified by an
// observed counterexample or Prover alert, and must say which one.
// ============================================================

links {
    OOReporterModule.ooReporter => OOReporter;
}

methods {
    // ---- OOReporterModule: production views ----
    function OOReporterModule.aggregator() external returns (address) envfree;

    // ---- OOReporterModule: harness projections (view-only additions) ----
    function OOReporterModule.requestInitializedAt(bytes32) external returns (bool) envfree;
    function OOReporterModule.arityOfRequestId(bytes32) external returns (uint256) envfree;
    function OOReporterModule.isCanonicalRequestId(bytes32) external returns (bool) envfree;
    function OOReporterModule.asUint(bytes32) external returns (uint256) envfree;
    function OOReporterModule.resultHashFor(uint256) external returns (bytes32) envfree;
    function OOReporterModule.voteKeyFor(bytes32, bytes32) external returns (bytes32) envfree;
    function OOReporterModule.conditionIdOfEventIndex(bytes32, uint256) external returns (bytes32) envfree;
    function OOReporterModule.isValidBinaryPriceExt(int256, uint8) external returns (bool) envfree;

    // ---- OracleAggregator: production views over raw bytes32 request ids ----
    function OracleAggregator.getRequestShape(bytes32) external returns (uint8, uint16) envfree;
    function OracleAggregator.voteCount(bytes32) external returns (uint256) envfree;
    function OracleAggregator.hasReporterVoted(bytes32, address) external returns (bool) envfree;
    function OracleAggregator.conflictingResultHash(bytes32) external returns (bytes32) envfree;
    function OracleAggregator.globalPaused() external returns (bool) envfree;

    // ---- UMA OOReporter (production, linked): settled-price reads ----
    function OOReporter.isRequestResolved(bytes32) external returns (bool) envfree;
    function OOReporter.getRequestResolution(bytes32) external returns (int256) envfree;

    // ---- Resolution target recorder ----
    function BinaryReporterTargetMock.reportCount() external returns (uint256) envfree;
    function BinaryReporterTargetMock.lastConditionId() external returns (bytes32) envfree;
    function BinaryReporterTargetMock.lastResultLen() external returns (uint256) envfree;
    function BinaryReporterTargetMock.lastResult0() external returns (uint256) envfree;
    function BinaryReporterTargetMock.lastResult1() external returns (uint256) envfree;

    // ---- Call resolution (the ONLY summaries in this scene) ----
    // OOReporterModule -> aggregator, through the `aggregator` storage variable.
    function _.getRequestShape(bytes32) external => DISPATCHER(true);
    function _.reportResult(bytes32, uint256[]) external => DISPATCHER(true);
    function _.finalize(bytes32, uint256[]) external => DISPATCHER(true);
    // OracleAggregator._finalizeConditions -> request target, through `cfg.targetContract`.
    function _.reportResult(OOReporterModule.ConditionId, uint256[]) external => DISPATCHER(true);
}

// ------------------------------------------------------------
// Scene wiring
// ------------------------------------------------------------

// The module's aggregator pointer is plain storage (not an immutable), so it cannot be
// `links`-ed. DISPATCHER already routes the call to the scene's aggregator; this pins the
// numeric address too, so rules that read OracleAggregator storage observe the same instance
// the module reported to.
function requireSceneWiring() {
    require OOReporterModule.aggregator() == OracleAggregator,
        "scene wiring: the module's aggregator is the scene's OracleAggregator";
}

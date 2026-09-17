// Scene file for the OOReporterModule oracle scene (certora/confs/oracle/*.conf).
// Owns the `using` alias declarations for every contract in the scene's `files` list.
// Convention: aliases are declared EXACTLY ONCE per scene, here; the shared summary file
// (OOReporterModule_base_summaries.spec) and the specs only reference them.
//
// The scene is deliberately CONCRETE: the production OracleAggregator and UMA's production
// OOReporter are in the scene as real code, not as mocks or CVL models. Only two boundary
// contracts are stand-ins, and each because the real thing adds nothing to the claim:
//   * BinaryReporterTargetMock  — the request's `targetContract` (a real module would pull in
//     PositionManager / CollateralToken / ConditionalTokens);
//   * IntegrationOptimisticOracleV2 (registration scene only) — UMA's Managed OO, reached only
//     by `OOReporter.registerRequest` for its `minimumDisputeWindow()` sanity read.
using OOReporterModule as OOReporterModule;
using OracleAggregator as OracleAggregator;
using OOReporter as OOReporter;
using BinaryReporterTargetMock as BinaryReporterTargetMock;

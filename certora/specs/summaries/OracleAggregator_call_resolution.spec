// Scene file for the OracleAggregator scene (certora/confs/oracle/Aggregator*.conf).
// Owns the `using` alias declarations for every contract in the scene's `files` list.
// Convention (same as OOReporterModule_call_resolution.spec): aliases are declared exactly once
// per scene, here; the shared summary file (OracleAggregator_base_summaries.spec) and the specs
// only reference them.
using OracleAggregator as OracleAggregator;
using EOAReporterModule as EOAReporterModule;
using MockDisputerModule as MockDisputerModule;
using MockArbitratorModule as MockArbitratorModule;
using RevertingArbitratorMock as RevertingArbitratorMock;
using BinaryReporterTargetMock as BinaryReporterTargetMock;
using PositionManager as PositionManager;

links {
    OracleAggregator.POSITION_MANAGER => PositionManager;
}

// ============================================================
// OOReporterModule_registration_scene.spec — scene extension for the registration paths
//
// `_registerRequest` calls UMA's production `OOReporter.registerRequest`, which reads
// `optimisticOracle().minimumDisputeWindow()` as a registration-time sanity check. The Managed
// OO address lives in the reporter's ERC-7201 storage, so that call site is address-symbolic
// and unresolved; `DISPATCHER(true)` routes it to the repo's existing Managed-OO stand-in
// (`src/oracle/test/integration/mocks/IntegrationOptimisticOracleV2.sol`, the same mock the
// Foundry integration tests drive the real OOReporter with).
//
// Imported by the specs whose method surface can reach a registration: OOReporterRegistration
// (directly) and OOReporterAccess (parametrically, through createRequest /
// initializeReporterModule). The relay and rules scenes never register, so they do not need it.
// ============================================================

using IntegrationOptimisticOracleV2 as ManagedOracle;

methods {
    function _.minimumDisputeWindow() external => DISPATCHER(true);
}

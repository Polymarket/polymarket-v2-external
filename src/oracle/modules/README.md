# OOReporterModule

Reporter module that registers Polymarket v2 request IDs with UMA's managed OOReporter and relays settled UMA results into the normal `OracleAggregator` report/threshold/liveness flow. It is not an arbitrator or disputer and never calls `resolveResult`.

UMA owns request initialization and settlement. Polymarket independently applies reporter thresholds, its own liveness window, optional disputes, and normal finalization before writing the result to the target module.

## Aggregator Configuration

`OOReporterModule` belongs in `reporterModules`:

```text
reporterModules:  [{ module: address(OOReporterModule), initData: registrationDataOrEmpty }]
disputerModules:  [] or independently configured disputer modules
arbitratorModule: address(0) or an independent arbitrator
finalizer:        address(OOReporterModule) or address(0)
```

Use a separate arbitrator whenever disputes or threshold-supported reporter conflicts can occur. Setting `finalizer` to the module routes finalization through its UMA-derived result; setting it to zero also permits callers to finalize directly on the aggregator with the already-proposed result.

The module inherits UUPS upgradeability from `OracleModuleBase`. Upgrades are owner-authorized, while module operators control request registration and rule updates.

## Request Registration

Registration stores the Polymarket request identity and rules in UMA's OOReporter. It does not initialize the actual UMA oracle request.

Two equivalent registration paths are supported:

1. **Aggregator init data:** Encode `OOReporterModule.RequestRegistration[]` into the reporter module's `initData`. This supports one binary/atomic request or multiple condition-level incremental NegRisk requests.
2. **Later operator call:** Leave `initData` empty and call `createRequest(requestId, requestRules, minimumLiveness, maximumLiveness)` after aggregator initialization.

Both paths share the same canonical-ID, event-membership, liveness-range, and duplicate guards. The module derives the UMA identifier from the aggregator market type:

- Binary and Incremental NegRisk -> `YES_OR_NO_QUERY`
- Atomic NegRisk -> `NUMERICAL`

The module must be an enabled managed-OO **requester**. It is intentionally not an `oracleInitializer`. A separately authorized UMA actor calls `OOReporter.initializeRequest(requestId, reward, proposalBond, liveness)` to start the managed UMA request.

There are two independent requester boundaries: OOReporter allowlists OOReporterModule to register Polymarket request IDs, while Managed Optimistic Oracle V2 allowlists OOReporter itself to create UMA price requests. MOOV2 callbacks target OOReporter because OOReporter is the MOOV2 requester; they never target OOReporterModule.

## Settlement Flow

1. The aggregator initializes the Polymarket request with OOReporterModule as a reporter.
2. The aggregator init payload or a module operator registers the request with UMA's OOReporter.
3. An authorized UMA oracle initializer starts the managed UMA request.
4. UMA settles the request independently.
5. Anyone calls `OOReporterModule.report(requestId)`. The module translates the settled UMA price and calls `OracleAggregator.reportResult` as one reporter vote.
6. Matching votes reaching `reporterThreshold` create a Polymarket proposal and start Polymarket liveness.
7. Once liveness expires without escalation, anyone may call `OOReporterModule.finalize(requestId)`. The aggregator validates the finalizer, proposal hash, and deadline before resolving the target. With zero aggregator liveness, `report` and `finalize` may execute in the same block.

If a Polymarket dispute or reporter conflict triggers arbitration, module finalization is blocked. Only the separately configured arbitrator or an aggregator admin can use the exceptional `resolveResult` path.

## Price Translation

- Binary `YES_OR_NO_QUERY`: UMA `0` maps to `[0]`, `0.5 ether` maps to `[500_000]`, and `1 ether` maps to `[1_000_000]`.
- Incremental NegRisk `YES_OR_NO_QUERY`: only UMA `0` and `1 ether` are valid because NegRisk results must be fully resolved; P3 is rejected before reporting.
- Atomic NegRisk `NUMERICAL`: the raw result must be a non-negative integer multiple of `1e18`, and `rawResult / 1e18` must be less than `eventId.arity()`. The translated result is `[winnerIndex]` for a real condition.

## Trust and Operational Boundaries

- Polymarket controls OracleAggregator and OOReporterModule. UMA ownership, initialization, and resolver roles do not grant any Polymarket aggregator role.
- UMA-controlled OOReporter owns UMA request state, rule persistence, dispute re-requests, and the final raw UMA price.
- UMA's OOReporter owner/initializers and MOOV2 requester-whitelist, request-manager, resolver, and upgrade authorities can affect whether and how UMA produces a settled raw price, but none gain Polymarket aggregator authority.
- OOReporterModule stores no duplicate UMA resolution state and cannot initialize UMA requests.
- A settled UMA outcome contributes one normal reporter vote. Polymarket independently controls reporter thresholds, reporter replacement, disputes, arbitration, liveness, finalization, and admin recovery.
- Permissionless `report` and `finalize` calls are safe relays because the module reads a settled UMA result and the aggregator independently enforces registration, one vote per module, thresholds, liveness, finalizer authorization, and the proposal hash.
- Unsupported UMA values cannot create a Polymarket vote. Aggregator admin recovery remains independent of the module.

## Deployment Preflight

Before enabling the integration, verify the live contracts and role holders:

- OOReporter is controlled by the intended UMA governance account or multisig.
- `OOReporter.isRequester(address(OOReporterModule))` is true.
- `OOReporter.isOracleInitializer(address(OOReporterModule))` is false, and the intended UMA initializer is enabled.
- OOReporter, not OOReporterModule, is enabled by MOOV2's requester whitelist.
- The intended MOOV2 resolver is enabled, and the identifier, reward currency, bond, and selected UMA liveness are accepted by the live MOOV2 configuration.
- OOReporterModule is registered only as an OracleAggregator reporter/finalizer; any Polymarket disputer and arbitrator are configured independently.
- The module points to the intended OOReporter proxy. Upgrading that proxy preserves compatibility; replacing its address requires a module upgrade.

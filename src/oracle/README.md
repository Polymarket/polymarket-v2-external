# Oracle System

A modular oracle for resolving prediction market outcomes. The system separates **who reports**, **who disputes**, and **who arbitrates** into pluggable modules behind a single aggregator contract.

See [GLOSSARY.md](./GLOSSARY.md) for canonical terminology.

## Architecture

```
                    ┌─────────────────────┐
                    │  OracleAggregator   │
                    │  (singleton, UUPS)  │
                    └────┬───────┬───────┬┘
                         │       │       │
              ┌──────────┘       │       └──────────┐
              ▼                  ▼                   ▼
     ReporterModules      DisputerModules     ArbitratorModule
     ─────────────        ──────────────      ────────────────
     EOAReporterModule                        Independent module
     ChainlinkReporterModule
     OOReporterModule
                                  │
                                  ▼
                          Target Contract
                     (BinaryModule / NegRiskModule)
```

The **OracleAggregator** is a singleton upgradeable (UUPS) contract. Each request is configured with:
- One or more **reporter modules** that submit results
- One or more **disputer modules** that challenge proposals
- One **arbitrator module** for final resolution after disputes escalate

The aggregator holds an immutable reference to `PositionManager`. During request initialization it
requires the event's encoded module ID, market type, and target address to agree with the canonical
`PositionManager.moduleById` registry entry. Binary requests route to module ID `1`; incremental and
atomic NegRisk requests route to module ID `2`.

All modules inherit from **OracleModuleBase**, which provides the aggregator reference, initialization guards, and conditionId resolution. Submodule per-event init entry points (`initialize*Module`) take a typed `EventId` argument; per-request entry points (`report`, `dispute`) take an opaque `bytes32 requestId`.

Target modules gate `reportResult` behind their **resolver role**: the aggregator must be granted the role on each target module (`addResolver`), and resolver-role callers can only resolve conditions whose encoded resolution chain matches the module's configured `RESOLUTION_CHAIN`. Replays revert for resolver callers (`ConditionAlreadyResolved`). See `docs/modules.md` (Result Reporting & Replays).

## Resolution Lifecycle

### Happy Path

```
1. initializeRequest()   Operator registers request + modules
2. reportResult()        Reporter modules vote on results
3. [threshold met]       Proposal created, liveness window starts
4. reportResult()        Remaining modules may continue reporting during liveness
5. [window expires]      No dispute or threshold-supported conflict occurred
6. finalize()            Finalizer (or anyone, if unset) calls with matching result → target
```

`finalize()` is gated by the per-event pause and by the request's optional `finalizer` address: when a
non-zero `finalizer` is configured only that address may finalize; a zero finalizer keeps it
permissionless. A paused market blocks `finalize()` for everyone (the arbitrator/admin `resolveResult()`
path still works).

A global oracle pause blocks reporting, disputing, and finalizing. The liveness window runs in
wall-clock time and is not extended by a pause: a window that elapses while paused simply lets the
proposal be finalized once the oracle is unpaused.

A zero liveness window closes at the proposal timestamp. The proposal can therefore be finalized
later in the same block, while disputes and additional reports are immediately closed.

### Dispute Path

```
1-3. (same as above)
4. disputeResult()       Disputer modules challenge during liveness window
5. [threshold met]       ArbitrationRequested status, arbitrator notified
6. resolveResult()       Arbitrator (or admin) submits final result → target receives outcome
```

Each registered disputer module can contribute at most one dispute vote per request ID. The same
module can dispute separate request IDs, including different conditions within one NegRisk event.

### Reporter Conflict Path

After the first result reaches `reporterThreshold`, reports remain open during liveness. If a
different result also reaches `reporterThreshold`, the aggregator preserves the first proposal,
records and emits the conflicting result, and immediately enters `ArbitrationRequested`. This is a
first-class arbitration trigger and does not increment `disputeCount`.

### Admin Override

An admin can call `resolveResult()` at any time (except after resolution) to force-finalize a condition, regardless of the current lifecycle stage. This path bypasses both the per-event pause and the `finalizer` gate.

### Market Management

An operator (`OPERATOR_ROLE`), or an admin, can adjust a request after initialization and pause markets (the operator role covers both request initialization and these former market-manager duties):

- **Config edits:** add/remove reporter and disputer modules, swap the arbitrator (`setArbitratorModule`), set the `finalize` gate (`setFinalizer`), and change the liveness window up to the 7-day protocol maximum (`setLivenessWindow`). It cannot change the target contract, market type, result length, thresholds, or resolution state. Each edit takes a `requestId` and rejects that request after resolution. For incremental NegRisk, an unresolved child can update the config shared by its siblings even after another child resolves.
- **Per-event pause:** `pauseMarkets`/`unpauseMarkets` toggle a per-event flag (independent of the global pause) that blocks only `finalize()`. The arbitrator/admin `resolveResult()` path, reporting, and disputing all continue while paused.

## Request Types

### Binary
Single condition, single result element. `resultLength = 1`, and the total condition count is derived as `1` from the event ID. The conditionId equals the eventId. Result `[1_000_000]` = YES, `[0]` = NO.

### Incremental NegRisk
Multiple independent subconditions under one request. Each subcondition is reported separately with `resultLength = 1`. Example: 3-outcome market where each outcome is resolved independently.

### Atomic NegRisk
All real subconditions resolve through one event-level request. `resultLength = 1`; the single value is the winning real condition index. Example: a 5-outcome market resolved with `[2]` means outcome 2 wins. The aggregator reports that winning condition as YES to the target, and `NegRiskModule.getResult` derives the remaining real conditions as NO.

## Module Types

### EOAReporterModule
Authorized EOA addresses submit results through a shared module instance. The aggregator counts one vote per registered module per request, so the first authorized reporter to report casts the module's single vote — additional authorized reporters are redundant senders, not extra votes. Meeting a `reporterThreshold` greater than 1 requires registering multiple reporter modules.

### ChainlinkReporterModule
Reads candle start/end prices from a DataStore contract. Reports YES (`RESULT_DENOMINATOR`) if `endPrice >= startPrice`, else NO (`0`). Configured per event with asset pair, duration, and start timestamp.

### OOReporterModule
Registers request metadata with UMA's managed OOReporter and submits settled UMA results through `reportResult()` as a normal reporter vote. It can relay `finalize()` once the Polymarket liveness window ends but has no arbitration or admin resolution authority. UMA request initialization remains controlled by UMA's independent `oracleInitializer` role. See `src/oracle/modules/README.md` for registration modes, price translation, and trust boundaries.

## File Structure

```
src/oracle/
├── OracleAggregator.sol          Core aggregator contract
├── GLOSSARY.md                   Terminology reference
├── README.md                     This file
├── abstract/
│   ├── OracleAggregatorErrors.sol
│   ├── OracleAggregatorEvents.sol
│   └── OracleModuleBase.sol      Shared base for all modules
├── interfaces/
│   ├── IOracleAggregator.sol
│   ├── IReporterModule.sol
│   ├── IDisputerModule.sol
│   ├── IArbitratorModule.sol
│   ├── IBinaryReporter.sol       Target contract interface
├── libraries/
│   └── OptimisticOraclePayoutLib.sol  Price/identifier constants
├── mixins/
│   ├── Auth.sol                  Role-based access control
│   ├── Pausable.sol             Emergency pause
│   └── MarketDataRegistry.sol   Product specs + per-request rules (namespaced storage)
├── modules/
│   ├── OOReporterModule.sol       UMA OOReporter result relay module
│   ├── README.md                  OOReporterModule documentation
│   └── reporters/
│       ├── EOAReporterModule.sol
│       └── ChainlinkReporterModule.sol
└── test/                         Forge tests
```

## Market Data Registry

The aggregator inherits the `MarketDataRegistry` mixin — an onchain store for market reference data, written by the rule manager (`RULE_MANAGER_ROLE`) or an admin. Storage lives in an ERC-7201 namespaced slot, so it does not affect the aggregator's storage layout.

- **Product specs.** `setProductSpecification(name, uri)` maps a product name (shared by many markets) to a spec-document URI. Names are case-insensitive (ASCII `A-Z` → `a-z`); the first write's casing is preserved for display. Each write bumps a per-product `version` and emits `ProductSpecificationUpdated`. Read via `getProductSpecification(name)` / `getProductSpecificationById(productId)`; `productId(name)` derives the key.
- **Rules.** Per-request rule updates are written exclusively through the aggregator's `updateRequestRules(requestId, updatedRules)` entry point (operator-gated). It appends to a per-request, append-only history via the mixin's internal `_pushRule` helper and then broadcasts the update by calling `IReporterModule.updateRules` on every registered reporter for the event — so reporters that mirror rules to external systems (e.g. UMA's OOReporter) stay in sync. The aggregator is the canonical source for the rule history (mirroring UMA OOReporter's `requestRulesUpdates`). The OOReporter module ignores `RequestAlreadyResolved` and `RequestNotRegistered` when forwarding because neither UMA request can accept new metadata; any other forwarding failure reverts the transaction and rolls back the aggregator-side write. Read via `getRules` / `getLatestRule` / `getRuleAt` / `getRuleCount`. Gated by request state: rejected for unknown (`RequestNotFound`) or already-resolved (`RequestAlreadyResolved`) requests.

## Key Design Decisions

**Result hashing instead of storage.** The aggregator stores only `keccak256(abi.encode(result))` rather than the full result array. Callers re-provide the result at finalization time, verified against the stored hash. This keeps storage to one slot per condition regardless of outcome count.

**Vote-based reporting.** Results aren't accepted from a single reporter. Multiple reporter modules vote, and the first result to receive `reporterThreshold` matching votes becomes the proposal. Reporting remains open during liveness; a different result reaching the same threshold automatically triggers arbitration.

> **Threshold invariant.** Votes are tallied **per reporter module** — each registered module casts at most one vote (deduped by `hasReporterVoted`), regardless of how many underlying addresses it authorizes. A result therefore only reaches `reporterThreshold` when that many *distinct* reporter modules agree. `initializeRequest` enforces this is achievable: it requires both reporter and disputer modules with each threshold at least one, and the count of *distinct* registered modules at least the corresponding threshold (the module sets dedupe, so duplicate-padded arrays are rejected). `removeReporterModules` / `removeDisputerModules` likewise refuse to drop a set below its threshold, so a request can never become under-provisioned.

**Modular design.** Reporter, disputer, and arbitrator logic is externalized into separate
contracts. New reporter, disputer, and arbitrator module types can be added without modifying the
aggregator's lifecycle state machine.

**Canonical target routing.** Request targets are validated against the PositionManager registry
rather than trusted to self-identify. The caller still supplies `targetContract` for ABI stability,
but initialization rejects any value that is not the registered owner of the request's module ID.

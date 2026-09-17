# Oracle System Glossary

Canonical terminology for the oracle module system. All contracts, events, errors, and documentation should use these terms consistently.

## Core Concepts

**Request**
A resolution request registered with the OracleAggregator via `initializeRequest`. Identified by an `EventId` (UDVT with `bytes29` underlying) from the shared ID scheme in `src/libraries/Ids.sol`. A request bundles shared configuration — modules, thresholds, liveness window, and target contract — for one or more conditions that need resolution. The oracle does not define what an "event" is; it uses the shared `EventId` as a configuration key.

**Condition**
The minimal unit of resolution. For binary and incremental NegRisk markets, a condition is a single yes/no question. For atomic NegRisk, the full request is the resolution unit. Identified by a `ConditionId` (UDVT with `bytes31` underlying), derived from the eventId via `EventIdLib.computeConditionId`.

**Subcondition**
An individual outcome slot within a request. A request whose event ID encodes count `3` has three subconditions (indices 0, 1, 2). Each subcondition maps to a conditionId.

**Result**
The outcome array for a condition report. Always a single-element `uint256` array (`resultLength == 1` for every market type), but the element's meaning depends on the market type. Binary values are payouts and may be fractional (up to `RESULT_DENOMINATOR`). Incremental NegRisk values are payouts that must be exactly `0` or `RESULT_DENOMINATOR`, so fractional outcomes such as a 50/50 split are rejected. Atomic NegRisk values are winning real condition indexes and must be less than `eventId.arity()`.

- Binary: `[1_000_000]` (YES) or `[0]` (NO), or a fractional split such as `[500_000]`
- Atomic NegRisk: `[2]` (outcome 2 wins; the losing real conditions derive NO in the target module)
- Incremental NegRisk: `[1_000_000]` or `[0]` per subcondition

**RESULT_DENOMINATOR**
Precision constant (`1_000_000`). Represents 100%. All result values are denominated in parts per million.

## Resolution Lifecycle

**Report** (`reportResult`)
A reporter module submits a result to the aggregator. Each submission is a vote. Multiple reporters can vote for different results.

**Threshold** (`reporterThreshold`)
The number of matching votes required for a result to become the proposed outcome.

**Proposal** (`OutcomeProposed`)
When votes for a result reach the threshold, it becomes the proposed outcome and starts the liveness window.

**Reporter Conflict** (`ReporterConflict`)
After a proposal exists, a different result that also reaches the reporter threshold. The first proposal remains stored, the conflicting result hash is recorded, and the request immediately enters arbitration without incrementing the disputer vote count.

**Liveness Window** (`livenessWindow`)
A time period (in seconds, capped at 7 days) after a proposal during which remaining reporters may report and disputers may challenge the result. The window runs in wall-clock time and is not extended by a global oracle pause. If no dispute or reporter conflict triggers arbitration, the proposal can be finalized at or after the deadline. A zero window closes at the proposal timestamp, enabling same-block finalization while leaving no opportunity for disputes or additional reports.

**Dispute** (`disputeResult`)
A disputer module challenges the proposed result during the liveness window. Each registered module can contribute at most one dispute vote per request ID; accepted votes increment the dispute counter.

**Dispute Threshold** (`disputerThreshold`)
The number of disputes required to escalate to arbitration.

**Arbitration** (`ArbitrationTriggered`)
When disputes reach their threshold or a second reporter result reaches the reporter threshold, the condition enters `ArbitrationRequested` status and the arbitrator module is notified.

**Resolve** (`resolveResult`)
The arbitrator module (or an admin) submits a final result that immediately finalizes the condition, bypassing the normal vote/liveness flow.

**Finalize** (`finalize`)
Callable once the liveness window expires without sufficient disputes. Re-provides the result (verified against stored hash) and triggers reporting to the target contract. If the request configures a non-zero **Finalizer**, only that address may call it; otherwise it is permissionless. A zero liveness window permits finalization in the proposal's block. Blocked while the market is paused (see **Market Pause**).

**Finalizer** (`finalizer`)
An optional per-request address allowed to call `finalize`. Zero means permissionless finalization. Settable at `initializeRequest` and changeable by the **Operator** via `setFinalizer`.

**Operator** (`OPERATOR_ROLE`)
A global role (`_ROLE_1`) that registers requests (`initializeRequest`), mutates a request's modules, arbitrator, finalizer, and liveness window after initialization, pauses/unpauses markets in batches, and publishes per-request rule updates via `updateRequestRules`. Admins can perform the same actions. A request's target contract, market type, result length, and thresholds have no setters and are immutable after initialization. The operator is a **fully trusted role** (all operators are run by Polymarket): it chooses which arbitrator `resolveResult` accepts calls from and which reporter modules may vote, so resolution authority follows the operator's configuration and there is no structural separation between the operator and resolution state.

**Rule Manager** (`RULE_MANAGER_ROLE`)
A global role (`_ROLE_2`) that publishes product specifications via the **Market Data Registry** (`setProductSpecification`). Admins can perform the same actions. Per-request rules are written by the **Operator** through `updateRequestRules`, not through this role.

**Market Data Registry** (`MarketDataRegistry`)
A mixin on the aggregator holding **product specifications** (a product name → spec-document URI, versioned and case-insensitive) and **rules** (an append-only per-request rule-update history, mirroring UMA OOReporter's `requestRulesUpdates`). Product specs are written by the **Rule Manager** via `setProductSpecification`. Rules are written exclusively through the host's `updateRequestRules` (Operator-gated), which appends via the mixin's internal `_pushRule` helper and broadcasts the update to all registered reporter modules; the mixin does not expose a standalone rule-write function. Rules are rejected for unknown or already-resolved requests.

**Market Pause** (`marketPaused`, `pauseMarkets`/`unpauseMarkets`)
A per-event pause flag, independent of the global oracle pause. Pausing a market only blocks `finalize`; reporting, disputing, and the arbitrator/admin `resolveResult` path are unaffected, so a paused market can still be resolved by the arbitrator or an admin.

**Global Pause** (`globalPaused`, `pauseOracle`/`unpauseOracle`)
An oracle-wide emergency pause that blocks reporting, disputing, finalizing, and resolving. Liveness windows run in wall-clock time and are not extended by a pause; a window that elapses while paused simply lets the proposal be finalized once unpaused.

## Modules

**ReporterModule**
Submits results to the aggregator via `reportResult`. Examples include `EOAReporterModule` (authorized wallets) and `OOReporterModule` (settled UMA results).

**DisputerModule**
Challenges proposed results via `disputeResult`.

**ArbitratorModule**
Provides final resolution after disputes or reporter conflicts escalate. Arbitrators finalize through `resolveResult`; OOReporterModule is not an arbitrator and participates only through the reporter/finalizer flow.

**OracleModuleBase**
Shared base contract for all module types. Provides aggregator reference, `initOnce` guard (keyed by a conditionId or eventId depending on the market type — conditionId for binary and incremental NegRisk, eventId for atomic NegRisk), and conditionId-to-eventId resolution.

**RequestInitialized** (event name used by OracleModuleBase and OracleAggregator)
The two contracts use distinct event signatures. The aggregator event records a request's complete
genesis configuration: target, thresholds, result length, market type, arbitrator, liveness window,
and finalizer. The module event records that a module initialized a request scope.

## Contracts

**OracleAggregator**
Singleton upgradeable contract that orchestrates the resolution lifecycle. Stores request configs, tracks votes, manages proposal/dispute state, and reports one final binary result per request to the target contract (for atomic NegRisk, only the winning condition is reported; the target derives the losers as NO).

**Target Contracts (BinaryModule / NegRiskModule)**
Contracts that receive final results from the aggregator via `IBinaryReporter.reportResult(conditionId, result)`.

## ID Scheme

All IDs are typed UDVTs defined in `src/libraries/Ids.sol`:

- `EventId` (`bytes29` underlying): Base identifier from the shared ID scheme in `src/libraries/Ids.sol`. By construction the conditionIndex and outcomeIndex bytes are zero.
- `ConditionId` (`bytes31` underlying): Derived from eventId + conditionIndex. For binary markets, the ConditionId is bit-equivalent to the EventId.
- `ConditionIdLib.eventId(ConditionId) → EventId`: Extracts the parent eventId from a conditionId.
- `EventIdLib.computeConditionId(EventId, uint256) → ConditionId`: Derives a conditionId for a specific subcondition index.

The oracle uses `EventId` as a key for `RequestConfig` (shared configuration). Per-condition lifecycle state (`resolutionStates`, `hasReporterVoted`, `hasDisputerVoted`) is keyed by a `bytes32 requestId` — the conditionId for binary and incremental NegRisk, the eventId reinterpreted as a condition for atomic NegRisk.

## Resolution Statuses

| Status | Meaning |
|---|---|
| `None` | Condition doesn't exist (but may be implicitly Active if request config exists) |
| `Active` | Accepting reports and disputes |
| `ArbitrationRequested` | Dispute threshold reached, awaiting arbitrator resolution |
| `Resolved` | Final result reported to target contract |

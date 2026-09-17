# Oracle

Source: `src/oracle/OracleAggregator.sol`

See also: [`src/oracle/README.md`](../src/oracle/README.md) for the full architecture guide and [`src/oracle/GLOSSARY.md`](../src/oracle/GLOSSARY.md) for canonical terminology.

The OracleAggregator is a singleton UUPS-upgradeable contract that orchestrates prediction market resolution. It separates **who reports**, **who disputes**, and **who arbitrates** into pluggable modules behind a single state machine.

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
     ChainlinkReporter                │
     OOReporterModule                 │
                                     ▼
                             Target Contract
                        (BinaryModule / NegRiskModule)
```

The aggregator manages the lifecycle. Modules handle domain-specific logic. Target contracts receive final results via `IBinaryReporter.reportResult()`. The aggregator has an immutable `POSITION_MANAGER` reference and uses its module registry as the canonical source for request targets.

Target modules gate `reportResult` behind their **resolver role**: the aggregator must be granted the role on each target module (`addResolver`), and resolver-role callers can only resolve conditions whose encoded resolution chain matches the module's configured `RESOLUTION_CHAIN`. Replays revert for resolver callers (`ConditionAlreadyResolved`). See [Modules — Result Reporting & Replays](modules.md#result-reporting--replays).

## Resolution Lifecycle

### Statuses

| Status | Meaning |
|--------|---------|
| `None` | No resolution state exists (implicitly Active if request config exists) |
| `Active` | Accepting reports and disputes |
| `ArbitrationRequested` | Dispute threshold reached, awaiting arbitrator |
| `Resolved` | Final result reported to target contract |

### Happy Path

```
1. initializeRequest()   Operator registers request + modules
2. reportResult()        Reporter modules vote on results
3. [threshold met]       Proposal created, liveness window starts
4. [window expires]      No disputes reached threshold
5. finalize()            Finalizer (or anyone, if unset) calls with matching result → target
```

`finalize` is gated two ways: it reverts if the market is paused (see [Market Management](#market-management)),
and if the request has a non-zero `finalizer` configured, only that address may call it. A zero finalizer
keeps finalization permissionless.

### Dispute Path

```
1-3. (same as above)
4. disputeResult()       Disputer modules challenge during liveness window
5. [threshold met]       ArbitrationRequested, arbitrator notified
6. resolveResult()       Arbitrator (or admin) submits final result → target receives outcome
```

### Admin Override

An admin can call `resolveResult()` at any non-Resolved stage to force-finalize a condition. This
path is unaffected by the per-event pause and the `finalizer` gate, so admins (and the arbitrator)
can always resolve a paused or finalizer-gated market.

## Request Types

### Binary

Single condition, single result element. `resultLength = 1`, and the total condition count is derived as `1` from the event ID. The conditionId equals the eventId. Result `[1_000_000]` = YES, `[0]` = NO.

### Incremental NegRisk

Multiple independent subconditions under one request. Each subcondition is reported separately with `resultLength = 1`. Example: 3-outcome market where each outcome is resolved independently.

### Atomic NegRisk

All real subconditions resolve through one event-level request. `resultLength = 1`; the single value is the winning real condition index. Example: a 5-outcome market resolved with `[2]` means outcome 2 wins. The aggregator reports that winning condition as YES to the target, and `NegRiskModule.getResult` derives the remaining real conditions as NO.

## Request Initialization

`initializeRequest` (operator-gated) registers a request and its modules in one call. Beyond the
uniform `resultLength == 1` check, it enforces a uniform shape so every request is finalizable
and disputable by construction:

- **Reporters and disputers are both mandatory.** `reporterThreshold` and `disputerThreshold` must
  each be at least one, and after registration the number of *distinct* reporter (resp. disputer)
  modules must be at least its threshold. Because the module sets dedupe, an array padded with
  duplicate addresses cannot satisfy a threshold it could never meet.
- **An arbitrator is always required** (`arbitratorModule != 0`). The liveness window may be zero;
  in that case the proposal is finalizable in the same block and cannot be disputed.
- `targetContract` must be non-zero and equal the module registered in `PositionManager` for the
  event's encoded module ID. Binary requests require module ID `1`; both NegRisk request types
  require module ID `2`. The request must not already exist.

Votes are tallied per module (deduped via `hasReporterVoted` / `hasDisputerVoted`), so a result or
dispute only crosses its threshold when that many distinct modules act. On escalation the arbitrator
hook is invoked best-effort via a low-level call: a non-responsive arbitrator does not brick conflict
or dispute handling — the request still parks in `ArbitrationRequested` for admin `resolveResult`,
and a deployed revert surfaces as `ArbitratorHookFailed`.

On success, `RequestInitialized` emits the complete genesis configuration needed to reconstruct the
request from logs: event ID, target, thresholds, result length, market type, arbitrator, liveness
window, and finalizer. Later changes to mutable fields are emitted separately through
`ArbitratorModuleSet`, `LivenessWindowSet`, and `FinalizerSet`.

## Structs

### InitParams

Parameters passed to `initializeRequest`:

| Field | Type | Description |
|-------|------|-------------|
| `eventId` | `EventId` | Typed event ID per the Ids.sol ID scheme (`bytes29` underlying) |
| `marketType` | `MarketType` | Request shape (Binary, Incremental NegRisk, Atomic NegRisk) |
| `targetContract` | `address` | Reporter contract receiving final results |
| `resultLength` | `uint16` | Expected result array length per report (must be `1` for all market types) |
| `reporterModules` | `ModuleConfig[]` | Reporter modules and their init data |
| `reporterThreshold` | `uint16` | Matching votes needed to propose |
| `disputerModules` | `ModuleConfig[]` | Disputer modules and their init data |
| `disputerThreshold` | `uint16` | Disputes needed to trigger arbitration |
| `arbitratorModule` | `address` | Arbitrator module address |
| `arbitratorInitData` | `bytes` | Arbitrator initialization payload |
| `livenessWindow` | `uint32` | Seconds to wait for disputes after proposal (zero to 7 days) |
| `finalizer` | `address` | Address allowed to call `finalize` (zero = permissionless) |

### RequestConfig (3 storage slots)

Stored per `eventId`:

| Field | Type | Description |
|-------|------|-------------|
| `targetContract` | `address` | Target reporter contract |
| `marketType` | `MarketType` | Request shape (Binary, Incremental, Atomic) |
| `resultLength` | `uint16` | Expected result elements per report (always `1`) |
| `livenessWindow` | `uint32` | Dispute window duration in seconds (zero to 7 days) |
| `reporterThreshold` | `uint16` | Votes required for proposal |
| `disputerThreshold` | `uint16` | Disputes required for arbitration |
| `arbitratorModule` | `address` | Arbitrator module |
| `finalizer` | `address` | Address allowed to call `finalize` (zero = permissionless) |

### ResolutionState

Stored per condition (or per event for atomic NegRisk):

| Field | Type | Description |
|-------|------|-------------|
| `status` | `ResolutionStatus` | Current lifecycle state |
| `disputeCount` | `uint16` | Disputes received |
| `disputeWindowEnd` | `uint40` | Timestamp when dispute window closes |
| `proposedResultHash` | `bytes32` | Hash of the proposed result array |

### Storage Keying

| Mapping | Key | Notes |
|---------|-----|-------|
| `requestConfigs` | `EventId` | Typed; one config per event |
| `resolutionStates` | `bytes32` (requestId) | Opaque — conditionId for binary/incremental NegRisk, eventId-as-condition for atomic NegRisk |
| `hasReporterVoted` | `bytes32` (requestId) | Same opaque keying as `resolutionStates` |
| `marketPaused` | `EventId` | Typed; per-event pause flag, independent of `globalPaused` |

The `bytes32 requestId` is the canonical wire format of the underlying ID: callers pass `ConditionId.unwrap(...)` (re-padded to `bytes32`) for per-condition reports and `EventId.unwrap(...)` (re-padded to `bytes32`) for atomic NegRisk reports. Submodule per-request entry points (`report`, `dispute`) take `bytes32` for this reason; the per-event `initialize*Module` entry points take `EventId` directly.

## Key Design Decisions

### Result Hashing

The aggregator stores only `keccak256(abi.encode(result))` rather than the full result array. Callers re-provide the result at finalization time, verified against the stored hash. This keeps storage to one slot per condition regardless of outcome count.

### Vote-based Reporting

Results aren't accepted from a single reporter. Multiple reporter modules vote, and a proposal is created only when `reporterThreshold` matching votes are received. Vote keys are `keccak256(abi.encode(conditionId, resultHash))`.

### Result Validation

Every reported (`reportResult`) and resolved (`resolveResult`) result is checked by `_validateResult`: its length must be 1. Binary values may be any payout up to `RESULT_DENOMINATOR`. Incremental NegRisk values must be either `0` or `RESULT_DENOMINATOR`. Atomic NegRisk values are winner indexes and must be less than the event arity.

### Target Reporting

When `_finalizeConditions()` executes, binary and incremental requests become a binary target report `[value, RESULT_DENOMINATOR - value]` for the request condition. Atomic NegRisk treats `result[0]` as the winning condition index and reports only that condition as `[RESULT_DENOMINATOR, 0]`; the target module derives the remaining real conditions as NO.

### Canonicality Discipline

Every external entry point that accepts a `bytes32 _requestId` / `bytes32 _conditionId` / `bytes32 _eventId` validates it at line 1 via `ConditionIdLib.from` or `EventIdLib.from` (defined in `src/libraries/Ids.sol`). Non-canonical inputs (dirty outcome byte for ConditionId, dirty bottom 24 bits for EventId) revert immediately with `NonCanonicalConditionId` / `NonCanonicalEventId` rather than silently aliasing into a parallel storage slot. This includes the soft views (`getRequestState`, `getResultLength`, `getRequestShape`, module-side `report`/`dispute`/`getEventWindow`): all revert on dirty input.

Storage mappings keyed by structured IDs are typed (`mapping(EventId => RequestConfig)`, `mapping(ConditionId => ResolutionState)`, etc.). Because UDVTs serialize as their underlying type, 4-byte selectors, event topics, EIP-712 typehashes, and storage slot derivation are all unchanged across the typing.

## Module Types

### EOAReporterModule

Source: `src/oracle/modules/reporters/EOAReporterModule.sol`

Authorized EOA addresses submit results through a shared module instance. Initialized with an array of authorized reporter addresses per event. The aggregator counts one vote per registered module per request, so the first authorized reporter to call `report` casts the module's single vote; later calls revert in the aggregator with `AlreadyVoted`. Authorizing multiple reporters provides sender redundancy (any-of-N), not additional votes — a `reporterThreshold` of N requires N registered reporter modules.

### ChainlinkReporterModule

Source: `src/oracle/modules/reporters/ChainlinkReporterModule.sol`

Candle-based price resolution using Chainlink Data Streams. Reads start and end prices from a `DataStore` contract, reports `RESULT_DENOMINATOR` (YES) if `endPrice >= startPrice`, else `0` (NO). Configured per event with `assetPair`, `duration`, and `startTimestamp`; initialization requires a nonzero `duration` and a window end (`startTimestamp + duration`) in the future. Has its own `pause`/`unpause`, `setPriceSource`, and `setFeedId` admin functions.

### OOReporterModule

Source: `src/oracle/modules/OOReporterModule.sol`

Registers Polymarket request IDs with UMA's managed OOReporter and submits settled UMA results through `reportResult` as a normal reporter vote. It may relay ordinary `finalize` after Polymarket liveness but never calls `resolveResult` and has no arbitration authority. Registration can be supplied through reporter init data or performed later by a module operator; UMA request initialization remains controlled by UMA's separate `oracleInitializer` role.

## ChainlinkReporterModule Trust Model

The `ChainlinkReporterModule` delegates Chainlink report verification and correctness entirely offchain to the configured `priceSource` writer. Operators must understand and accept the following assumptions before deploying or relying on this reporter.

### 1. `priceSource` writer is fully trusted

The `priceSource` address configured on the module (and the corresponding writer address in `DataStore`) is the sole source of price data. The module does not cross-check prices against any additional feed or heuristic. Whatever price the writer stores is the price the module converts to `0` or `RESULT_DENOMINATOR` payouts, so the correctness of that price rests entirely with the writer.

**Implication:** operators are responsible for the operational security of the `priceSource` key (HSM, multi-party signing, role separation, monitoring). The `setPriceSource` admin can rotate the writer.

### 2. `DataStore::write` is not append-only

The `DataStore` contract permits the writer to overwrite any `(writer, key)` pair, and the reporter reads at `report()` time, so the value present at that moment is the one used for the start and end of the window.

**Implication:** operators must ensure the writer pipeline is append-only at the application layer (e.g. refuse to write if the slot is already populated, or require a cooling-off between writes).

### 3. Report authenticity is established offchain

The module does not verify Chainlink Data Streams report signatures, Merkle proofs, or committee attestations onchain. Report authenticity is established offchain inside the writer pipeline.

**Implication:** the module accepts whatever the writer has stored, so the writer pipeline must integrate Chainlink's official Data Streams verifier and only write after signature validation succeeds.

### 4. Signed-price encoding is enforced; decimal and feed-ID validation are not

The writer must store each Chainlink `int192` price at `keccak256(abi.encode(feedId, timestamp))` using the canonical sign-extended encoding `bytes32(uint256(int256(price)))`. This encoding supports both positive and negative prices. The module decodes the full 256-bit word and rejects values outside the `int192` range with `InvalidPriceEncoding`; `isPriceAvailable` also returns `false` for a non-canonical value.

The encoding check does not enforce a decimal contract (e.g. 8 vs 18 decimals), nor does it verify that the feed ID configured via `setFeedId` corresponds to the expected asset pair.

**Implication:** the writer must preserve the sign when widening `int192` to the stored 256-bit word; zero-extending a negative value is invalid and prevents reporting. An `assetPair -> feedId` misconfiguration or a decimal mismatch between start and end prices can still silently produce incorrect payouts.

### 5. Window timing is the writer's responsibility

The module does not check that the window start/end timestamps are in the past, nor does it enforce any bound on the age of the written price data.

**Implication:** the module reports from whatever values are stored for the window keys, so `startTimestamp` and `duration` must match the writer's cadence and the writer must store the intended window prices.

### Defense in depth via `OracleAggregator`

The `OracleAggregator` composes multiple reporters via its `reporterThreshold` parameter: a result only finalizes once at least `threshold` distinct reporters submit matching payouts. Using `ChainlinkReporterModule` alongside one or more independent reporters (e.g. `EOAReporterModule`, a second Chainlink-configured module with a different `priceSource`) means no single writer determines the outcome.

**Recommended threshold:** set `reporterThreshold >= 2` whenever `ChainlinkReporterModule` is one of the reporters for a production event. The exact threshold and reporter mix are operational decisions left to the deployer — see `InitParams` and `RequestConfig` for wiring and per-event configuration.

## Market Management

An operator (`OPERATOR_ROLE`, `_ROLE_1`) — or an admin — can mutate a request's configuration after
initialization and selectively pause markets. These actions are gated by `onlyOperatorOrAdmin`. They
are allowed for any request that is not `Resolved` (including mid-arbitration). Each config edit is
keyed by `requestId` and rejects a resolved request before mutating its event-level config. For
incremental NegRisk, an unresolved child can therefore update the config shared by its siblings even
after another child resolves. (The operator role absorbs the former market-manager duties in
addition to `initializeRequest`.)

| Function | Effect |
|----------|--------|
| `addReporterModules(requestId, configs)` | Register additional reporter modules (runs each module's init data) |
| `removeReporterModules(requestId, addrs)` | Deregister reporter modules (prior votes are not purged) |
| `addDisputerModules(requestId, configs)` | Register additional disputer modules |
| `removeDisputerModules(requestId, addrs)` | Deregister disputer modules |
| `setArbitratorModule(requestId, addr, initData)` | Swap the arbitrator module (optionally init it) |
| `setFinalizer(requestId, addr)` | Set/clear the `finalize` gate (zero = permissionless) |
| `setLivenessWindow(requestId, seconds)` | Change future proposals' liveness window (maximum 7 days) |
| `pauseMarkets(eventIds[])` / `unpauseMarkets(eventIds[])` | Batch toggle the per-event pause |

`targetContract`, `marketType`, `resultLength`, and the reporter/disputer thresholds have no
setters and are immutable after initialization. Module edits make the operator a **fully trusted
role**: it chooses which arbitrator `resolveResult` accepts calls from and which reporter modules
may vote, so resolution authority for every request follows the operator's configuration and there
is no structural separation between the operator and resolution state. Every request is initialized with both reporter and
disputer modules present, each with a threshold of at least one, and a non-zero arbitrator (see
[Request Initialization](#request-initialization)). Mutations preserve that shape — in particular,
neither module set can be reduced below its threshold:

- All seven config-edit functions revert with `RequestAlreadyResolved` when the supplied request is
  resolved.
- `removeReporterModules` / `removeDisputerModules` revert if the removal would leave fewer distinct
  modules than the corresponding threshold.
- `setLivenessWindow` accepts values from zero through 7 days and only affects proposals created
  after the change. An existing proposal's `disputeWindowEnd` is fixed at proposal time. Setting it
  to zero makes future proposals
  finalizable in their reporting block and leaves no opportunity to dispute them.
- `setArbitratorModule` cannot zero the arbitrator (which would otherwise disable dispute
  escalation); supplying init data requires the target to be a contract.
- `addDisputerModules` requires the request to already be disputable, which holds for every request
  created under the current invariant.

> **Arbitrator swap:** `setArbitratorModule` does not replay `onArbitrationTriggered` for conditions
> already in `ArbitrationRequested`, so the new module starts without local state for them and the
> previous module's state is no longer consulted. Finish such a condition through the new arbitrator's
> resolve path or an admin `resolveResult`.

## Auth

The OracleAggregator uses its own `Auth` mixin (`src/oracle/mixins/Auth.sol`) plus a locally-defined
`RULE_MANAGER_ROLE`, not the shared `src/auth/Roles.sol`:

| Role | Constant | Capabilities |
|------|----------|-------------|
| Owner | — | `addAdmin`, `removeAdmin`, UUPS upgrade |
| Admin | `_ROLE_0` | `removeAdmin`, `addOperator`/`removeOperator`, `addRuleManager`/`removeRuleManager`, `pause`/`unpause`, `resolveResult`, plus all operator and rule-manager actions |
| Operator | `_ROLE_1` | `initializeRequest` + per-event config edits + `pauseMarkets`/`unpauseMarkets` (see [Market Management](#market-management)) |
| Rule Manager | `_ROLE_2` | Add/edit product specifications via `setProductSpecification` (see [Market Data Registry](#market-data-registry)). Per-request rule updates are owned by the Operator via `updateRequestRules` |

## Pause

Two independent pause layers:

- **Global pause** — via `src/oracle/mixins/Pausable.sol`. Admin calls `pauseOracle()`/`unpauseOracle()`.
  The `whenUnpaused` modifier guards `reportResult`, `disputeResult`, `resolveResult`, and `finalize`.
- **Per-event pause** (`marketPaused`) — set by an operator or admin via `pauseMarkets`/
  `unpauseMarkets`. It only blocks `finalize` for the affected event (everyone, including a configured
  finalizer). Reports, disputes, and admin/arbitrator `resolveResult` continue to work, so a paused
  market can still be resolved by the arbitrator or an admin.

## View Functions

| Function | Description |
|----------|-------------|
| `getRequestState(requestId)` | Returns (status, proposedResultHash, disputeWindowEnd, disputeCount) |
| `getReportVotes(requestId, result)` | Vote count for a specific result on a condition |
| `getResultLength(requestId)` | Expected result array length for the request (always `1`) |
| `getRequestShape(requestId)` | Authoritative market type and result length for the request |

## Market Data Registry

The aggregator inherits the `MarketDataRegistry` mixin (`src/oracle/mixins/MarketDataRegistry.sol`),
an onchain store for market reference data. Product specifications are written by the rule
manager (or admin); per-request rule updates are written by the operator (or admin) through the
aggregator's `updateRequestRules` entry point. Storage lives in an ERC-7201 namespaced slot, so
it does not affect the aggregator's storage layout. Two data shapes:

**Product specifications.** `setProductSpecification(name, uri)` maps a product name (shared across
many markets — e.g. a sports league) to a specification-document URI. Keys are case-insensitive
(ASCII `A-Z` → `a-z`); the first write's casing is preserved as the display `name`. Each write
increments a per-product `version` and emits `ProductSpecificationUpdated`, so consumers reconstruct
the full URI changelog from logs while the latest pointer is read via `getProductSpecification(name)`
(high-level) or `getProductSpecificationById(productId)` (low-level). `productId(name)` exposes the key.

**Rules.** Per-request rule updates flow exclusively through the aggregator's
`updateRequestRules(requestId, updatedRules)` entry point (operator-gated). It appends to a
per-request, append-only history via the mixin's internal `_pushRule` helper (emitting
`RuleAdded`), then iterates the event's registered reporter modules and calls
`IReporterModule.updateRules(requestId, updatedRules)` on each — so reporters that mirror rules
to external systems (e.g. UMA's OOReporter via `OOReporterModule`) stay in sync. The aggregator
remains the canonical source for the rule history (mirroring the `requestRulesUpdates` pattern
in UMA's OOReporter). The OOReporter module ignores `RequestAlreadyResolved` and
`RequestNotRegistered` when forwarding because neither UMA request can accept new metadata; any
other forwarding failure reverts the transaction and rolls back the aggregator-side write. Read via
`getRules(requestId)`, `getLatestRule(requestId)`,
`getRuleAt(requestId, index)`, and `getRuleCount(requestId)`. Because the aggregator knows
request state, rules are gated: a rule is rejected for an unknown request (`RequestNotFound`)
or an already-resolved one (`RequestAlreadyResolved`).

Market rules can reference a product spec by name and a request's rule list by `requestId`;
citing a specific spec `version` (rather than "the current spec") keeps an open market's terms
deterministic, while the changelog events let anyone reconstruct what was in force at resolution time.

## Upgradeability

UUPS proxy pattern. `initialize(owner)` sets the contract owner. `_authorizeUpgrade` restricted to `onlyOwner`.

# Modules

Modules implement market logic for the [Position Manager](position-manager.md). Each module is registered by its `moduleId()` and governs identifier derivation, result reporting, and settlement for its market type.

## BinaryModule (moduleId = 1)

Source: `src/modules/BinaryModule.sol`

Binary markets have a single condition with two outcomes (YES / NO).

BinaryModule uses the UUPS proxy pattern. `initialize(owner, admin)` sets the proxied owner and
initial admin. The implementation constructor still sets immutable external references
(`PositionManager`, `CollateralToken`, legacy CTF, `USDCE`), so each proxy uses a dedicated
implementation with matching constructor config.

### Condition Lifecycle

1. **`getConditionId(data) → conditionId`** — derives the binary condition ID, embedding the module's configured `RESOLUTION_CHAIN`. Native conditions need no preparation or storage.
2. **`reportResult(conditionId, result)`** (`onlyResolver`) — a resolver- or bridge-role caller reports `[YES_payout, NO_payout]` normalized to `RESULT_DENOMINATOR` (1,000,000). See [Result Reporting & Replays](#result-reporting--replays).
3. **Split / Merge / Redeem** — inherited from `BaseModule`; inputs are pre-transferred to the module, typically via the [Router](router.md)

### View Functions

- `getConditionId(data) → bytes32` — computes the condition ID for given data (embeds the module's `RESOLUTION_CHAIN`)
- `getPayout(positionId, amount) → uint256` — payout amount for a resolved position
- `getResult(conditionId) → uint256[]`

## NegRiskModule (moduleId = 2)

Source: `src/modules/NegRiskModule.sol`

Neg-risk markets group multiple conditions under an event. Real conditions occupy indexes `[0, arity)`. A synthetic **Other** condition at index `arity` is derived lazily by `getResult` (never stored, except when reported directly by a bridge): it derives NO once any real condition resolves YES, and derives YES once every real condition has resolved NO. Unresolved real siblings likewise derive NO once one condition resolves YES, completing the payout partition without per-condition reports.

NegRiskModule also uses the UUPS proxy pattern. `initialize(owner, admin)` sets the proxied owner
and initial admin, while the implementation constructor retains immutable references for
`PositionManager`, `CollateralToken`, legacy CTF, `USDCE`, and the legacy NegRisk adapter.

### Event Lifecycle

1. **`getEventId(conditionCount, data) → eventId`** — derives the canonical neg-risk event ID, embedding the module's configured `RESOLUTION_CHAIN`. The 16-bit arity is embedded directly in the ID (real condition count only; excludes the synthetic Other).
2. **`reportResult(conditionId, result)`** (`onlyResolver`) — reports result for one real condition. Resolver-role callers may report real condition indexes only; bridge callers may also report the synthetic Other result from cross-chain messages. Results must be fully binary (each side `0` or `RESULT_DENOMINATOR`) and at most one condition per event can resolve YES — a second YES reverts `InvalidResults`, and the first emits `RemainingConditionsDerivableAsNo`. A bridge-reported synthetic Other NO also reverts `InvalidResults` once every real condition has directly stored NO, in either delivery order — an event cannot end with every condition NO. When every real condition instead resolves NO, `SyntheticConditionDerivableAsYes` identifies the synthetic Other condition that becomes YES. Locally derived losers and synthetic Other results are not stored — `getResult` derives them once event state is final; a bridge-reported synthetic result is stored directly. See [Result Reporting & Replays](#result-reporting--replays).

### Horizontal Operations

- **`horizontalSplit(to, eventId, amount)`** — mints one YES position per real condition plus the synthetic Other, burns collateral. Collateral must be pre-transferred to the module before calling.
- **`horizontalMerge(to, eventId, amount)`** — mints collateral, burns YES positions (real conditions plus synthetic Other). Positions must be pre-transferred to the module before calling.
- **`convert(to, eventId, conditionIndex, amount)`** — converts a NO position into YES positions for all other conditions, including the synthetic Other at index `arity`. Leverages the identity: 1 NO(i) = all YES(j) for j≠i. NO position must be pre-transferred to the module. No collateral movement needed.

### View Functions

- `conditionCount(eventId) → uint256` — number of **real** conditions in the event (arity), excluding the synthetic Other
- `resultsSum(eventId) → uint256` — `RESULT_DENOMINATOR` once a YES result has been stored for the event, else `0` (at most one YES per event)
- `conditionsResolved(eventId) → uint256` — number of real conditions with directly stored results; synthetic Other and lazily derived sibling results are not counted. Events fully resolved under earlier implementations may permanently read `arity + 1`, having also counted the stored synthetic Other
- `getResult(conditionId)` / `hasResult(conditionId)` / `getPayout(positionId, amount)` — overridden to serve derived results: sibling NO once `resultsSum == RESULT_DENOMINATOR`, and an unstored synthetic Other YES once every real condition has stored NO. The corresponding transitions emit `RemainingConditionsDerivableAsNo` and `SyntheticConditionDerivableAsYes`, respectively. Migration conditions never derive — they resolve from legacy CTF payouts (via `resolveMigrationCondition`, a bridge report, or migration of an already-resolved condition; see [Migration](migration.md)).

Event IDs are derived purely from condition IDs via `conditionId.eventId()` (`ConditionIdLib.eventId`) — a pure library function with no storage access.

## CombinatorialModule (moduleId = 3)

Source: `src/modules/CombinatorialModule.sol`

Combinatorial markets are conjunctions of up to `MAX_LEGS = 50` underlying binary/neg-risk conditions. A **leg** is an underlying position ID (a (condition, outcome) pair). A YES combinatorial position pays out the product of its legs' payouts; the NO position pays the complement.

CombinatorialModule is UUPS-upgradeable with the same `initialize(owner, admin)` pattern as the other modules, but it does **not** inherit `BaseModule`/`OracleModule`: it stores no results of its own and has no `reportResult`. Leg resolution is read from the underlying modules via `BaseModule.getResult(leg.conditionId())`.

### Condition Preparation

Unlike binary/neg-risk conditions, combinatorial conditions require preparation. `getConditionId(legs)` hashes the canonical leg array (ascending order, no duplicate or contradictory condition IDs, binary/neg-risk legs only) into the condition ID's base hash, and `prepareCondition(legs)` (permissionless) stores the array in `legs[conditionId]`.

A stored definition is never silently reused for a different one: `prepareCondition` is idempotent for an *identical* definition and reverts `ConditionDefinitionMismatch` for a different one. Every operation that derives a leg array commits it through that same guarded write, in both directions: the refinement operations, so children are always operable, and the inverse operations (`mergeOnCondition`, `mergeOnEvent`, `inject`, `mergeFromYesBasket`) too. `split` completes the set by requiring its condition to be prepared already, reverting `ConditionNotPrepared` otherwise, so no combinatorial position can exist without a definition behind it.

Storing in the inverse direction rather than merely comparing is deliberate. Now that every mint path binds, an inverse op's write always resolves to the comparison branch, so the two rules overlap — and the overlap is the point: committing the definition at the moment of consumption means every consumed position settles against a definition bound no later than that consumption, however the position was minted. Both checks are fail-closed: a condition ID whose stored definition differs from the derived one reverts permanently rather than settling against the wrong basket, and the revert propagates through `Exchange.matchOrdersAndPrepareCombinatorial` and `Router.combinatorialCollateralReturn`.

### Operations

All operations use the pre-transfer pattern (inputs pre-transferred to the module, typically via the [Router](router.md)):

| Operation | Effect |
|-----------|--------|
| `split(to[], conditionId, amount)` / `merge(to, conditionId, amount)` | Collateral ⇄ YES + NO combinatorial pair |
| `splitOnCondition(to[], parentYesId, conditionId, amount)` / `mergeOnCondition(to, parentYesId, conditionId, amount)` | YES(P) ⇄ YES(P∧Y(m)) + YES(P∧N(m)) |
| `splitOnEvent(to[], parentYesId, eventId, amount)` / `mergeOnEvent(to, parentYesId, eventId, amount)` | YES(P) ⇄ one YES child per neg-risk event outcome (incl. the synthetic Other) |
| `convertOnEvent(to[], parentYesId, conditionIndex, amount)` | Expands a neg-risk NO leg into YES children for every other outcome of that event |
| `extract(to[], fullNoId, conditionIndex, amount)` / `inject(to, fullNoId, conditionIndex, amount)` | NO(P∧d) ⇄ NO(P) + YES(P∧¬d) |
| `convertToYesBasket(to[], fullNoId, amount)` / `mergeFromYesBasket(to, fullNoId, amount)` | NO(Q) ⇄ canonical YES basket |
| `compress(to, positionId, amount)` | Strips resolved legs: pays out resolved value as collateral, mints a reduced position for the unresolved remainder |
| `redeem(to, positionId, amount)` | Redeems for collateral once the payout is final or terminal |
| `wrap(to, underlyingPositionId, amount)` / `unwrap(to, positionId, amount)` | Underlying binary/neg-risk position ⇄ single-leg combinatorial position. `wrap` always mints the YES form; `unwrap` accepts YES or NO (a NO unwraps to the flipped underlying). Requires `crossModuleAuth` on the PositionManager |

Every refinement event records both `user` (the immediate caller/initiator) and the actual output
recipient or recipient array. In routed flows `user` is the Router while the recipient fields identify
the end user. Array recipients preserve the same output ordering documented by the corresponding
operation.

### Payouts

`getPayout(positionId, amount)`: YES pays `amount` scaled by the product of leg payout numerators (rounded down); NO pays the complement (rounded in the direction that never over-pays the pair). Reverts `PositionNotRedeemable` while any leg is unresolved, unless a resolved zero-payout leg already makes the result terminal (YES → 0, NO → full amount).

Combinatorial positions cannot be bridged, and the module exposes no bridge surface to make it possible: there is no `mintFromBridge`/`burnFromBridge`, no `addBridge`/`removeBridge`, and no bridge role. `legs[]` is per-chain state, so a combinatorial position is operable only on a chain that already holds its definition, and a position payload carries only the ID and amount — not enough for the destination to confirm that its definition matches the source's. `BridgeBase` independently refuses `moduleId = 3` on both the send and the receive path, by omitting it from its bridgeable-module allowlist and regardless of `moduleSupported` configuration, so the invariant holds at both layers rather than depending on a particular transport. To move value, bridge collateral and build the position locally on the destination chain. See [Bridge](bridge.md) for the full rationale and what supporting it would require.

## Result Reporting & Replays

`BinaryModule.reportResult` and `NegRiskModule.reportResult` share the same authorization and replay semantics:

**Authorization (`onlyResolver` modifier).** The caller must hold the bridge or resolver role. Callers holding the resolver role must report condition IDs whose encoded `resolutionChain` matches the module's `RESOLUTION_CHAIN` immutable — otherwise `InvalidResolutionChain`. Bridge-only callers are exempt from the chain check because they relay results already finalized on the resolution chain. Both paths respect the resolver pause (`ResolverIsPaused`) and the event-level resolution pause (`ResolutionIsPaused`).

**Replays.** When a result is already stored:

- A report with a **different** payout vector always reverts `ExistingPayoutMismatch` — this is catastrophic and should never happen.
- A **matching** report from a resolver-role caller reverts `ConditionAlreadyResolved` (resolvers are expected to handle the revert).
- A **matching** report from a bridge-only caller returns silently, making cross-chain result relays safely replayable.

**Migration conditions.** Resolver-role callers cannot resolve migration conditions (`MigrationNotSupported`). A bridge-role report on an unresolved migration condition resolves it from the legacy CTF's actual payouts (via `_resolveMigrationCondition`) and then verifies the bridge-supplied payout vector matches the CTF-derived result, reverting `ExistingPayoutMismatch` on divergence. See [Migration](migration.md).

## Abstract Hierarchy

### BaseModule

Source: `src/modules/abstract/BaseModule.sol`

Base for all modules. Provides:

- **`split(to[], conditionId, amount)`** — mints YES + NO positions, burns collateral. Collateral must be pre-transferred to the module before calling.
- **`merge(to, conditionId, amount)`** — mints collateral, burns YES + NO positions. Positions must be pre-transferred to the module before calling.
- **`redeem(to, positionId, amount)`** — mints collateral payout, burns position. Position must be pre-transferred to the module before calling.
- **`_storeResult(conditionId, result)`** — validates the result array (length 2, sums to `RESULT_DENOMINATOR`), stores it, and emits `ConditionResolved`. Does not check for duplicate resolution — callers guard against already-resolved conditions. `NegRiskModule` overrides it to additionally require fully binary payouts (`0` or `RESULT_DENOMINATOR`).
- **`getPayout(positionId, amount)`** — `amount * result[outcomeIndex] / RESULT_DENOMINATOR`
- Views: `getResult(conditionId)`, `hasResult(conditionId)` — the base implementations read stored results only; `NegRiskModule` overrides them (and `getPayout`) to also serve lazily derived results
- **`getResultForBridge(conditionId)`** — bridge-export hook that returns `getResult` by default. `NegRiskModule` overrides it to delay a migrated event's winning result until every real legacy condition has a directly stored V2 result.
- Bridge functions (`onlyBridge`): `mintFromBridge(to, positionId, amount)`, `burnFromBridge(positionIds, amounts)`

Constants: `RESULT_DENOMINATOR = 1_000_000`. Immutables: `POSITION_MANAGER`, `COLLATERAL_TOKEN`, and `RESOLUTION_CHAIN` (the chain enum allowed to resolve this module's conditions, encoded into every generated ID).

**Canonicality.** External entrypoints (`getResult`, `hasResult`, `split`, `merge`, `reportResult`, …) accept structured IDs as typed values (`ConditionId` is `bytes31`), so the strict ABI decoder rejects non-canonical input (a non-zero outcome byte) before the function body runs. Entrypoints that still take raw `bytes32` (e.g. `resolveMigrationCondition`) validate at line 1 via `ConditionIdLib.from`, reverting `NonCanonicalConditionId`. The `result` mapping is typed `mapping(ConditionId => uint256[])`; analogous typed mappings exist throughout the module hierarchy (`resultsSum`, `conditionsResolved`, `legacyConditionId`, `legacyEventId`, etc.). See [Position IDs](position-ids.md) for the type-system rationale.

### OracleModule

Source: `src/modules/abstract/OracleModule.sol`

Role-based resolution authorization and pause controls. There is no per-condition oracle assignment — resolution is authorized by the bridge and resolver roles:

- **`addResolver(addr)` / `removeResolver(addr)`** (`onlyAdmin`) — grant/revoke the resolver role (typically held by the [OracleAggregator](oracle.md))
- **`addBridge(addr)` / `removeBridge(addr)`** (`onlyAdmin`) — grant/revoke the bridge role (held by the CCIP bridge)
- **`pauseResolver(addr)` / `unpauseResolver(addr)`** (`onlyAdmin`) — pauses/unpauses all reporting by a resolver address
- **`pauseResolution(eventId)` / `unpauseResolution(eventId)`** (`onlyAdmin`) — pauses/unpauses new resolution writes (resolver reports, bridge reports, migration resolves) for an event; binary conditions are covered via their parent event ID. Lazy derivation from already-stored state is read-only and unaffected — pausing before a YES lands is what freezes an event's payouts.
- `onlyResolver(conditionId)` modifier — requires the bridge or resolver role; resolver-role callers must additionally match the condition's encoded resolution chain (`InvalidResolutionChain`); reverts if the caller is paused (`ResolverIsPaused`) or the parent event's resolution is paused (`ResolutionIsPaused`). See [Result Reporting & Replays](#result-reporting--replays).

### Migration Mixins

Source: `src/modules/migration/`

Migration logic is extracted into separate mixin contracts for modularity:

- **`BaseMigrationMixin`** (`BaseMigrationMixin.sol`) — shared migration logic: `migratePositions` (2 overloads, sorted legacy condition IDs), `resolveMigrationCondition`, legacy position transfer, complementary merging, redemption of resolved legacy conditions, collateral settlement. Respects event-level `resolutionPausedAt` so the admin kill switch freezes migration resolves. Inherits `BaseModule`.
- **`BinaryMigrationMixin`** (`BinaryMigrationMixin.sol`) — binary-specific: `prepareMigrationCondition`, legacy CTF state and hooks. Emits `MigrationConditionRegistered` so the legacy-to-V2 condition mapping is log-derivable.
- **`NegRiskMigrationMixin`** (`NegRiskMigrationMixin.sol`) — neg-risk-specific: `prepareMigrationEvent`, legacy adapter state and hooks. Emits the typed `legacyEventId` in `EventPrepared`. `NegRiskModule` overrides `_finalizeMigrationResolution` to delegate to `_finalizeNegriskResolution`, sharing aggregate YES tracking with the oracle path; the synthetic Other result is derived lazily by `getResult` in both paths.

Modules inherit their migration mixin as a separate parent: `BinaryModule is BaseModule, BinaryMigrationMixin`. To remove migration support, drop the mixin from the inheritance list and delete the `migration/` directory.

Because the migration mixins retain constructor-configured immutables, proxied module deployments
should create one implementation per proxy rather than sharing a single implementation across
different module configs.

### ModuleErrors

Source: `src/modules/abstract/ModuleErrors.sol`

Shared error definitions: `ConditionAlreadyResolved`, `ExistingPayoutMismatch`, `ConditionNotResolved`, `InvalidResults`, `MigrationNotSupported`, `IncompatibleImplementation`, etc. (`CombinatorialModule` defines its own error set in `CombinatorialModule.sol`.)

## Resolution Management

There is no per-condition oracle assignment. Resolution is authorized by role, scoped by the resolution chain encoded in each condition ID:

- Any **resolver-role** holder (typically the OracleAggregator) can report any condition whose encoded resolution chain matches the module's `RESOLUTION_CHAIN`.
- Any **bridge-role** holder (the CCIP bridge) can relay results for any condition, including the neg-risk synthetic Other and migration conditions.
- The admin can **pause** a resolver address globally (`pauseResolver`) or pause resolution writes for an event (`pauseResolution(eventId)`); binary conditions are covered via their parent event ID. **Unpause** restores reporting.

The `onlyResolver` modifier enforces role membership, the resolution chain check for resolver-role callers, and both pause switches. Replay behavior is described in [Result Reporting & Replays](#result-reporting--replays).

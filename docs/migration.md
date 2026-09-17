# Migration

Migration enables users to move positions from legacy ConditionalTokens (CTF) and NegRiskAdapter contracts into the PositionManager system.

## Architecture

Migration logic lives in dedicated mixin contracts under `src/modules/migration/`:

- **`BaseMigrationMixin`** — shared: `migratePositions` overloads, legacy redemption, and collateral settlement
- **`BinaryMigrationMixin`** — binary-specific setup, resolution, and legacy CTF hooks
- **`NegRiskMigrationMixin`** — neg-risk-specific setup, resolution, and legacy adapter hooks

Modules inherit their mixin as a separate parent (`BinaryModule is BaseModule, BinaryMigrationMixin`). To remove migration, drop the mixin from the inheritance list.

Both modules are UUPS-upgradeable, but the migration mixins still rely on constructor-set immutable
references. In practice, that means each proxied module deployment uses its own dedicated
implementation with matching legacy contract addresses.

## Binary Migration

Source: `src/modules/migration/BinaryMigrationMixin.sol`

### Setup

**`prepareMigrationCondition(legacyConditionId)`** (`onlyCreator`) — links a legacy CTF condition ID to a structured condition ID. The legacy condition must have exactly 2 outcome slots. Stores the mapping in `legacyConditionId[structuredConditionId]` and emits `MigrationConditionRegistered(structuredConditionId, legacyConditionId)`. The structured condition ID is derived from the legacy condition ID via `getMigrationConditionId`.

### Migrating Positions

**`migratePositions(legacyConditionIds, outcomeIndices, amounts)`** (permissionless, self-service) — transfers the caller's legacy CTF positions to the module and mints the equivalent structured positions. Each entry names a registered legacy condition, an outcome index (0 or 1), and an amount; the legacy condition IDs must be sorted ascending (`UnsortedMigrationConditions`), so per-condition settlement work runs once per group. For a condition still unresolved on the CTF, the module merges complete YES/NO sets and leaves residual positions in place. For a condition already resolved on the CTF, the module stores the local result if missing (same path as `resolveMigrationCondition`, so the resolution pause applies) and redeems its whole legacy balance for that condition. Either way the released collateral is settled to the vault, keeping minted positions fully backed.

**`migratePositions(from, legacyConditionIds, outcomeIndices, amounts)`** (`onlyOperator`) — migration on behalf of `from`, which must have approved the module for its CTF positions; same sorted-input requirement.

### Resolving

**`resolveMigrationCondition(conditionId)`** (permissionless; defined on `BaseMigrationMixin`) — resolves a migration condition by reading payouts from the legacy CTF contract. The legacy condition must already be resolved (`ConditionNotResolved` otherwise). Converts CTF payouts to the `RESULT_DENOMINATOR` scale, then redeems the module's legacy positions and settles the proceeds to the vault. Reverts with `ResolutionIsPaused` when the admin has paused the parent event ID via `pauseResolution`. Safe to call again after resolution: a repeat call skips the already-stored result and just redeems any legacy positions the module has received since. Reverts with `NonCanonicalConditionId` if `conditionId` has a non-zero outcome byte — this is line-1 validation via `ConditionIdLib.from`, closing an audit-flagged alias-key vector where a malformed `conditionId | 0xNN` could previously read the canonical legacy payout but write event-level state under the alias (see [`docs/position-ids.md`](position-ids.md) for the type-system enforcement).

**Bridge-relayed resolution.** On the `reportResult` path, migration conditions are bridge-only: resolver-role callers revert `MigrationNotSupported`. A bridge report on an unresolved migration condition first resolves it from the legacy CTF via `_resolveMigrationCondition`, then verifies the bridge-supplied payout vector equals the CTF-derived result — reverting `ExistingPayoutMismatch` on divergence. Replays follow the standard rules (matching bridge replays return silently, conflicting replays revert); see [Modules — Result Reporting & Replays](modules.md#result-reporting--replays).

### ID Mapping

- `getMigrationConditionId(legacyConditionId) → bytes32` — computes structured condition ID
- `legacyConditionId(conditionId) → bytes32` — public mapping: structured condition ID → registered legacy CTF condition ID
- `getLegacyPositionId(conditionId, outcomeIndex) → uint256` — computes legacy CTF position ID from a structured condition

### MigrationNotSupported

If the module was deployed without a legacy `conditionalTokens` contract (address(0)), all migration functions revert with `MigrationNotSupported()`. This applies to spoke chain deployments where legacy contracts don't exist.

## NegRisk Migration

Source: `src/modules/migration/NegRiskMigrationMixin.sol`

### Setup

**`prepareMigrationEvent(legacyEventId)`** (`onlyCreator`) — links a legacy NegRiskAdapter event to a structured event ID. Reads the condition count from the legacy adapter — it must be in `[2, 256]` (`InsufficientConditionCount` below, `LegacyConditionCountTooLarge` above, because the legacy adapter encodes question indices as `uint8`) — and stores `legacyEventId[structuredEventId]` plus a `legacyConditionToConditionId` entry per condition. Emits `MigrationConditionRegistered` per condition and `EventPrepared(structuredEventId, conditionCount, legacyEventId)`. Do not add conditions to the legacy event after calling.

### Migrating Positions

**`migratePositions(legacyConditionIds, outcomeIndices, amounts)`** (permissionless) — same pattern as binary. Transfers legacy NegRisk positions (denominated in the adapter's wrapped collateral) to the module, mints structured equivalents. Legacy condition IDs must be sorted ascending; complete unresolved sets are merged once per condition, and resolved condition balances are redeemed into the vault.

**`migratePositions(from, legacyConditionIds, outcomeIndices, amounts)`** (`onlyOperator`) — migration on behalf of `from`; same sorted-input requirement.

### Resolving

**`resolveMigrationCondition(conditionId)`** (permissionless; shared `BaseMigrationMixin` implementation) — resolves a real migration condition from legacy CTF payouts, similar to the binary flow. `NegRiskModule` overrides the internal `_finalizeMigrationResolution` hook to delegate to `_finalizeNegriskResolution`, which updates `resultsSum[eventId]` and the directly stored real-condition count in `conditionsResolved[eventId]`, rejects multiple YES outcomes, and lets `getResult` derive the synthetic Other result when resolution completes. When the synthetic result was not already stored by a bridge, the final real NO emits `SyntheticConditionDerivableAsYes` with both the event and synthetic condition IDs. It also redeems the module's legacy positions and settles the vault, which is required for asymmetric migrations where a user migrated a loser-side NO without anyone migrating the matching YES. Reverts with `MigrationNotRegistered` on the synthetic Other index (`conditionIndex >= eventId.arity()`) because Other has no legacy CTF mapping. Honest legacy cannot report two-YES because of `MarketAlreadyDetermined`, but if it ever did, the second migration-resolve reverts with `InvalidResults` instead of silently draining the vault. Respects the admin event-level `pauseResolution` kill switch.

**Operational requirement.** For a NegRisk migration event, the legacy oracle must call `reportOutcome(_, true)` on the winning question AND `reportOutcome(_, false)` on every losing question, so each underlying CTF condition is resolved with `payoutNumerators` set. `resolveMigrationCondition` reads those payouts and reverts with `ConditionNotResolved` for any subcondition the oracle hasn't reported. The vault only receives wcol for conditions the module has successfully redeemed on the legacy CTF.

**Bridge-relayed resolution.** Identical to the binary flow: resolver-role callers revert `MigrationNotSupported` on migration conditions, and a bridge report resolves from the legacy CTF and verifies the bridge-supplied payouts against the CTF-derived result (`ExistingPayoutMismatch` on divergence).

**Cross-chain result gating.** Unresolved migrated positions remain bridgeable. A winning migrated NegRisk result, however, cannot be exported from the hub until every real condition in the legacy event has a directly stored V2 result; `getResultForBridge` reverts with `MigrationEventNotFullyResolved` until then. This prevents a spoke—which intentionally has no migration metadata—from treating the bridged winner as a native NegRisk result and lazily deriving unsettled legacy siblings as NO. Losing results may be bridged independently because they do not make sibling claims redeemable.

### Synthetic Other Condition

Neg-risk events include a module-derived **Other** condition at index `eventId.arity()` (one past the last real outcome). It is not registered during `prepareMigrationEvent` and has no legacy CTF mapping — `getLegacyConditionId` returns `bytes32(0)` for that index, and `_getLegacyConditionIdForResolve` reverts with `MigrationNotRegistered`. The Other result is never stored; `getResult` derives it lazily — NO once aggregate YES reaches `RESULT_DENOMINATOR`, YES once every real condition has resolved NO. Horizontal split/merge and convert include the Other condition alongside real conditions.

### ID Mapping

- `legacyEventId(eventId) → bytes32` — public mapping: structured event ID → registered legacy NegRisk event ID
- `legacyConditionToConditionId(legacyConditionId) → ConditionId` — public mapping: legacy CTF condition ID → structured condition ID
- Internal helpers (`getLegacyConditionIdFromEvent`, `getLegacyConditionId`) derive legacy CTF condition IDs from the stored event link. The synthetic Other index maps to `bytes32(0)` and cannot be migration-resolved.

### MigrationNotSupported

Same as binary — reverts if the module was deployed without legacy `conditionalTokens`, `negRiskAdapter`, or `wrappedCollateralToken` addresses.

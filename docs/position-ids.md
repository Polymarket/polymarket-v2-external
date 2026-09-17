# Structured Position IDs

Position IDs encode all routing and identity information directly in the ID itself, eliminating storage-based lookups.

## Bit Layout

```
[moduleId(8) | baseHash(128) | arity(16) | reserved(64) | resolutionChain(16) | conditionIndex(16) | outcomeIndex(8)]
 ────────────   ─────────────   ─────────   ────────────   ─────────────────     ────────────────     ──────────────
 bits 248-255   bits 120-247    bits 104-119 bits 40-103   bits 24-39            bits 8-23            bits 0-7
```

| Field             | Bits | Description                                                   |
|-------------------|------|---------------------------------------------------------------|
| `moduleId`        | 8    | Identifies which module owns this position (O(1) lookup)      |
| `baseHash`        | 128  | Truncated hash of event/question data                         |
| `arity`           | 16   | Neg-risk condition count (zero for binary and other modules)  |
| `reserved`        | 64   | Event-scoped reserved bits, part of event identity            |
| `resolutionChain` | 16   | Chain enum allowed to resolve this condition (0 = Polygon)    |
| `conditionIndex`  | 16   | Index within multi-condition events (0 for binary markets)    |
| `outcomeIndex`    | 8    | Outcome index (0 = YES, 1 = NO for binary markets)           |

A **Condition ID** is a position ID with `outcomeIndex = 0`.

An **Event ID** is a condition ID with `conditionIndex = 0`: `[moduleId(8) | baseHash(128) | arity(16) | reserved(64) | resolutionChain(16) | 0(24)]`.

The `resolutionChain` field is a `ResolutionChain` enum value (defined in `Ids.sol`; currently only `POLYGON = 0`) naming the chain whose resolvers are allowed to resolve the condition. Modules encode their constructor-configured `RESOLUTION_CHAIN` immutable into every ID they generate, and `OracleModule.onlyResolver` rejects resolver-role reports whose condition ID encodes a different chain (`InvalidResolutionChain`). Bridge-role callers are exempt — they relay results already finalized on the resolution chain, and the bridge only exports results from Polygon, refusing to import one there (see [bridge.md](./bridge.md#result-direction)). Because the field is part of event identity, the same market data produces distinct IDs per resolution chain.

The bridge does not read this field: it compares `block.chainid` against its own `RESOLUTION_CHAIN_ID` immutable, and an inbound result's source chain against the transport's own identifier for the resolution chain (`CcipBridge.RESOLUTION_CHAIN_SELECTOR`). Both are set per deployment because the enum stays `POLYGON` on testnet chains such as Amoy. Adding a `ResolutionChain` variant means changing those comparisons to derive the chain id from the ID's field, and supplying the matching transport identifier.

## Typed identifiers and canonicality

Three Solidity user-defined value types are defined in `src/libraries/Ids.sol`:

- `type ConditionId is bytes31` — underlying is `bytes31` (drops the outcome byte) so dirty
  values cannot exist by construction.
- `type EventId is bytes29` — underlying is `bytes29` (drops conditionIndex + outcome bytes) so
  dirty values cannot exist by construction.
- `type PositionId is uint256` — ERC1155 token ID. No additional canonicality invariant beyond
  the bit layout the encoders produce; the type is for compile-time safety against
  `amount`/`positionId` confusion at internal call sites.

Every external entry point that accepts a structured ID enforces canonicality
at the boundary: typed `ConditionId` / `EventId` parameters are rejected by the
strict ABI decoder when the dropped low bytes are non-zero, and entry points
that take raw `bytes32` (e.g. `resolveMigrationCondition`, the CtfRouter
surface) validate at line 1 via `ConditionIdLib.from(bytes32)` or
`EventIdLib.from(bytes32)`. Those two functions are the **only** sanctioned
ways to construct a `ConditionId` / `EventId` value from raw `bytes32`; they
revert `NonCanonicalConditionId` / `NonCanonicalEventId` on dirty input and
then truncate to the narrower underlying type. `PositionId` has no validating
constructor — callers wrap raw `uint256` values with the compiler-provided
`PositionId.wrap(...)` directly.

The compiler-provided `ConditionId.wrap(bytes31)` / `EventId.wrap(bytes29)`
constructors are reserved for `src/libraries/Ids.sol` only — that file is the
sole place that constructs UDVTs from raw bit components that are canonical by
construction. The `make wrap-check` CI step enforces this discipline
(`bash/check-wrap-discipline.sh`). `PositionId.wrap` is not gated because there
is no canonicality invariant to protect.

Every storage mapping keyed by a structured ID is typed
(`mapping(ConditionId => …)` or `mapping(EventId => …)`). Because Solidity
UDVTs serialize as their underlying type, 4-byte function selectors, event
topic hashes, storage slot layouts, and ABI calldata encoding are all
unchanged. ERC1155 token IDs and bridge wire payloads stay `uint256` at the
ABI boundary; `PositionId` lives in the gap between external entry and the
inherited ERC1155 / wire-decode boundary, with `PositionId.unwrap` at the
boundary.

This discipline closed an audit finding (#6) where `resolveMigrationCondition`
accepted a non-canonical alias key with a dirty outcome byte, enabling state
corruption that flipped a legacy YES into V2 NO. See
[`docs/migration.md`](migration.md) for the resolution path detail.

## Derivation

```
baseHash    = keccak256(moduleId, data)                          // full 256-bit hash (truncated to 128 on encode)
eventId     = encode(moduleId, baseHash, arity, resolutionChain)
conditionId = encode(moduleId, baseHash, arity, conditionIndex, resolutionChain)
positionId  = conditionId | outcomeIndex
```

Every encoder has two overloads: one taking an explicit `ResolutionChain` and one defaulting to
`ResolutionChain.POLYGON`. Modules pass their `RESOLUTION_CHAIN` immutable explicitly, so generated
IDs always carry the module's configured resolution chain. The event-scoped reserved field is left
at zero by the current encode helpers; it is still part of the event ID, so if future versions
populate it, `ConditionIdLib.eventId()` preserves it.

The moduleId is embedded in all IDs, so any eventId, conditionId, or positionId is self-describing — the module can always be derived via bit extraction without storage lookups.

## Module IDs

| Module                | ID |
|-----------------------|----|
| `BinaryModule`        | 1  |
| `NegRiskModule`       | 2  |
| `CombinatorialModule` | 3  |

Constants live in `src/libraries/ModuleIds.sol` (`BINARY`, `NEGRISK`, `COMBINATORIAL`). The
`CombinatorialModule` encodes its condition IDs with `arity = 0` and `conditionIndex = 0`; the
base hash commits to the canonical leg array (`abi.encode(PositionId[])`).

## Ids.sol API

Source: `src/libraries/Ids.sol` — one file, three internal libraries plus the
UDVT definitions, the operator overloads, and `computeBaseHash`. The split
follows a simple rule: anything that **operates on** or **produces** a typed
ID lives in that ID's library; raw-`uint256` position-ID primitives live in
`PositionIdLib`. Naming convention: `encode*` for raw → typed, `compute*` for
typed → typed with a positional selector, noun-form for typed → projection.

### `ConditionIdLib` (operates on / produces `ConditionId`)

| Function | Description |
|----------|-------------|
| `from(bytes32) → ConditionId` | Validating constructor; reverts on non-canonical input |
| `encode(moduleId, baseHash, arity, conditionIndex[, resolutionChain]) → ConditionId` | Encode from raw bit components; the 4-arg overload defaults to `POLYGON` |
| `encodeFromData(moduleId, conditionIndex, data[, resolutionChain]) → ConditionId` | Encode by hashing `data` into the base hash (`arity = 0`); 3-arg overload defaults to `POLYGON` |
| `moduleId(ConditionId) → uint256` | Top 8 bits |
| `conditionIndex(ConditionId) → uint256` | Condition index within parent event |
| `resolutionChain(ConditionId) → uint256` | Encoded resolution chain enum value |
| `eventId(ConditionId) → EventId` | Derive parent event ID (zero condition + outcome bytes) |
| `isValidEventId(ConditionId) → bool` | True iff the conditionIndex bytes are zero (i.e. the condition is bit-equivalent to its event) |
| `computePositionId(ConditionId, outcomeIndex) → PositionId` | ERC1155 token ID for the (condition, outcome) pair |

### `EventIdLib` (operates on / produces `EventId`)

| Function | Description |
|----------|-------------|
| `from(bytes32) → EventId` | Validating constructor; reverts on non-canonical input |
| `encode(moduleId, baseHash, arity[, resolutionChain]) → EventId` | Encode from raw bit components; the 3-arg overload defaults to `POLYGON` |
| `encodeFromData(moduleId, arity, data[, resolutionChain]) → EventId` | Encode by hashing `data` into the base hash; 3-arg overload defaults to `POLYGON` |
| `moduleId(EventId) → uint256` | Top 8 bits |
| `arity(EventId) → uint256` | Encoded arity |
| `resolutionChain(EventId) → uint256` | Encoded resolution chain enum value |
| `asCondition(EventId) → ConditionId` | Reinterpret as a `ConditionId` (bit-equivalent) |
| `computeConditionId(EventId, conditionIndex) → ConditionId` | Derive the conditionId at a given index |

### `PositionIdLib` (operates on / produces `PositionId`)

| Function | Description |
|----------|-------------|
| `moduleId(PositionId) → uint256` | Top 8 bits |
| `outcomeIndex(PositionId) → uint256` | Bottom 8 bits |
| `conditionId(PositionId) → ConditionId` | Mask off the outcome byte |

`PositionIdLib` has no encoder — position IDs are derived from condition IDs via
`ConditionIdLib.computePositionId(conditionId, outcomeIndex)`. Raw `uint256` values are wrapped
directly via `PositionId.wrap(...)` — no validating constructor is needed because the underlying
type already has full width.

### Free function

| Function | Description |
|----------|-------------|
| `computeBaseHash(moduleId, data) → bytes32` | `keccak256(abi.encode(moduleId, data))` |

## Mappings Removed

The structured ID scheme eliminates four storage mappings:

### PositionManager

| Removed Mapping                                      | Replaced By                                    |
|------------------------------------------------------|------------------------------------------------|
| `mapping(uint256 => address) moduleByPositionId`     | `PositionIdLib.moduleId()` + `moduleById[]`    |
| `mapping(uint256 => bytes32) conditionIdByPositionId`| `PositionIdLib.conditionId()` (pure)           |
| `mapping(address => bool) module`                    | `moduleById[]` (bidirectional)                 |

### NegRiskBaseModule

| Removed Mapping                                      | Replaced By                                    |
|------------------------------------------------------|------------------------------------------------|
| `mapping(bytes32 => bytes32) eventId`                | `ConditionIdLib.eventId()` (pure)              |

## Gas Savings

### Condition Preparation (write path)

The old `prepareCondition` wrote to 2 mappings for every position ID (2 per condition):

| Eliminated SSTORE                                    | Gas per write | Writes per condition |
|------------------------------------------------------|---------------|----------------------|
| `moduleByPositionId[positionId] = module`            | 20,000        | 2 (YES + NO)         |
| `conditionIdByPositionId[positionId] = conditionId`  | 20,000        | 2 (YES + NO)         |

**~80,000 gas saved per condition prepared.**

For NegRisk modules, the `eventId[conditionId] = eventId` mapping is also eliminated:

| Eliminated SSTORE                                    | Gas per write | Writes per condition |
|------------------------------------------------------|---------------|----------------------|
| `eventId[conditionId] = eventId`                     | 20,000        | 1                    |

**~100,000 gas saved per NegRisk condition prepared.** For a NegRisk event with 256 conditions, that is ~25.6M gas eliminated at preparation time.

### Authorization & Routing (read path)

Every operation that previously required storage lookups now uses pure bit extraction (~3 gas vs ~2,100 gas cold SLOAD):

| Eliminated SLOAD                                     | Replaced by                                    | Savings per call |
|------------------------------------------------------|------------------------------------------------|------------------|
| `moduleByPositionId[positionId]`                     | `PositionIdLib.moduleId()` (pure)              | ~2,100           |
| `conditionIdByPositionId[positionId]`                | `PositionIdLib.conditionId()` (pure)           | ~2,100           |
| `eventId[conditionId]`                               | `ConditionIdLib.eventId()` (pure)              | ~2,100           |

These savings compound across every split, merge, redeem, bridge, and authorization check.

### Bridge Path

The bridge previously required 2 SLOADs per position to derive module and conditionId. Now derived purely from bit layout:
- **~4,200 gas saved per position bridged**

The `_moduleId` parameter was also removed from all bridge event functions since moduleId is derivable from the structured eventId.

## Modified Flows

### PositionManager

- **Module registration**: `addModule(address)` reads `moduleId()` from the module. Modules are registered by their self-reported ID, enabling ID-based lookup.
- **Authorization**: `onlyModuleByPositionId` derives the module from the position ID via bit extraction instead of a storage lookup.

### NegRiskModule

- **`getEventId(conditionCount, data)`**: Pure derivation — returns the structured eventId `[moduleId | baseHash | arity | reserved | resolutionChain | 0 | 0]` with the module's `RESOLUTION_CHAIN`. Native events need no preparation or storage: the arity is embedded in the ID, and `conditionCount(eventId)` decodes it.
- **`reportResult`**: Derives the eventId via `conditionId.eventId()` for neg-risk state lookups (`resultsSum`, `conditionsResolved`).
- **`horizontalSplit` / `horizontalMerge`**: Use the structured eventId directly as the mapping key.

### Migration (BinaryModule / NegRiskModule)

- **`prepareMigrationCondition`** (binary): Stores the legacy CTF condition ID under the structured V2 condition ID (whose base hash is the legacy condition ID itself) and emits `MigrationConditionRegistered(v2ConditionId, legacyConditionId)` so the mapping is recoverable from logs.
- **`prepareMigrationEvent`** (neg-risk): Constructs a structured eventId from the legacy hash, stores `legacyEventId[structuredEventId]` once per event, and emits `EventPrepared(structuredEventId, conditionCount, legacyEventId)` so the legacy-to-structured event mapping is recoverable from logs.

### CombinatorialModule

- **`getConditionId(legs)`**: Pure derivation — hashes the canonical leg array into the base hash (`arity = 0`, `conditionIndex = 0`).
- **`prepareCondition(legs)` / `_storeLegsFromMemory`**: Store the canonical leg array under the derived condition ID; unlike binary/neg-risk conditions, combinatorial operations need the stored `legs[conditionId]` array to reconstruct leg sets.

### Bridge (BridgeBase / CcipBridge)

- **`bridgePositions`**: Derives `moduleId` and `conditionId` from position IDs via the `PositionId` library instead of storage reads. Combinatorial positions (`moduleId = 3`) are rejected explicitly.
- **`_handlePositionsReceive`**: Derives `moduleId` from position IDs and mints supported binary/neg-risk positions directly — no condition preparation needed. Combinatorial positions are rejected before module lookup or minting.

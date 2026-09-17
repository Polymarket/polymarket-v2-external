# Router

Source: `src/routers/Router.sol`, `src/routers/BridgeRouter.sol`, `src/routers/CtfRouter.sol`

Routers provide user-facing entry points for interacting with the PositionManager and its modules by bundling pre-transfer and module-call.

All three routers are UUPS-upgradeable proxies (implementation + ERC1967 proxy). Their implementations call `_disableInitializers()` in the constructor; proxies are initialized once via `initialize(address _owner)`. The owner authorizes upgrades through `_authorizeUpgrade` (`onlyOwner`). Immutables (`POSITION_MANAGER`, `COLLATERAL_TOKEN`, `BRIDGE`) live in the implementation bytecode, so each implementation deployment is parameterized for one set of dependencies. Use `RouterSetup` in `src/routers/dev/RouterSetup.sol` to deploy a router behind a proxy in tests and scripts.

## Router

The primary entry point for all PositionManager operations. Uses the [pre-transfer pattern](architecture.md#pre-transfer-pattern): pre-transfers tokens to the module, then invokes the module operation directly.

The Router has no business state — no allowlists, no transient storage. It resolves modules from condition IDs via `conditionId.moduleId()` (`ConditionIdLib.moduleId`); the combinatorial wrappers instead resolve the registered module via `moduleById(ModuleIds.COMBINATORIAL)`. The only storage it reserves is a `uint256[50] __gap` so downstream inheritors (`BridgeRouter`) can add their own state without colliding with future `Router` additions.

Users only need to approve the Router (for both collateral and positions).

### Split / Merge / Redeem

| Function | Description |
|----------|-------------|
| `split(conditionId, amount)` | Transfers collateral to module, calls `module.split` |
| `merge(conditionId, amount)` | Transfers YES + NO positions to module via two `unsafeTransferFrom` calls, calls `module.merge` |
| `redeem(conditionId, outcomeIndex, amount)` | Transfers position to module, calls `module.redeem` |

### NegRisk Horizontal Operations

| Function | Description |
|----------|-------------|
| `horizontalSplit(eventId, amount)` | Transfers collateral to module, mints one YES position per real condition plus the synthetic Other |
| `horizontalMerge(eventId, amount)` | Transfers YES positions (real conditions plus synthetic Other) to module, burns them, mints collateral |
| `convert(eventId, conditionIndex, amount)` | Transfers NO position to module, converts to YES positions for all other conditions. Valid `conditionIndex` is `[0, conditionCount(eventId)]` where `conditionCount` is the Other index. `conditionIndex` is `uint16` to mirror the 16-bit `conditionIndex` field in position IDs. |

The module is derived from the `eventId` via `eventId.moduleId()` (`EventIdLib.moduleId`) — no module address parameter is needed.

### Convert

`convert` leverages the identity: 1 NO(i) = all YES(j) for j!=i, including the synthetic Other at index `eventId.arity()`. The Router transfers the caller's NO position to the module, then calls `NegRiskModule.convert` which burns the NO and mints YES positions for every other condition. No collateral movement is needed.

### Combinatorial Operations

Wrappers around every [CombinatorialModule](modules.md#combinatorialmodule-moduleid--3) operation. The module is resolved from the PositionManager registry via `moduleById(ModuleIds.COMBINATORIAL)`; the wrappers revert `CombinatorialModuleNotConfigured` if no combinatorial module is registered. All outputs go to the caller.

| Function | Description |
|----------|-------------|
| `splitOnCondition(parentYesPositionId, conditionId, amount)` | Transfers the parent YES position to the module, splits on a new condition |
| `mergeOnCondition(parentYesPositionId, conditionId, amount)` | Computes and transfers both child YES positions, merges them into the parent |
| `splitOnEvent(parentYesPositionId, eventId, amount)` | Transfers the parent, splits across every neg-risk event outcome (incl. Other) |
| `mergeOnEvent(parentYesPositionId, eventId, amount)` | Computes and transfers all event children, merges them into the parent |
| `convertOnEvent(parentYesPositionId, conditionIndex, amount)` | Transfers the parent, expands its neg-risk NO leg into every other outcome |
| `extract(fullNoPositionId, conditionIndex, amount)` | Transfers the NO position, extracts one leg |
| `inject(fullNoPositionId, conditionIndex, amount)` | Computes and transfers the reduced-NO + residual-YES inputs, reconstructs the full NO |
| `convertToYesBasket(fullNoPositionId, amount)` | Transfers the NO position, converts it to the canonical YES basket |
| `mergeFromYesBasket(fullNoPositionId, amount)` | Computes and transfers the basket positions, reconstructs the NO |
| `compress(positionId, amount)` | Transfers the position, strips resolved legs |
| `wrap(underlyingPositionId, amount)` / `unwrap(positionId, amount)` | Underlying binary/neg-risk position ⇄ single-leg combinatorial position |

For merge-shaped operations the Router derives the input position IDs from the module's stored leg arrays (`getLegs`), inserting/removing/flipping legs with the same canonical ordering the module uses — callers never supply derived IDs.

### Combinatorial Collateral Return

**`combinatorialCollateralReturn(transfers, operations)`** executes a complete multi-step combinatorial sequence in one call:

1. Validates the inputs before any transfer: `operations` must be non-empty and the `transfers.positionIds` / `positionAmounts` lengths must match (`InvalidCombinatorialReturnOperation`).
2. Transfers the aggregate inputs to the CombinatorialModule: `transfers.collateralAmount` of collateral plus the `transfers.positionIds` / `positionAmounts` batch.
3. Executes each ABI-encoded call in `operations` against the module in order, bubbling up the revert data of any failed call.
4. Emits `CombinatorialCollateralReturned(initiator, operationCount)`.

The call target is fixed to the registered CombinatorialModule — the Router forwards arbitrary selectors, but only to that module. An off-chain collateral-return engine computes the operation sequence; the caller must size the up-front transfers so each step's pre-transfer requirement is covered by the module's running balance.

## BridgeRouter

Source: `src/routers/BridgeRouter.sol`

Extends `Router` with cross-chain position and collateral bridging. Transfers assets to the bridge contract, then calls `IBridge` functions directly.

**Immutable:** `BRIDGE` — address of the bridge contract (the `IBridge` implementation, currently `CcipBridge`).

**Constructor:** `BridgeRouter(positionManager, bridge)` — inherits Router's PositionManager setup.

### Bridge Operations

| Function | Description |
|----------|-------------|
| `bridgePositions(dstChain, positionIds, amounts, options)` | Bridge positions with `msg.sender` as recipient |
| `bridgePositionsTo(dstChain, positionIds, amounts, recipient, options)` | Bridge positions with explicit `bytes32` recipient (non-EVM support) |
| `bridgeCollateral(dstChain, amount, options)` | Bridge collateral with `msg.sender` as recipient |
| `bridgeCollateralTo(dstChain, amount, recipient, options)` | Bridge collateral with explicit `bytes32` recipient |

All are `payable` (messaging fees paid in native gas). The `To` variants accept a `bytes32 _recipient` for non-EVM destinations.

Internally, `_bridgePositions` transfers positions from the user to the bridge via `unsafeBatchTransferFrom`, then calls `IBridge.bridgePositions`. `_bridgeCollateral` transfers collateral via `safeTransferFrom`, then calls `IBridge.bridgeCollateral`.

## CtfRouter

Source: `src/routers/CtfRouter.sol`

Backwards-compatible router matching the legacy ConditionalTokens interface. Allows existing contracts to interact with the PositionManager without modification.

| Function | Legacy CTF Signature | Behavior |
|----------|---------------------|----------|
| `splitPosition(collateralToken, parentCollectionId, conditionId, partition, amount)` | Matches CTF | Ignores collateralToken, parentCollectionId, and partition; splits via the module |
| `mergePositions(collateralToken, parentCollectionId, conditionId, partition, amount)` | Matches CTF | Ignores collateralToken, parentCollectionId, and partition; merges via the module |
| `redeemPositions(collateralToken, parentCollectionId, conditionId, indexSets)` | Matches CTF | Iterates index sets (1=YES, 2=NO), redeems full balance |

The CtfRouter requires approval for both collateral token and PositionManager positions.

## AutoRedeemer

Source: `src/utils/AutoRedeemer.sol`

Utility contract (UUPS proxy) that redeems resolved positions on behalf of users. Users must approve the AutoRedeemer for their PositionManager positions (or legacy ConditionalTokens positions for the legacy variants).

- **`redeem(froms[], positionIds[])`** (`onlyOperator`) — for each entry, transfers the user's full position balance to the module via `unsafeTransferFrom`, then calls `module.redeem` with the pre-transfer pattern; users without approval (or with zero balance) are skipped. Payouts are received by the AutoRedeemer and forwarded to the user in the same transaction.
- **`redeemBinary(froms[], conditionIds[])` / `redeemNegRisk(froms[], conditionIds[])`** (`onlyOperator`) — batch-redeem legacy binary CTF / neg-risk positions (require ConditionalTokens approval) and wrap the USDCe payout into pUSD for the user via the CollateralOnramp.

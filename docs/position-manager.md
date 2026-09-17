# Position Manager

Source: `src/positionManager/PositionManager.sol`

The PositionManager is the central ERC1155 contract for all prediction market positions. It holds no market logic itself — all condition management, result reporting, and settlement are delegated to registered [modules](modules.md).

## Module Registration

Modules are registered and looked up by their `moduleId`:

- **`addModule(module)`** (`onlyAdmin`) — reads `moduleId()` from the module contract and registers it in `moduleById[moduleId]`
- **`removeModule(moduleId)`** (`onlyAdmin`) — unregisters the module

The `onlyModuleByPositionId` modifier derives the module from a position ID's top 8 bits and verifies `moduleById[moduleId] == msg.sender`. This allows any position ID to self-describe which module governs it.

## Cross-Module Authorization

By default, modules can only mint/burn their own positions. Admin can grant cross-module authorization to allow a module to mint/burn positions belonging to any module:

- **`setCrossModuleAuth(module, authorized)`** (`onlyAdmin`) — sets `crossModuleAuth[module]`
- **`crossModuleAuth(module)`** — returns whether the module has cross-module authorization

This is granted to the `CombinatorialModule` so `wrap`/`unwrap` can burn and mint the underlying binary/neg-risk positions.

The authorization check is lazy: the same-module fast path (`moduleById[moduleId] == msg.sender`) is checked first. `crossModuleAuth` is only read on mismatch, adding zero gas overhead for existing modules.

## ERC1155 Operations

Mint and burn are restricted to the owning module or a cross-module-authorized module:

| Function | Access | Description |
|----------|--------|-------------|
| `mint(to, positionId, amount)` | `onlyModuleByPositionId` | Mint a single position |
| `batchMint(to, positionIds, amounts)` | `onlyModuleByPositionIds` | Mint multiple positions |
| `burn(positionId, amount)` | `onlyModuleByPositionId` | Burn from caller (the module) |
| `batchBurn(positionIds, amounts)` | `onlyModuleByPositionIds` | Batch burn from caller |

## Unsafe Transfers

Two transfer functions skip the ERC1155 receiver callback (`onERC1155Received` / `onERC1155BatchReceived`) for gas savings:

- **`unsafeTransferFrom(from, to, id, amount)`** — single transfer, no receiver callback
- **`unsafeBatchTransferFrom(from, to, ids, amounts)`** — batch transfer, no receiver callback

Both still enforce the standard approval check (`msg.sender == from || isApprovedForAll`). These are used internally by the Router and Exchange to transfer positions to modules without triggering callback overhead.

## View Functions

| Function | Description |
|----------|-------------|
| `balanceOf(owner, conditionId, outcomeIndex)` | Convenience overload — computes position ID from condition + outcome |
| `getPayout(positionId, amount)` | Delegates to the position's module |

## Upgradeability

PositionManager uses the UUPS proxy pattern:

- **`initialize(owner, admin)`** — sets the contract owner and grants admin role (`_ROLE_0`) to `admin`
- **`_authorizeUpgrade(newImplementation)`** — restricted to `onlyOwner`

Inherits `InitializableRoles` for role management (see [Auth](auth.md)).

## Immutables

| Variable | Description |
|----------|-------------|
| `COLLATERAL_TOKEN` | Address of the [CollateralToken](collateral.md) (PMCT) |

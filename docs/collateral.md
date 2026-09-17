# Collateral

## CollateralToken (PMCT)

Source: `src/collateral/CollateralToken.sol`

The Polymarket Collateral Token (PMCT) is an ERC20 token that wraps USDC and USDCe 1:1 via an external vault. It serves as the single collateral asset for all modules.

**Immutables:** `usdc`, `usdce`, `vault`

**Token metadata:** name = `Polymarket USD`, symbol = `pUSD`, decimals = `6`

### Roles

| Role | Constant | Holders | Capabilities |
|------|----------|---------|-------------|
| Minter | `MINTER_ROLE` (`_ROLE_0`) | Modules, Bridge | `mint`, `burn` |
| Wrapper | `WRAPPER_ROLE` (`_ROLE_1`) | Onramp, Offramp | `wrap`, `unwrap` |

Role management: `addMinter` / `removeMinter`, `addWrapper` / `removeWrapper` — all `onlyOwner`.

### Mint / Burn

- **`mint(to, amount)`** (`onlyRoles(MINTER_ROLE)`) — mints PMCT to `to`
- **`burn(amount)`** (`onlyRoles(MINTER_ROLE)`) — burns PMCT from `msg.sender`

Used by modules during split (burn collateral) and merge/redeem (mint collateral), and by the bridge for cross-chain collateral transfers.

### Wrap / Unwrap

- **`wrap(asset, to, amount)`** (`onlyRoles(WRAPPER_ROLE)`) — mints PMCT to `to`, then transfers the asset from `address(this)` to the vault. The asset must be pre-transferred to the CollateralToken contract before calling.
- **`unwrap(asset, to, amount)`** (`onlyRoles(WRAPPER_ROLE)`) — transfers the asset from the vault to `to`, then burns PMCT from `address(this)`. PMCT must be pre-transferred to the CollateralToken contract before calling.

Assets must be `usdc` or `usdce` (enforced by `onlyValidAsset` modifier).

### Legacy Wrap / Unwrap Overloads (deployed-ramp compatibility)

Five-argument overloads retained for backwards compatibility with the ramps and CTF collateral adapters already deployed from `ctf-exchange-v2`, which call these selectors:

- **`wrap(asset, to, amount, callbackReceiver, data)`** (`onlyRoles(WRAPPER_ROLE)`)
- **`unwrap(asset, to, amount, callbackReceiver, data)`** (`onlyRoles(WRAPPER_ROLE)`)

The trailing `callbackReceiver` and `data` parameters are the legacy callback arguments of the previously deployed implementation. They are **accepted for ABI compatibility but ignored — no callback is ever invoked**. Every deployed caller passes `address(0)` (verified on-chain against the full WRAPPER_ROLE holder set), so this is behaviorally identical for all existing integrations while removing the external-call surface from the wrap/unwrap paths.

Both overloads behave exactly like their three-argument counterparts: funds must be pre-transferred to the CollateralToken before calling. All four external functions share the internal `_wrap` / `_unwrap` implementations.

### Rescue

- **`rescue(assets[], tos[], amounts[])`** (`onlyOwner`) — batch-transfers stuck ERC20 balances held by the CollateralToken contract: for each entry `i`, transfers `amounts[i]` of `assets[i]` to `tos[i]` and emits a `Rescued` event. The three arrays must be the same length (`ArrayLengthMismatch` otherwise), and the batch is atomic — if any transfer fails the whole rescue reverts.

The CollateralToken contract is not meant to hold balances outside of a wrap/unwrap transaction, so any lingering balance is stuck (e.g. tokens transferred directly to the contract, or PMCT sent without a matching `unwrap`). The assets are deliberately unrestricted — the owner already controls upgrades, so limiting rescuable assets adds no security.

### Backing Invariant

`usdc.balanceOf(vault) + usdce.balanceOf(vault) >= totalSupply()`

All PMCT is backed 1:1 by USDC or USDCe held in the vault.

### Upgradeability

UUPS proxy pattern. `initialize(owner)` sets the contract owner. `_authorizeUpgrade` restricted to `onlyOwner`.

## CollateralOnramp

Source: `src/collateral/CollateralOnramp.sol`

Permissionless entry point for wrapping USDC/USDCe into PMCT.

- **`wrap(asset, to, amount)`** — transfers the asset from `msg.sender` to the CollateralToken, then calls `CollateralToken.wrap` 
- Per-asset pause: `pause(asset)` / `unpause(asset)` (`onlyAdmin`)

## CollateralOfframp

Source: `src/collateral/CollateralOfframp.sol`

Permissionless entry point for unwrapping PMCT back to USDC/USDCe.

- **`unwrap(asset, to, amount)`** — transfers PMCT from `msg.sender` to the CollateralToken, then calls `CollateralToken.unwrap` 
- Per-asset pause: `pause(asset)` / `unpause(asset)` (`onlyAdmin`)

## PermissionedRamp

Source: `src/collateral/PermissionedRamp.sol`

EIP-712 witness-gated wrap/unwrap. Every wrap or unwrap requires a co-signature from an authorized witness, enabling permissioned access control over collateral operations.

**EIP-712 domain:** name = `"PermissionedRamp"`, version = `"1"`

### Roles

| Role | Constant | Capabilities |
|------|----------|-------------|
| Admin | `ADMIN_ROLE` (`_ROLE_0`) | Manage admins, manage witnesses, pause/unpause |
| Witness | `WITNESS_ROLE` (`_ROLE_1`) | Co-sign wrap/unwrap operations |

### Functions

| Function | Description |
|----------|-------------|
| `wrap(asset, to, amount, nonce, deadline, signature)` | Validates witness EIP-712 signature, transfers asset from `msg.sender` to CollateralToken, calls `CollateralToken.wrap`  |
| `unwrap(asset, to, amount, nonce, deadline, signature)` | Same pattern — validates witness signature, unwraps PMCT back to the underlying asset |

### Replay Protection

Sequential nonces per sender (`nonces[msg.sender]`). The provided nonce must match the current value and increments atomically on use.

### Deadline Validation

`block.timestamp <= deadline` is enforced. The witness signature covers the deadline, preventing stale signatures from being replayed.

### Signature Validation

The witness signature is an EIP-712 typed signature over a `Wrap` or `Unwrap` struct containing `(sender, asset, to, amount, nonce, deadline)`. The recovered signer must hold the `WITNESS_ROLE`.

### Admin Management

| Function | Access | Description |
|----------|--------|-------------|
| `addAdmin(addr)` / `removeAdmin(addr)` | `onlyRoles(ADMIN_ROLE)` | Manage admin role |
| `addWitness(addr)` / `removeWitness(addr)` | `onlyRoles(ADMIN_ROLE)` | Manage witness role |

### Per-asset Pause

Inherited from `Pausable` mixin (same as Onramp/Offramp). `pause(asset)` / `unpause(asset)` by admin.

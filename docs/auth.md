# Auth

## Roles

Source: `src/auth/Roles.sol`

Non-upgradeable role contract inheriting Solady's `OwnableRoles`, with a constructor that sets the owner. Kept for non-proxy deployments; no production contract currently inherits it — the proxied contracts use [`InitializableRoles`](#initializableroles), and the Exchange, CollateralToken, CcipBridge, and OracleAggregator define their own roles.

| Role | Constant | Purpose |
|------|----------|---------|
| Admin | `_ROLE_0` | Manages all other roles; pause controls |
| Operator | `_ROLE_1` | Batch migration on behalf of users |
| Creator | `_ROLE_2` | Prepare migration conditions and events |
| Bridge | `_ROLE_3` | Cross-chain mint/burn and result relay |
| Resolver | `_ROLE_4` | Result reporting (e.g. an oracle aggregator) |

### Role Management

| Function | Access | Description |
|----------|--------|-------------|
| `addAdmin(addr)` | `onlyOwner` | Grant admin role |
| `removeAdmin(addr)` | `onlyAdmin` | Revoke admin role |
| `addOperator(addr)` / `removeOperator(addr)` | `onlyAdmin` | Grant/revoke operator |
| `addCreator(addr)` / `removeCreator(addr)` | `onlyAdmin` | Grant/revoke creator |
| `addBridge(addr)` / `removeBridge(addr)` | `onlyAdmin` | Grant/revoke bridge |
| `addResolver(addr)` / `removeResolver(addr)` | `onlyAdmin` | Grant/revoke resolver |

Constructor: `constructor(address _owner)` — initializes the owner.

## InitializableRoles

Source: `src/auth/InitializableRoles.sol`

Upgradeable variant of `Roles` — no constructor (designed for use with UUPS / `Initializable`).
Used by `PositionManager`, `BinaryModule`, `NegRiskModule` (via the `OracleModule` mixin),
`CombinatorialModule`, and `AutoRedeemer`.

| Role | Constant | Purpose |
|------|----------|---------|
| Admin | `_ROLE_0` | Module registration, role management, pause controls |
| Operator | `_ROLE_1` | Operator-gated functions (e.g. batch migration) |
| Creator | `_ROLE_2` | Migration condition/event preparation |
| Bridge | `_ROLE_3` | Cross-chain mint/burn and result relay |
| Resolver | `_ROLE_4` | Result reporting; granted to the OracleAggregator via `addResolver` |

Initial admin(s) are granted in the inheriting contract's initializer. `InitializableRoles` itself
defines admin/operator/creator management (`addAdmin` is `onlyOwner`; the rest are `onlyAdmin`).
Bridge and resolver management live on the inheriting contracts: `OracleModule` (inherited by
`BinaryModule` / `NegRiskModule`) defines `addBridge` / `removeBridge` and `addResolver` /
`removeResolver`, and `CombinatorialModule` defines `addBridge` / `removeBridge` — all `onlyAdmin`.

## CollateralToken Roles

The [CollateralToken](collateral.md) defines its own roles via Solady's `OwnableRoles`:

| Role | Constant | Holders | Capabilities |
|------|----------|---------|-------------|
| Minter | `MINTER_ROLE` (`_ROLE_0`) | Modules, Bridge | `mint`, `burn` |
| Wrapper | `WRAPPER_ROLE` (`_ROLE_1`) | Onramp, Offramp | `wrap`, `unwrap` |

Managed via `addMinter` / `removeMinter`, `addWrapper` / `removeWrapper` — all `onlyOwner`.

## Exchange Roles

The [Exchange](exchange.md) defines its own roles via Solady's `OwnableRoles` and is initialized behind a UUPS proxy (not the shared `Roles` contract):

| Role | Constant | Capabilities |
|------|----------|-------------|
| Admin | `ADMIN_ROLE` (`_ROLE_0`) | Manage operators, pause/unpause trading, set fee receiver, set max fee rate, pause/unpause users |
| Operator | `OPERATOR_ROLE` (`_ROLE_1`) | Match orders, pre-approve/invalidate orders |

Initialized via `initialize(owner, admin, feeReceiver)`. Managed thereafter via `addAdmin` / `removeAdmin` (`onlyOwner`), `addOperator` / `removeOperator` (`onlyRoles(ADMIN_ROLE)`).

## OracleAggregator Roles

The [OracleAggregator](oracle.md) uses its own `Auth` mixin (`src/oracle/mixins/Auth.sol`) plus a
locally-defined `RULE_MANAGER_ROLE`, not the shared `Roles` contract:

| Role | Constant | Capabilities |
|------|----------|-------------|
| Admin | `_ROLE_0` | `removeAdmin`, `addOperator`/`removeOperator`, `addRuleManager`/`removeRuleManager`, `pause`/`unpause`, `resolveResult`, plus all operator actions except `initializeRequest`, and all rule-manager actions |
| Operator | `_ROLE_1` | `initializeRequest`, per-event config edits (add/remove reporter & disputer modules, `setArbitratorModule`, `setFinalizer`, `setLivenessWindow`), `updateRequestRules`, and `pauseMarkets`/`unpauseMarkets` |
| Rule Manager | `RULE_MANAGER_ROLE` (`_ROLE_2`) | Add/edit product specifications via the `MarketDataRegistry` mixin (`setProductSpecification`). Per-request rule updates are owned by the Operator via `updateRequestRules` |

Managed via `addAdmin` (`onlyOwner`), `removeAdmin` (`onlyAdmin`), `addOperator` / `removeOperator`
(`onlyAdmin`), `addRuleManager` / `removeRuleManager` (`onlyAdmin`). Operator actions other than
`initializeRequest` are gated by `onlyOperatorOrAdmin`, and rule-manager actions by a
rule-manager-or-admin check, so an admin can perform them without separately holding the role;
`initializeRequest` itself is strictly `onlyOperator`. The operator absorbs the former market-manager
duties — it can edit a request's modules/arbitrator/finalizer/liveness, update rules, and pause
markets. A request's `targetContract`, `marketType`, `resultLength`, and thresholds have no setters
and are immutable after `initializeRequest`. Note that module edits make the operator a **fully
trusted role** (all operators are run by Polymarket): because `resolveResult` accepts calls from the
configured arbitrator at any point before resolution, an operator can point `setArbitratorModule` at
an address it controls and resolve any market directly, and swapping reporter modules similarly
redirects who can vote. There is no structural guarantee that the operator cannot affect resolution
state. The rule manager can only publish product specs.

## Bridge Roles

### CcipBridge

The only bridge transport in the tree. Uses Solady's `OwnableRoles` behind a UUPS proxy.
`initialize(owner, admin)` sets the owner and grants the initial admin role:

| Role | Constant | Capabilities |
|------|----------|-------------|
| Owner | — | `setPeer`, `removePeer`, `setModuleSupported`, `setBatchModuleSupported`, `addAdmin`, `removeAdmin`, UUPS upgrade |
| Admin | `ADMIN_ROLE` (`_ROLE_0`) | `pauseSend`/`unpauseSend`, `pauseReceive`/`unpauseReceive` |

## AutoRedeemer Roles

Source: `src/utils/AutoRedeemer.sol`

UUPS proxy inheriting `InitializableRoles` (`src/auth/InitializableRoles.sol`); `initialize(owner, admin)`
sets the proxied owner (upgrade authority) and initial admin (role management):

| Role | Capabilities |
|------|-------------|
| Operator (`_ROLE_1`) | `redeem` / `redeemBinary` / `redeemNegRisk` batch redemption on behalf of users |

## Role Assignment Summary

| Contract | Admin | Operator | Creator | Bridge | Resolver | Minter | Wrapper |
|----------|-------|----------|---------|--------|----------|--------|---------|
| PositionManager | Module registration, cross-module auth | — | — | — | — | — | — |
| BinaryModule | Role management, resolver/resolution pause | Batch migration | Prepare migration conditions | Relay results, mint/burn from bridge | Report results | — | — |
| NegRiskModule | Role management, resolver/resolution pause | Batch migration | Prepare migration events | Relay results (incl. synthetic Other), mint/burn from bridge | Report results (real conditions) | — | — |
| CombinatorialModule | Bridge role management | — | — | Mint/burn from bridge | — | — | — |
| CollateralToken | — | — | — | — | — | Mint/burn PMCT | Wrap/unwrap |
| Exchange | Manage operators, pause, fees | Match orders | — | — | — | — | — |
| OracleAggregator | Manage operators/managers, pause, resolve | Initialize requests, edit request config, pause markets | — | — | — | — | — |
| CcipBridge | Pause send/receive | — | — | — | — | — | — |
| AutoRedeemer | — | Redeem on behalf | — | — | — | — | — |

# Architecture

## Overview

Polymarket V2 is a modular ERC1155-based prediction market platform. The `PositionManager` contract is the central token ledger — it holds no market logic itself, delegating all condition management, result reporting, and settlement to registered **modules**. Each module type (binary, neg-risk, combinatorial) implements its own market semantics while sharing the same position token and collateral infrastructure.

## Contract Relationships

```
                         ┌──────────────┐
                         │PositionManager│  (ERC1155, UUPS)
                         │  moduleById[] │
                         └──────┬───────┘
                                │ registers
                ┌───────────────┼───────────────────┐
                │               │                   │
         ┌──────▼──────┐ ┌─────▼──────┐  ┌─────────▼─────────┐
         │BinaryModule │ │NegRiskModule│  │CombinatorialModule│
         │  moduleId=1 │ │  moduleId=2 │  │     moduleId=3    │
         └──────┬──────┘ └─────┬──────┘  └─────────┬─────────┘
                │               │                   │
                └───────────────┼───────────────────┘
                                │ mint/burn collateral
                ┌───────▼────────┐
                │CollateralToken │  (ERC20, UUPS, "PMCT")
                │  USDC/USDCe   │
                └───────┬────────┘
                   wrap │ unwrap
         ┌──────────┬───┴───┬──────────┐
  ┌──────▼──────┐  ─▼─             ┌──▼──────────-┐
  │CollateralOn-│  Permissioned    │CollateralOff-│
  │    ramp     │  ramp            │    ramp      │
  └─────────────┘                  └──────────────┘
                   


                    ┌─────────────────┐
                    │OracleAggregator │  (UUPS, singleton)
                    │reporter/disputer│
                    │  /arbitrator    │
                    └────────┬────────┘
                             │ reportResult
                    ┌────────▼────────┐
                    │ BinaryModule /  │
                    │ NegRiskModule   │
                    └─────────────────┘



         ┌────────────┐
         │  Exchange   │  (EIP-712, UUPS)
         └────────────┘



  ┌────────┐  ┌────────────┐
  │ Router │──│BridgeRouter│
  └────────┘  └─────┬──────┘
                    │
         ┌──────────▼──────────┐
         │     BridgeBase      │  (abstract)
         ├─────────────────────┤
         │     CcipBridge      │
         └─────────────────────┘
```

**Routers** (`Router`, `BridgeRouter`, `CtfRouter`) provide user-facing entry points that handle token transfers; the `Router` also wraps every `CombinatorialModule` operation and exposes the batched `combinatorialCollateralReturn` flow. The **OracleAggregator** manages result reporting and resolution, calling modules directly via `IBinaryReporter.reportResult()` (it holds the resolver role on the target modules). The **Exchange** handles order matching. The bridge layer (`CcipBridge` for Chainlink CCIP) provides cross-chain position, collateral, and result transfers via the transport-agnostic `BridgeBase` abstract contract. The `BridgeRouter` wraps bridge calls for EOA use by pre-transferring assets to the bridge before invoking it.

## Design Patterns

### Module-based architecture

`PositionManager` delegates all market logic to modules. Each module self-reports a `moduleId()` (1 = Binary, 2 = NegRisk, 3 = Combinatorial). When an operation targets a position, the module is resolved from the position ID's top 8 bits via `moduleById[moduleId]` — a single SLOAD replacing what used to be per-position storage lookups.

See [Modules](modules.md) for details.

### Pre-transfer pattern

Core operations (split, merge, redeem, wrap, unwrap, bridge) require the caller to transfer input tokens to the target contract **before** invoking the operation. Each entry point burns/mints output tokens directly against its own balance — no callback hooks, no allowance pulls.

This means every flow is two on-chain calls: `transfer(target, amount)` followed by `target.op(...)`. The `Router`/`BridgeRouter`/`CtfRouter` bundle these into a single user-facing call per operation, so EOAs only need to approve the router. The routers carry no business state — no allowlists, no transient storage — beyond the Solady ownership/upgrade slots and a reserved `__gap`.

See [Router](router.md) for details.

### Canonical ID discipline

Structured identifiers are typed at the language level: `ConditionId` and `EventId` are Solidity user-defined value types defined in `src/libraries/Ids.sol`. The only sanctioned `bytes32 → UDVT` conversion is via the validating constructors `ConditionIdLib.from` / `EventIdLib.from`, which revert on non-canonical input. External entry points either take the typed value directly (the strict ABI decoder rejects dirty low bytes) or accept raw `bytes32` and validate at line 1 via `from`; every storage mapping keyed by a structured ID is typed (`mapping(ConditionId => …)`, etc.). The compiler-provided `.wrap` is reserved for `Ids.sol` only and enforced via `make wrap-check` in CI. See [Position IDs](position-ids.md) for the bit layout and invariants.

### UUPS upgradeability

`PositionManager`, `CollateralToken`, `BinaryModule`, `NegRiskModule`, `CombinatorialModule`, `OracleAggregator`, `Exchange`, `Router`, `BridgeRouter`, `CtfRouter`, `CcipBridge`, and `AutoRedeemer` use the UUPS proxy pattern (ERC-1967). All are initialized via `initialize()` and restrict upgrades to the contract owner via `_authorizeUpgrade`.

The modules, routers, and CcipBridge keep their external dependency references as constructor-set immutables on the implementation, so each proxy is paired with a dedicated implementation. The modules' `_authorizeUpgrade` enforces immutable-pin compatibility by reverting `IncompatibleImplementation` on mismatch; the routers' and CcipBridge's `_authorizeUpgrade` hooks are owner-only with no compatibility check, so an owner can intentionally re-point the proxy to an implementation pinning different dependency addresses.

## Further Reading

- [Position IDs](position-ids.md) — structured ID schema and library
- [Modules](modules.md) — BinaryModule, NegRiskModule, CombinatorialModule, abstract hierarchy
- [Position Manager](position-manager.md) — core ERC1155 contract
- [Collateral](collateral.md) — CollateralToken, onramp, offramp, PermissionedRamp
- [Oracle](oracle.md) — OracleAggregator, modular resolution system
- [Bridge](bridge.md) — cross-chain bridging (Chainlink CCIP)
- [Auth](auth.md) — roles and access control
- [Router](router.md) — Router, BridgeRouter, and CtfRouter
- [Exchange](exchange.md) — order matching
- [Migration](migration.md) — legacy position migration

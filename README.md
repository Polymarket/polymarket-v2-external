# Polymarket V2

Polymarket's next-generation prediction market smart contract system. Manages position tokens (ERC1155), collateral wrapping/unwrapping, market resolution via modular oracles, order matching, and cross-chain bridging. Built with Foundry and Solady.

Positions are represented as structured IDs that encode module routing, condition identity, and outcome index directly in the token ID — eliminating storage lookups and enabling pure derivation of all relationships.

## Position ID Layout

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

See [Position IDs](docs/position-ids.md) for the full spec, library API, gas analysis, and migration details.

## Deployed Contracts

<details>
<summary><strong>Polygon</strong></summary>

| Contract | Address |
|----------|---------|
| [PositionManager](src/positionManager/PositionManager.sol) (proxy) | [`0x006F54F7f9A22e0000CC2AB60031000000ae9fEF`](https://polygonscan.com/address/0x006F54F7f9A22e0000CC2AB60031000000ae9fEF) |
| [PositionManager](src/positionManager/PositionManager.sol) (impl) | [`0x30c038F0Dae8dcC3E6AD51D016F50821D32Cb87e`](https://polygonscan.com/address/0x30c038F0Dae8dcC3E6AD51D016F50821D32Cb87e) |
| [Exchange](src/exchange/Exchange.sol) (proxy) | [`0xe3333700cA9d93003F00f0F71f8515005F6c00Aa`](https://polygonscan.com/address/0xe3333700cA9d93003F00f0F71f8515005F6c00Aa) |
| [Exchange](src/exchange/Exchange.sol) (impl) | [`0x7345C6842b244926125ed4054905cAc49620B5dc`](https://polygonscan.com/address/0x7345C6842b244926125ed4054905cAc49620B5dc) |
| [Router](src/routers/Router.sol) (proxy) | [`0x12121212006e4CD160D18e3f00711DA5c3372600`](https://polygonscan.com/address/0x12121212006e4CD160D18e3f00711DA5c3372600) |
| [Router](src/routers/Router.sol) (impl) | [`0x6C405dA46fdC4172239E5053189b6577e290E62f`](https://polygonscan.com/address/0x6C405dA46fdC4172239E5053189b6577e290E62f) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (proxy) | [`0xa1200000d0002264C9a1698e001292D00E1b00af`](https://polygonscan.com/address/0xa1200000d0002264C9a1698e001292D00E1b00af) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (impl) | [`0x64860bFD14fCcaAc09cd36f347784a9616AfB66C`](https://polygonscan.com/address/0x64860bFD14fCcaAc09cd36f347784a9616AfB66C) |
| [BinaryModule](src/modules/BinaryModule.sol) (proxy) | [`0x1000008dD9001B968442c1000017eaE6E0dA00Ba`](https://polygonscan.com/address/0x1000008dD9001B968442c1000017eaE6E0dA00Ba) |
| [BinaryModule](src/modules/BinaryModule.sol) (impl) | [`0x492FEc596eC347459E1Ebe30b9245EB3B49B1BBa`](https://polygonscan.com/address/0x492FEc596eC347459E1Ebe30b9245EB3B49B1BBa) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (proxy) | [`0x200000900045e3B6259600682756002200028933`](https://polygonscan.com/address/0x200000900045e3B6259600682756002200028933) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (impl) | [`0xA61e7ca374F721D5b9FD5b0FEe6Fb90f27d448d7`](https://polygonscan.com/address/0xA61e7ca374F721D5b9FD5b0FEe6Fb90f27d448d7) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (proxy) | [`0x30000034706C7d8e12009DAB006Be20000c031A8`](https://polygonscan.com/address/0x30000034706C7d8e12009DAB006Be20000c031A8) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (impl) | [`0x572cD48cCe93B2E58F1cc0253a7fDd4B4952a9C2`](https://polygonscan.com/address/0x572cD48cCe93B2E58F1cc0253a7fDd4B4952a9C2) |

</details>

<details>
<summary><strong>Amoy</strong></summary>

| Contract | Address |
|----------|---------|
| [PositionManager](src/positionManager/PositionManager.sol) (proxy) | [`0x006F54F7f9A22e0000CC2AB60031000000ae9fEF`](https://amoy.polygonscan.com/address/0x006F54F7f9A22e0000CC2AB60031000000ae9fEF) |
| [PositionManager](src/positionManager/PositionManager.sol) (impl) | [`0xCc5De1e9D14a7AB75E872E23FC9D605518Bac2D0`](https://amoy.polygonscan.com/address/0xCc5De1e9D14a7AB75E872E23FC9D605518Bac2D0) |
| [Exchange](src/exchange/Exchange.sol) (proxy) | [`0xe3333700cA9d93003F00f0F71f8515005F6c00Aa`](https://amoy.polygonscan.com/address/0xe3333700cA9d93003F00f0F71f8515005F6c00Aa) |
| [Exchange](src/exchange/Exchange.sol) (impl) | [`0x9e644323459CF672437fcAcC820E11A4645bF09e`](https://amoy.polygonscan.com/address/0x9e644323459CF672437fcAcC820E11A4645bF09e) |
| [Router](src/routers/Router.sol) (proxy) | [`0x12121212006e4CD160D18e3f00711DA5c3372600`](https://amoy.polygonscan.com/address/0x12121212006e4CD160D18e3f00711DA5c3372600) |
| [Router](src/routers/Router.sol) (impl) | [`0x7Df9968F0Ce8383D6aCd0d963411d7cdfbC7c311`](https://amoy.polygonscan.com/address/0x7Df9968F0Ce8383D6aCd0d963411d7cdfbC7c311) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (proxy) | [`0xa1200000d0002264C9a1698e001292D00E1b00af`](https://amoy.polygonscan.com/address/0xa1200000d0002264C9a1698e001292D00E1b00af) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (impl) | [`0xEA6d041829Daaf591d463CF9B2860F4ce0828CC3`](https://amoy.polygonscan.com/address/0xEA6d041829Daaf591d463CF9B2860F4ce0828CC3) |
| [BinaryModule](src/modules/BinaryModule.sol) (proxy) | [`0x1000008dD9001B968442c1000017eaE6E0dA00Ba`](https://amoy.polygonscan.com/address/0x1000008dD9001B968442c1000017eaE6E0dA00Ba) |
| [BinaryModule](src/modules/BinaryModule.sol) (impl) | [`0x69f46E306f31D65934389cCE28c118C694932dEB`](https://amoy.polygonscan.com/address/0x69f46E306f31D65934389cCE28c118C694932dEB) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (proxy) | [`0x200000900045e3B6259600682756002200028933`](https://amoy.polygonscan.com/address/0x200000900045e3B6259600682756002200028933) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (impl) | [`0x684bD14F5bEA2689947d87B9fc8840CF44590d21`](https://amoy.polygonscan.com/address/0x684bD14F5bEA2689947d87B9fc8840CF44590d21) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (proxy) | [`0x30000034706C7d8e12009DAB006Be20000c031A8`](https://amoy.polygonscan.com/address/0x30000034706C7d8e12009DAB006Be20000c031A8) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (impl) | [`0x67c8b271E2828b875f3bb4B14208523b440e1E04`](https://amoy.polygonscan.com/address/0x67c8b271E2828b875f3bb4B14208523b440e1E04) |

</details>

## Documentation

- [Architecture](docs/architecture.md) — system overview, design patterns, contract relationships
- [Position IDs](docs/position-ids.md) — structured ID schema, Ids.sol API (ConditionIdLib / EventIdLib / PositionIdLib), gas savings
- [Modules](docs/modules.md) — BinaryModule, NegRiskModule, CombinatorialModule, abstract hierarchy, resolution roles
- [Position Manager](docs/position-manager.md) — core ERC1155 contract, module registration, unsafe transfers
- [Collateral](docs/collateral.md) — CollateralToken (PMCT), onramp, offramp, PermissionedRamp
- [Oracle](docs/oracle.md) — OracleAggregator, modular resolution system
- [Bridge](docs/bridge.md) — cross-chain bridging (Chainlink CCIP), hub-and-spoke topology
- [Auth](docs/auth.md) — roles, access control, role assignment
- [Router](docs/router.md) — Router, BridgeRouter, CtfRouter, pre-transfer pattern, combinatorial operations
- [Exchange](docs/exchange.md) — order matching, EIP-712 signatures, fee model
- [Migration](docs/migration.md) — legacy CTF/NegRiskAdapter position migration

## Usage

```shell
forge install      # install pinned Foundry dependencies
forge build        # compile
forge test         # run tests
forge fmt          # format
forge snapshot     # gas snapshots
make setup         # install git hooks (pre-commit: fmt + snapshot)
```

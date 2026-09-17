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
| [PositionManager](src/positionManager/PositionManager.sol) (impl) | [`0xCc5De1e9D14a7AB75E872E23FC9D605518Bac2D0`](https://polygonscan.com/address/0xCc5De1e9D14a7AB75E872E23FC9D605518Bac2D0) |
| [Exchange](src/exchange/Exchange.sol) (proxy) | [`0xe3333700cA9d93003F00f0F71f8515005F6c00Aa`](https://polygonscan.com/address/0xe3333700cA9d93003F00f0F71f8515005F6c00Aa) |
| [Exchange](src/exchange/Exchange.sol) (impl) | [`0x641b40ec414a076b9e79E703Fc7BF4EBEC248Bb7`](https://polygonscan.com/address/0x641b40ec414a076b9e79E703Fc7BF4EBEC248Bb7) |
| [Router](src/routers/Router.sol) (proxy) | [`0x12121212006e4CD160D18e3f00711DA5c3372600`](https://polygonscan.com/address/0x12121212006e4CD160D18e3f00711DA5c3372600) |
| [Router](src/routers/Router.sol) (impl) | [`0x91fA5E2F12a308A13DefdB6aaF80B71DBe9B7696`](https://polygonscan.com/address/0x91fA5E2F12a308A13DefdB6aaF80B71DBe9B7696) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (proxy) | [`0xa1200000d0002264C9a1698e001292D00E1b00af`](https://polygonscan.com/address/0xa1200000d0002264C9a1698e001292D00E1b00af) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (impl) | [`0x64860bFD14fCcaAc09cd36f347784a9616AfB66C`](https://polygonscan.com/address/0x64860bFD14fCcaAc09cd36f347784a9616AfB66C) |
| [BinaryModule](src/modules/BinaryModule.sol) (proxy) | [`0x1000008dD9001B968442c1000017eaE6E0dA00Ba`](https://polygonscan.com/address/0x1000008dD9001B968442c1000017eaE6E0dA00Ba) |
| [BinaryModule](src/modules/BinaryModule.sol) (impl) | [`0xf6428c0B5fa9361c0708CDdb95468cf54C56e9A2`](https://polygonscan.com/address/0xf6428c0B5fa9361c0708CDdb95468cf54C56e9A2) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (proxy) | [`0x200000900045e3B6259600682756002200028933`](https://polygonscan.com/address/0x200000900045e3B6259600682756002200028933) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (impl) | [`0x39a5B01a100edF811f2748aa37B1313715Ded70e`](https://polygonscan.com/address/0x39a5B01a100edF811f2748aa37B1313715Ded70e) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (proxy) | [`0x30000034706C7d8e12009DAB006Be20000c031A8`](https://polygonscan.com/address/0x30000034706C7d8e12009DAB006Be20000c031A8) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (impl) | [`0xf96968a44022B17240B42c557693E7C383d2d8a3`](https://polygonscan.com/address/0xf96968a44022B17240B42c557693E7C383d2d8a3) |
| [CollateralToken](src/collateral/CollateralToken.sol) (proxy) | [`0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB`](https://polygonscan.com/address/0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB) |
| [CollateralToken](src/collateral/CollateralToken.sol) (impl) | [`0xCe84E053301A82937F90ee2C2c1889cAb1db25dE`](https://polygonscan.com/address/0xCe84E053301A82937F90ee2C2c1889cAb1db25dE) |
| [CollateralOnramp](https://github.com/Polymarket/ctf-exchange-v2/blob/main/src/collateral/CollateralOnramp.sol) | [`0x93070a847efEf7F70739046A929D47a521F5B8ee`](https://polygonscan.com/address/0x93070a847efEf7F70739046A929D47a521F5B8ee) |
| [CollateralOfframp](https://github.com/Polymarket/ctf-exchange-v2/blob/main/src/collateral/CollateralOfframp.sol) | [`0x2957922Eb93258b93368531d39fAcCA3B4dC5854`](https://polygonscan.com/address/0x2957922Eb93258b93368531d39fAcCA3B4dC5854) |
| [PermissionedRamp](https://github.com/Polymarket/ctf-exchange-v2/blob/main/src/collateral/PermissionedRamp.sol) | [`0xebC2459Ec962869ca4c0bd1E06368272732BCb08`](https://polygonscan.com/address/0xebC2459Ec962869ca4c0bd1E06368272732BCb08) |
| [OracleAggregator](src/oracle/OracleAggregator.sol) (proxy) | [`0x0A0a0A0A8B00C51b7D810501b03F230028C04a87`](https://polygonscan.com/address/0x0A0a0A0A8B00C51b7D810501b03F230028C04a87) |
| [OracleAggregator](src/oracle/OracleAggregator.sol) (impl) | [`0x822e8A97AF8005073F2f6E88435D692E33ab6082`](https://polygonscan.com/address/0x822e8A97AF8005073F2f6E88435D692E33ab6082) |
| [OOReporterModule](src/oracle/modules/OOReporterModule.sol) (proxy) | [`0x000012e0009c84078c4924fba808A41b9f67527f`](https://polygonscan.com/address/0x000012e0009c84078c4924fba808A41b9f67527f) |
| [OOReporterModule](src/oracle/modules/OOReporterModule.sol) (impl) | [`0xBd49A21677Da630fF5Efec52B7309d0Ada685d81`](https://polygonscan.com/address/0xBd49A21677Da630fF5Efec52B7309d0Ada685d81) |
| [ChainlinkReporterModule](src/oracle/modules/reporters/ChainlinkReporterModule.sol) (proxy) | [`0xc12EC12E0000326890Ca5560dEf5EB5C22b16814`](https://polygonscan.com/address/0xc12EC12E0000326890Ca5560dEf5EB5C22b16814) |
| [ChainlinkReporterModule](src/oracle/modules/reporters/ChainlinkReporterModule.sol) (impl) | [`0x33823856ff1c89cD6940f8Ad3d03786C439d6ca5`](https://polygonscan.com/address/0x33823856ff1c89cD6940f8Ad3d03786C439d6ca5) |
| [EOAReporterModule](src/oracle/modules/reporters/EOAReporterModule.sol) (proxy) | [`0x8Ef9D6d668798b1f363b305D916F30739d2b0419`](https://polygonscan.com/address/0x8Ef9D6d668798b1f363b305D916F30739d2b0419) |
| [EOAReporterModule](src/oracle/modules/reporters/EOAReporterModule.sol) (impl) | [`0x5fe0280873f5539da12B6b5b37484E0B0c28Ab14`](https://polygonscan.com/address/0x5fe0280873f5539da12B6b5b37484E0B0c28Ab14) |

</details>

<details>
<summary><strong>Amoy</strong></summary>

| Contract | Address |
|----------|---------|
| [PositionManager](src/positionManager/PositionManager.sol) (proxy) | [`0x006F54F7f9A22e0000CC2AB60031000000ae9fEF`](https://amoy.polygonscan.com/address/0x006F54F7f9A22e0000CC2AB60031000000ae9fEF) |
| [PositionManager](src/positionManager/PositionManager.sol) (impl) | [`0xCc5De1e9D14a7AB75E872E23FC9D605518Bac2D0`](https://amoy.polygonscan.com/address/0xCc5De1e9D14a7AB75E872E23FC9D605518Bac2D0) |
| [Exchange](src/exchange/Exchange.sol) (proxy) | [`0xe3333700cA9d93003F00f0F71f8515005F6c00Aa`](https://amoy.polygonscan.com/address/0xe3333700cA9d93003F00f0F71f8515005F6c00Aa) |
| [Exchange](src/exchange/Exchange.sol) (impl) | [`0xb4D848D2a9c3D8e3F7b13AFea6901d685E580a9f`](https://amoy.polygonscan.com/address/0xb4D848D2a9c3D8e3F7b13AFea6901d685E580a9f) |
| [Router](src/routers/Router.sol) (proxy) | [`0x12121212006e4CD160D18e3f00711DA5c3372600`](https://amoy.polygonscan.com/address/0x12121212006e4CD160D18e3f00711DA5c3372600) |
| [Router](src/routers/Router.sol) (impl) | [`0x91fA5E2F12a308A13DefdB6aaF80B71DBe9B7696`](https://amoy.polygonscan.com/address/0x91fA5E2F12a308A13DefdB6aaF80B71DBe9B7696) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (proxy) | [`0xa1200000d0002264C9a1698e001292D00E1b00af`](https://amoy.polygonscan.com/address/0xa1200000d0002264C9a1698e001292D00E1b00af) |
| [AutoRedeemer](src/utils/AutoRedeemer.sol) (impl) | [`0xEA6d041829Daaf591d463CF9B2860F4ce0828CC3`](https://amoy.polygonscan.com/address/0xEA6d041829Daaf591d463CF9B2860F4ce0828CC3) |
| [BinaryModule](src/modules/BinaryModule.sol) (proxy) | [`0x1000008dD9001B968442c1000017eaE6E0dA00Ba`](https://amoy.polygonscan.com/address/0x1000008dD9001B968442c1000017eaE6E0dA00Ba) |
| [BinaryModule](src/modules/BinaryModule.sol) (impl) | [`0x00C0623203959B43C227c3a01C6aB51b1d28AaEA`](https://amoy.polygonscan.com/address/0x00C0623203959B43C227c3a01C6aB51b1d28AaEA) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (proxy) | [`0x200000900045e3B6259600682756002200028933`](https://amoy.polygonscan.com/address/0x200000900045e3B6259600682756002200028933) |
| [NegRiskModule](src/modules/NegRiskModule.sol) (impl) | [`0xDd6c41C8CaC49547774CcE1e979152Be21b39122`](https://amoy.polygonscan.com/address/0xDd6c41C8CaC49547774CcE1e979152Be21b39122) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (proxy) | [`0x30000034706C7d8e12009DAB006Be20000c031A8`](https://amoy.polygonscan.com/address/0x30000034706C7d8e12009DAB006Be20000c031A8) |
| [CombinatorialModule](src/modules/CombinatorialModule.sol) (impl) | [`0xf96968a44022B17240B42c557693E7C383d2d8a3`](https://amoy.polygonscan.com/address/0xf96968a44022B17240B42c557693E7C383d2d8a3) |
| [CollateralToken](src/collateral/CollateralToken.sol) (proxy) | [`0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB`](https://amoy.polygonscan.com/address/0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB) |
| [CollateralToken](src/collateral/CollateralToken.sol) (impl) | [`0xaBE35017032C5Ca11B93d32f45EBAe8ecaD4916c`](https://amoy.polygonscan.com/address/0xaBE35017032C5Ca11B93d32f45EBAe8ecaD4916c) |
| [CollateralOnramp](https://github.com/Polymarket/ctf-exchange-v2/blob/main/src/collateral/CollateralOnramp.sol) | [`0x93070a847efEf7F70739046A929D47a521F5B8ee`](https://amoy.polygonscan.com/address/0x93070a847efEf7F70739046A929D47a521F5B8ee) |
| [CollateralOfframp](https://github.com/Polymarket/ctf-exchange-v2/blob/main/src/collateral/CollateralOfframp.sol) | [`0x2957922Eb93258b93368531d39fAcCA3B4dC5854`](https://amoy.polygonscan.com/address/0x2957922Eb93258b93368531d39fAcCA3B4dC5854) |
| [PermissionedRamp](https://github.com/Polymarket/ctf-exchange-v2/blob/main/src/collateral/PermissionedRamp.sol) | [`0xebC2459Ec962869ca4c0bd1E06368272732BCb08`](https://amoy.polygonscan.com/address/0xebC2459Ec962869ca4c0bd1E06368272732BCb08) |
| [OracleAggregator](src/oracle/OracleAggregator.sol) (proxy) | [`0x0A0a0A0A8B00C51b7D810501b03F230028C04a87`](https://amoy.polygonscan.com/address/0x0A0a0A0A8B00C51b7D810501b03F230028C04a87) |
| [OracleAggregator](src/oracle/OracleAggregator.sol) (impl) | [`0x822e8A97AF8005073F2f6E88435D692E33ab6082`](https://amoy.polygonscan.com/address/0x822e8A97AF8005073F2f6E88435D692E33ab6082) |
| [OOReporterModule](src/oracle/modules/OOReporterModule.sol) (proxy) | [`0x000012e0009c84078c4924fba808A41b9f67527f`](https://amoy.polygonscan.com/address/0x000012e0009c84078c4924fba808A41b9f67527f) |
| [OOReporterModule](src/oracle/modules/OOReporterModule.sol) (impl) | [`0xDF213Ee661238df4b29ae6d4b2DFF33d4E0BD7BE`](https://amoy.polygonscan.com/address/0xDF213Ee661238df4b29ae6d4b2DFF33d4E0BD7BE) |
| [ChainlinkReporterModule](src/oracle/modules/reporters/ChainlinkReporterModule.sol) (proxy) | [`0xc12EC12E0000326890Ca5560dEf5EB5C22b16814`](https://amoy.polygonscan.com/address/0xc12EC12E0000326890Ca5560dEf5EB5C22b16814) |
| [ChainlinkReporterModule](src/oracle/modules/reporters/ChainlinkReporterModule.sol) (impl) | [`0x4a0ef53ACEC6DdADCc12a44dB11fEd3f281dAf42`](https://amoy.polygonscan.com/address/0x4a0ef53ACEC6DdADCc12a44dB11fEd3f281dAf42) |
| [EOAReporterModule](src/oracle/modules/reporters/EOAReporterModule.sol) (proxy) | [`0x8Ef9D6d668798b1f363b305D916F30739d2b0419`](https://amoy.polygonscan.com/address/0x8Ef9D6d668798b1f363b305D916F30739d2b0419) |
| [EOAReporterModule](src/oracle/modules/reporters/EOAReporterModule.sol) (impl) | [`0x5fe0280873f5539da12B6b5b37484E0B0c28Ab14`](https://amoy.polygonscan.com/address/0x5fe0280873f5539da12B6b5b37484E0B0c28Ab14) |

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

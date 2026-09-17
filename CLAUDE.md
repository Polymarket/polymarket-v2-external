# CLAUDE.md

## Project Overview

Polymarket's next-generation prediction market smart contract system. Manages position tokens (ERC1155), collateral wrapping/unwrapping, market resolution via modular oracles, order matching, and cross-chain bridging. Built with Foundry and Solady.

Core concepts:
- **PositionManager**: UUPS-upgradeable ERC1155 token contract. Positions are structured uint256 IDs encoding the module, market data, condition index, and outcome index.
- **Modules**: BinaryModule (YES/NO markets), NegRiskModule (2–65535 outcome markets), and CombinatorialModule (multi-leg conjunction positions) are UUPS-upgradeable and handle the split/merge/redeem lifecycle. Binary/NegRisk resolution is authorized by resolver/bridge roles, scoped by the resolution chain encoded in each condition ID.
- **OracleAggregator**: Modular oracle resolution with composable reporter/disputer/arbitrator modules (OOReporter, Chainlink, EOA). Requests are registered via `initializeRequest`, with targets validated against the PositionManager module registry, and resolved through reporter-vote or arbitrator-finalization flows. See `src/oracle/README.md` and `src/oracle/GLOSSARY.md`.
- **Exchange**: UUPS-upgradeable EIP-712 order matching with direct-to-module transfers for gas-efficient mint/merge paths.
- **CollateralToken**: UUPS-upgradeable ERC20 (pUSD) wrapping USDC/USDCe, with onramp, offramp, and permissioned ramp.
- **Bridge**: Cross-chain position, collateral, and result bridging via the shared `IBridge` interface. One transport in the tree: UUPS-upgradeable `CcipBridge` (Chainlink CCIP) on the transport-agnostic `BridgeBase`. Peers are `bytes32`; send/receive can be paused globally and per remote chain. Position bridging is an allowlist (`_isBridgeablePositionModule`: BINARY and NEGRISK only) applied on both the send and receive paths, so a new module type is refused by default. Results make one hop out of the resolution chain, enforced by two constructor immutables in different layers: `BridgeBase.RESOLUTION_CHAIN_ID` (EVM chain id — 137 on mainnet, 80002 on Amoy) and `CcipBridge.RESOLUTION_CHAIN_SELECTOR` (the same chain's CCIP selector, since the receive path only learns selectors and there is no on-chain mapping to chain ids). `bridgeResult` reverts `InvalidResolutionChainId` unless the local chain is the resolution chain; `_handleResultReceive` reverts `LocalResolutionChain` there, and reverts `UnexpectedResultSource` unless the message arrived on the resolution chain's own lane, delegating that comparison to the `_isResolutionChainSource` transport hook so CCIP addressing stays out of the base. The two receive checks are independent and neither subsumes the other — the provenance check is what stops a compromised or misconfigured spoke resolving conditions on other spokes, while the identity check still catches a peer configured for the resolution chain's own selector. Do not collapse them; zero is rejected for both immutables. Combinatorial positions are not bridgeable and `CombinatorialModule` exposes no bridge entry point — its leg definition is per-chain state that a position payload cannot carry.

## CollateralToken Backwards Compatibility (Deployed Ramps)

The `CollateralToken` proxy (`0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB` on Polygon and Amoy) was originally deployed from the `ctf-exchange-v2` repo, and this repo's `CollateralToken` is upgraded **onto that same proxy**. The ramps and adapters deployed from `ctf-exchange-v2` (CollateralOnramp `0x93070a84…`, CollateralOfframp `0x2957922E…`, PermissionedRamp `0xebC2459E…`, CtfCollateralAdapter `0xADa10087…`, NegRiskCtfCollateralAdapter `0xAdA20000…`) are **not** being redeployed or upgraded and remain live against the proxy. This creates a hard upgrade constraint:

- The deployed ramps/adapters call the **five-argument, legacy** `wrap(address,address,uint256,address,bytes)` (`0xb97b57c7`) and `unwrap(address,address,uint256,address,bytes)` (`0xd600875d`). Every future `CollateralToken` implementation **must keep these overloads** (alongside the three-argument variants used by this repo's own ramps) or every deployed ramp/adapter breaks — including this repo's deployed `AutoRedeemer` and the external `ctf-auto-redeem` contract, which both wrap redemption payouts through the deployed Onramp.
- **Callbacks are intentionally not implemented**: in the five-argument overloads, the trailing `callbackReceiver`/`data` parameters are accepted for ABI compatibility but ignored — this repo's implementation never invokes a callback and `ICollateralTokenCallbacks` does not exist here. This is safe because the **entire current WRAPPER_ROLE holder set** was enumerated on-chain via `RolesUpdated` logs (Polygon and Amoy) and every holder passes `_callbackReceiver: address(0)`: CollateralOnramp `0x93070a84…`, CollateralOfframp `0x2957922E…` (Polygon only), PermissionedRamp `0xebC2459E…`, CtfCollateralAdapter `0xADa10087…` and `0xAdA100db…`, NegRiskCtfCollateralAdapter `0xAdA20000…` and `0xAdA20056…` (the `…db`/`…56` adapter instances are newer deployments not listed in the ctf-exchange-v2 README; verified via Polygonscan source). Nothing deployed implements the callback interface. If a future wrapper is ever expected to receive callbacks, the CollateralToken must be upgraded first — the current implementation will silently skip the callback (and revert on the vault transfer/burn if funds were not pre-transferred).
- **Callback history disclaimer**: in `ctf-exchange-v2`, the original CollateralToken (PR #48) invoked a *mandatory* `wrapCallback`/`unwrapCallback` on `msg.sender`, and the Onramp implemented an empty callback. PR #52 ("Callback Address") made the callback receiver an explicit optional parameter, and the ramps were changed to pre-transfer funds and pass `address(0)`. So the **deployed ramps/adapters never trigger callbacks** — the callback parameters are dormant in practice, but the five-arg *selectors* are load-bearing. This was verified against the on-chain runtime bytecode on Polygon and Amoy (exact match with `ctf-exchange-v2` HEAD, modulo immutables/metadata; the Amoy adapters are an older post-#52 build, also 5-arg + `address(0)`).
- The deployed periphery uses the token's other functions only as standard ERC20 plus `mint`/`burn`/immutable getters, which must also remain selector-stable. (Deployed-impl provenance, verified by bytecode: this repo's PositionManager, Exchange, BinaryModule, NegRiskModule = release `v1.0.0`; Router, AutoRedeemer, CombinatorialModule = post-#310 main; ctf-exchange-v2's exchanges/ramps/Polygon adapters = its HEAD.)

## Build & Verification Commands

```bash
forge build        # Compile
forge test         # Run all tests
forge fmt          # Format all files
forge snapshot     # Regenerate .gas-snapshot
```

**CI** (`.github/workflows/foundry.yml`) runs three parallel jobs:
- **Build & Test**: `forge fmt --check`, `forge build`, `make wrap-check`, `make sizes`, `forge test -vvv`, `forge snapshot --check`
- **Coverage**: `make coverage` — auto-discovers production files from `forge coverage` output (excludes `test/`, `dev/`, `mocks/`, `legacy/`, `external/` paths) and fails if any drops below the threshold (currently **90%** line, **80%** branch) for coverage
- **Storage Layout**: `make storage-check` — compares storage layouts of upgradeable contracts against baselines in `.storage-layouts/`, and runs custom storage slot tests (`forge test --mc StorageSlots`)

The `bash/` directory contains the CI check scripts (`check-contract-sizes.sh`, `check-coverage.sh`, `check-storage-layout.sh`, `check-wrap-discipline.sh`), referenced by the `Makefile`.

**Pre-commit hook** (`.hooks/pre-commit`): auto-runs `forge fmt` and `forge snapshot`, stages results. Activate with `make setup`.

After every code change, run all four commands in order and fix any issues before considering the task complete.

## Project Structure

```
src/
├── positionManager/
│   ├── PositionManager.sol             # ERC1155 position token (UUPS upgradeable)
│   ├── IPositionManagerModule.sol      # Module interface (getPayout)
│   ├── dev/
│   │   └── PositionManagerSetup.sol
│   └── test/
│       ├── PositionManager.t.sol
│       └── UnsafeTransfer.t.sol
├── modules/
│   ├── BinaryModule.sol                # Binary YES/NO markets (moduleId=1, UUPS upgradeable)
│   ├── NegRiskModule.sol               # Multi-outcome markets (moduleId=2, UUPS upgradeable)
│   ├── CombinatorialModule.sol         # Multi-leg conjunction markets (moduleId=3, UUPS upgradeable)
│   ├── dev/
│   │   └── ModuleProxyLib.sol          # Dev helper for ERC1967 module proxy deployment
│   ├── abstract/
│   │   ├── BaseModule.sol              # Shared split/merge/redeem logic
│   │   ├── OracleModule.sol            # Resolver/bridge role authorization + pause management
│   │   └── ModuleErrors.sol
│   ├── migration/
│   │   ├── BaseMigrationMixin.sol      # Shared legacy CTF migration logic
│   │   ├── BinaryMigrationMixin.sol    # Binary-specific migration
│   │   └── NegRiskMigrationMixin.sol   # NegRisk-specific migration
│   └── test/
│       ├── BaseModule.t.sol
│       ├── BinaryModule.t.sol
│       ├── NegRiskModule.t.sol
│       ├── CombinatorialModule.t.sol
│       ├── CombinatorialModuleInvariant.t.sol
│       ├── BinaryMigration.t.sol
│       ├── NegRiskMigration.t.sol
│       ├── MigrationSnapshots.t.sol
│       └── mocks/
│           └── MigrationReentrancyMock.sol
├── oracle/
│   ├── OracleAggregator.sol            # Central resolution registry + state machine
│   ├── README.md                       # Oracle system architecture docs
│   ├── GLOSSARY.md                     # Canonical oracle terminology
│   ├── abstract/
│   │   ├── OracleModuleBase.sol        # Shared base for reporter/disputer/arbitrator
│   │   ├── OracleAggregatorErrors.sol
│   │   └── OracleAggregatorEvents.sol
│   ├── interfaces/
│   │   ├── IOracleAggregator.sol
│   │   ├── IReporterModule.sol
│   │   ├── IDisputerModule.sol
│   │   ├── IArbitratorModule.sol
│   │   └── IBinaryReporter.sol
│   ├── libraries/
│   │   └── OptimisticOraclePayoutLib.sol
│   ├── mixins/
│   │   ├── Auth.sol
│   │   ├── Pausable.sol
│   │   └── MarketDataRegistry.sol       # Product specs + per-request rules (ERC-7201 namespaced storage)
│   ├── modules/
│   │   ├── OOReporterModule.sol         # UMA OOReporter result reporter/finalizer
│   │   ├── README.md                    # OOReporterModule documentation
│   │   └── reporters/
│   │       ├── EOAReporterModule.sol
│   │       └── ChainlinkReporterModule.sol
│   └── test/
│       ├── OracleAggregator.t.sol
│       ├── common/
│       │   ├── ModuleTestBase.sol
│       │   └── OOReporterModule.t.sol
│       ├── integration/
│       │   ├── OOReporterIntegration.t.sol
│       │   ├── OracleSnapshots.t.sol
│       │   └── mocks/
│       │       └── IntegrationOptimisticOracleV2.sol
│       ├── libraries/
│       │   └── OptimisticOraclePayoutLib.t.sol
│       ├── mocks/
│       │   ├── MockArbitratorModule.sol
│       │   └── MockDisputerModule.sol
│       └── modules/
│           └── reporters/
│               ├── EOAReporterModule.t.sol
│               └── ChainlinkReporterModule.t.sol
├── collateral/
│   ├── CollateralToken.sol             # UUPS ERC20 (pUSD, 6 decimals)
│   ├── CollateralOnramp.sol            # Wrap (USDC/USDCe → pUSD)
│   ├── CollateralOfframp.sol           # Unwrap (pUSD → USDC/USDCe)
│   ├── PermissionedRamp.sol            # EIP-712 witness-signed wrap/unwrap
│   ├── abstract/
│   │   ├── CollateralErrors.sol
│   │   └── Pausable.sol
│   ├── interfaces/
│   │   └── ICollateralToken.sol
│   ├── mocks/
│   │   ├── DepositWallet.sol           # Test vault
│   │   ├── USDC.sol
│   │   └── USDCe.sol
│   ├── dev/
│   │   ├── CollateralSetup.sol
│   │   └── CollateralSetup.t.sol
│   └── test/
│       ├── CollateralToken.t.sol
│       ├── CollateralOnramp.t.sol
│       ├── CollateralOfframp.t.sol
│       └── PermissionedRamp.t.sol
├── exchange/
│   ├── Exchange.sol                    # UUPS EIP-712 order matching
│   ├── OrderStructs.sol
│   ├── MATCH_ORDERS_LIFECYCLE.md       # Order matching lifecycle docs
│   └── test/
│       ├── BaseExchangeTest.sol
│       ├── MatchOrders.t.sol
│       ├── MatchOrdersBalanceFlows.t.sol
│       ├── EIP712Digest.t.sol
│       ├── ERC1271Signature.t.sol
│       ├── ExchangeAdmin.t.sol
│       ├── ExchangeMath.t.sol
│       ├── ExchangeSnapshots.t.sol
│       ├── Preapproved.t.sol
│       └── mocks/
│           ├── ERC1271Mock.sol
│           ├── GriefingERC1271Mock.sol
│           ├── MockProxyFactory.sol
│           ├── MockSafeFactory.sol
│           └── ToggleableERC1271Mock.sol
├── routers/
│   ├── Router.sol                      # Primary router (pre-transfer pattern + combinatorial ops)
│   ├── BridgeRouter.sol                # Extends Router with cross-chain bridging
│   ├── CtfRouter.sol                   # Legacy CTF-compatible interface
│   ├── dev/
│   │   └── RouterSetup.sol             # Dev helper for router proxy deployment
│   └── test/
│       ├── Router.t.sol
│       ├── BridgeRouter.t.sol
│       ├── CtfRouter.t.sol
│       ├── RouterBinaryModule.t.sol
│       ├── RouterNegRiskModule.t.sol
│       ├── RouterCombinatorialCollateralReturn.t.sol
│       └── RouterSnapshots.t.sol
├── bridge/
│   ├── abstract/
│   │   └── BridgeBase.sol              # Shared bridge logic (all IBridge functions)
│   ├── CcipBridge.sol                  # UUPS Chainlink CCIP transport (implements IBridge)
│   ├── interfaces/
│   │   └── IBridge.sol                 # Shared bridge interface (uint256 chain IDs)
│   └── test/
│       ├── CcipBridgeUnit.t.sol
│       ├── CcipBridgeStandard.t.sol
│       ├── CcipBridgeCollateral.t.sol
│       ├── CcipBridgeMigration.t.sol
│       ├── base/
│       │   ├── BridgeTestBase.sol      # Shared bridge test infrastructure
│       │   ├── BridgeUnitTestBase.sol
│       │   ├── BridgeStandardTestBase.sol
│       │   ├── BridgeCollateralTestBase.sol
│       │   ├── BridgeMigrationTestBase.sol
│       │   └── CcipBridgeTestBase.sol
│       └── mocks/
│           └── MockCcipRouter.sol
├── auth/
│   ├── Roles.sol
│   ├── InitializableRoles.sol
│   └── test/
│       └── Roles.t.sol
├── utils/
│   ├── AutoRedeemer.sol
│   └── test/
│       └── AutoRedeemer.t.sol
├── libraries/
│   ├── Ids.sol                         # ConditionId/EventId/PositionId UDVTs + ConditionIdLib, EventIdLib, PositionIdLib
│   ├── ModuleIds.sol                   # BINARY=1, NEGRISK=2, COMBINATORIAL=3
│   ├── BridgePayloads.sol              # Shared bridge payload encoding
│   ├── CrossChainTypes.sol             # MessageType enum, BridgedPosition struct
│   └── test/
│       └── Ids.t.sol
├── abstract/
│   ├── ERC1155TokenReceiver.sol
│   └── test/
│       └── ERC1155TokenReceiver.t.sol
├── legacy/
│   ├── interfaces/
│   │   ├── IConditionalTokens.sol
│   │   ├── IConditionalTokensMethods.sol
│   │   ├── INegRiskAdapter.sol
│   │   └── IUmaCtfAdapter.sol
│   ├── libraries/
│   │   ├── CTFHelpers.sol
│   │   ├── CTHelpers.sol
│   │   └── NegRiskIdLib.sol
│   └── dev/
│       └── NegRiskAdapterSetUp.sol
├── external/
│   └── uma/
│       └── mocks/
│           └── MockOOReporter.sol      # Mock of UMA's managed OOReporter for tests
├── dev/
│   ├── TestHelper.sol                  # Base test contract (inherits Addresses)
│   ├── Addresses.sol                   # Preset accounts: owner, admin, alice, brian, etc.
│   ├── Vm.sol                          # Foundry VM constant
│   └── DeployLib.sol
├── test/
│   └── integration/
│       └── StorageSlots.t.sol          # Custom storage slot validation
└── mocks/
    ├── USDC.sol
    ├── USDCe.sol
    └── ERC20Mintable.sol
```

Each domain (modules, collateral, oracle, etc.) is self-contained with its own `test/`, `dev/`, and `mocks/` subdirectories alongside the source contracts.

## Position ID Encoding

The core data structure — all routing derives from this:

```
[moduleId(8) | baseHash(128) | arity(16) | reserved(64) | resolutionChain(16) | conditionIndex(16) | outcomeIndex(8)]
```

- **moduleId**: Module lookup via `positionManager.moduleById()` — no storage read needed (bit shift). BINARY=1, NEGRISK=2, COMBINATORIAL=3 (`src/libraries/ModuleIds.sol`)
- **baseHash**: `keccak256(moduleId, data)` truncated to 128 bits
- **arity**: Neg-risk condition count (zero for binary and other modules)
- **reserved**: 64 bits reserved for future use (part of event identity)
- **resolutionChain**: `ResolutionChain` enum (currently only `POLYGON = 0`) naming the chain allowed to resolve the condition; modules encode their `RESOLUTION_CHAIN` immutable into every generated ID, and `OracleModule.onlyResolver` rejects resolver-role reports for other chains
- **conditionIndex**: Index within multi-condition events (0 for binary, 0–65535 for NegRisk)
- **outcomeIndex**: Outcome (0=YES, 1=NO for binary)

All encoding/decoding lives in `src/libraries/Ids.sol` — three internal libraries (`ConditionIdLib`, `EventIdLib`, `PositionIdLib`) plus the UDVT definitions, the `ResolutionChain` enum, and the `computeBaseHash` free function. Pure bit operations, no storage access. Encoders have overloads with and without an explicit `ResolutionChain` (default `POLYGON`); `PositionIdLib` has no encoder — position IDs come from `ConditionIdLib.computePositionId`.

## Solidity Conventions

### License

- **Production files**: `// SPDX-License-Identifier: BUSL-1.1` — all contracts, interfaces, libraries, abstract contracts, and mixins in `src/` (excluding `test/`, `dev/`, `mocks/`, `legacy/`, `external/`).
- **Non-production files** (test, dev, mocks): `// SPDX-License-Identifier: MIT`.
- **`src/legacy/`** and **`src/external/`**: Keep existing licenses unchanged — these mirror external protocol code.
- When adding a new file, use `BUSL-1.1` for production code and `MIT` for test/dev/mock files.

### Pragma

- Main source contracts (modules, exchange, collateral, bridge, etc.): `pragma solidity 0.8.34;` (exact)
- Libraries, interfaces, abstract contracts, dev helpers, mocks: mixed — some use exact `0.8.34`, many use `pragma solidity ^0.8.15;`
- Tests: `pragma solidity ^0.8.15;`
- When adding new files, match the pragma style of neighboring files in the same directory.

#### Bumping the Solidity Version

When bumping the exact pragma version (e.g., `0.8.34` → `0.8.35`):

1. Update `solc_version` in `foundry.toml`.
2. Replace the exact pragma in all `src/` `.sol` files: `find src -name "*.sol" -type f -exec sed -i '' 's/pragma solidity OLD;/pragma solidity NEW;/g' {} +`. This covers production code, interfaces, abstract contracts, test bases, and mocks that use the exact version.
3. Files using `^0.8.15` (most standalone test files, some legacy interfaces) do **not** need updating — the caret range already covers newer patch versions.
4. Update this Pragma section in `CLAUDE.md` to reflect the new version.
5. Run `forge build` and `forge test` to verify compilation and tests pass under the new compiler.

### Loops

- **Do not use `unchecked { ++i; }` in for-loops.** Since Solidity 0.8.22, the compiler automatically optimizes overflow checks for standard `for (uint256 i; i < X; ++i)` loops. Manual unchecked blocks are unnecessary and reduce readability.
- Use `++i` (prefix increment) in loop headers, not `i++`.

### Formatting

Enforced by `forge fmt` with `foundry.toml`:
- Line length: **120 characters**
- Comment wrapping: enabled
- Always run `forge fmt` before considering any change complete

### File & Contract Layout

Standard section ordering within contracts, using these separators:

```solidity
/*--------------------------------------------------------------
                           SECTION NAME
--------------------------------------------------------------*/
```

Section order: STATE → CONSTANTS → MODIFIERS → CONSTRUCTOR → INITIALIZER → VIEW → EXTERNAL → function groups by access level (ONLY ADMIN, ONLY OWNER, etc.) → INTERNAL → overrides (SOLADY OVERRIDES, UUPS, EIP712).

### Imports

- External libs: `import {Type} from "@solady/src/path/File.sol";` (also `@chainlink/contracts-ccip/`,
  `@openzeppelin/contracts@5.0.2/`, `managed-oracle/pm-v2-oo-reporter/`, and the
  `@openzeppelin/contracts/` / `@openzeppelin/contracts-upgradeable/` remappings it brings in)
- Cross-domain src: `import {Type} from "@polymarket-v2/src/domain/File.sol";`
- Same-domain src: `import {Type} from "./File.sol";`
- Group external imports first, then `@polymarket-v2/src/` imports, then same-directory `./` imports, separated by a blank line.
- Never use bare `src/` or relative `../` paths for cross-domain imports. The `@polymarket-v2/src/` remapping (`@polymarket-v2/src/=src/` in `foundry.toml`) ensures imports resolve correctly both standalone and when used as a dependency.

### Naming

- Internal/private functions: `_functionName()`
- Constants: `_UPPER_SNAKE_CASE` for internal/private, `UPPER_SNAKE_CASE` for public
- Immutables: `UPPER_SNAKE_CASE` (e.g., `POSITION_MANAGER`, `COLLATERAL_TOKEN`)
- Typehash constants: `_TYPEHASH` suffix
- Function params: `_camelCase` with leading underscore
- Libraries: `PascalCase` (e.g., `PositionIdLib`, `CollateralSetup`)
- **Excluded directories**: `src/legacy/` and `src/external/` mirror external protocol code and are exempt from naming conventions. Do not rename variables or apply style changes to files in these directories.

### Named Parameters in Function Calls

**Always** use named parameters (`foo({_param1: val1, _param2: val2})`) for function calls with **5 or more arguments**. This is especially important for:

- **Internal functions with 6+ params**: E.g., `_setupRequest`, `_reRequest`, `_validateSignature`.
- **Bridge calls with many params**: E.g., `bridgePositions` (5 params), `bridgeCollateral` (4 params).

For calls with **≤4 params**, use named params at your discretion when it improves readability (e.g., `bytes32(0)` or boolean literals that are opaque without names).

Do **not** use named params for:
- ERC1155/ERC20 standard calls (`safeTransferFrom`, `safeBatchTransferFrom`) — universally known.
- `abi.encode()` and event `emit` (syntax doesn't support named arguments).

**Multi-line formatting**: Named parameter calls must have each parameter on its own line. Since `forge fmt` may collapse short calls onto a single line, add `// forgefmt: disable-next-item` on the line before the call to preserve multi-line formatting. Calls with 7+ params typically stay multi-line naturally and don't need the comment.

### Errors & Events

- Domain-specific errors live as abstract contracts (e.g., `CollateralErrors` in `collateral/abstract/`).
- Events are defined as abstract contracts in the same file as the emitting contract (e.g., `CollateralTokenEvents` at the top of `CollateralToken.sol`).
- Test contracts inherit error/event contracts to use selectors directly in assertions.

### Roles (Authorization Pattern)

Contracts use Solady's `OwnableRoles` with role constants:
- `_ROLE_0` / `MINTER_ROLE` / Admin — primary privileged role
- `_ROLE_1` / `WRAPPER_ROLE` / Operator / Witness — secondary role
- `_ROLE_2` / Creator — market creation
- `_ROLE_3` / Bridge — cross-chain operations

Role constants vary per contract. Check each contract's doc comments for its role mapping.

## NatSpec Documentation

Every contract, interface, library, error, event, and function in `src/` (excluding `dev/`, `mocks/`, and test files) must have NatSpec.

### Contract / Interface / Library Level

```solidity
/// @title ContractName
/// @author Polymarket
/// @notice Brief one-line description.
/// @dev Implementation details if needed (multi-line ok).
```

### Errors

```solidity
/// @notice Thrown when the caller is not authorized to perform the action.
error Unauthorized();
```

### Events

```solidity
/// @notice Emitted when ownership is transferred.
/// @param oldOwner The address of the previous owner.
/// @param newOwner The address of the new owner.
event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
```

### Functions

```solidity
/// @notice What it does (one line).
/// @dev Implementation detail or access restriction note (only if non-obvious).
/// @param _name Description.
/// @return name Description.
```

### Modifiers

```solidity
/// @dev Restricts access to admin role holders.
modifier onlyAdmin() { ... }
```

### Struct Fields

```solidity
/// @notice A resolution request registered with the aggregator.
struct RequestConfig {
    /// @dev The contract that receives the final result.
    address targetContract;
    /// @dev Number of matching votes needed to propose an outcome.
    uint128 reporterThreshold;
    ...
}
```

### forge fmt and NatSpec stability

`forge fmt` with `wrap_comments = true` re-flows `///` comment blocks. This can merge a `@param` or `@return` tag into the preceding line's prose, breaking NatSpec parsing. To prevent this:

- Keep each `@notice`, `@dev`, `@param`, `@return` description under ~85 characters so it fits on one `///` line (with the 4-space indent and `/// ` prefix, that's ~100 total).
- After adding NatSpec, always run `forge fmt` then verify no tags were merged: `grep -rn '/// .* @\(param\|dev\|return\|notice\)' src/ --include='*.sol'` should return no matches.
- If `forge fmt` merges a tag, shorten the preceding description.

### Never disclose security context

Production contract source is verified on Polygonscan, so its comments are public even though this repo is private. NatSpec and inline comments in `src/` (excluding `test/`, `dev/`, `mocks/`) must describe **functional behavior only**.

Do not write, in any production contract comment: a vulnerability or attack path, a work factor or hash width that quantifies attack difficulty, a reference to an audit finding / bug bounty / incident / post-mortem, or framing that marks the code as a fix, patch, or mitigation.

Access-control specifications, ordering and derivation constraints, and the mechanical reason a low-level construct was chosen are all still fine. The test is whether a reader learns an exploitable outcome, not whether a sentence contains the word "prevents".

State the rule and the design constraint as a property of the system:

```solidity
// Bad  - describes the failure mode
/// @dev The condition ID commits to the leg array in only 128 bits, so two chains can bind
///      different arrays to the same ID and mint unbacked value.

// Good - describes the behavior
/// @dev A condition's leg definition is stored per chain in `legs[]`, so a position is operable
///      only on a chain that already holds that definition.
```

The reasoning belongs in `docs/`, in tests, and in the PR description, none of which are published with the bytecode.

### When NOT to document

- `dev/`, `mocks/`, and test-only libraries (any library importing `src/dev/Vm.sol`)
- Test files
- External protocol interfaces may use minimal documentation

## Testing

### Parent/Child Test Structure

Every test file uses a **parent/child** pattern:

- **Parent contract**: Has `virtual setUp()`, state variables, and helper functions. **Zero test functions.**
- **Child contracts**: Named `ParentName_feature`, each grouping tests for one function or feature.
- **Section separators** between each child contract:

```solidity
/*--------------------------------------------------------------
                      SECTION NAME
--------------------------------------------------------------*/

contract CollateralTokenTest_mint is CollateralTokenTest {
    function test_mint() public { ... }
    function test_revert_unauthorized() public { ... }
}
```

Example structure:

```solidity
// Parent: setUp + helpers, ZERO test functions
contract CollateralTokenTest is TestHelper, CollateralTokenEvents, CollateralErrors {
    function setUp() public virtual { ... }
    function _wrapUSDC(uint256 _amount) internal { ... }
}

/*--------------------------------------------------------------
                         INITIALIZE
--------------------------------------------------------------*/

contract CollateralTokenTest_initialize is CollateralTokenTest {
    function test_initialize() public { ... }
    function test_revert_alreadyInitialized() public { ... }
}
```

This enables targeted test execution: `forge test --mc CollateralTokenTest_mint`.

### Test File Conventions

- Tests are **co-located** with source in `test/` subdirectories (e.g., `src/collateral/test/CollateralToken.t.sol`)
- Dev helpers and setup libraries live in `dev/` subdirectories
- File naming: `ContractName.t.sol`
- Pragma: `pragma solidity ^0.8.15;`

### Test Function Naming

The child contract name scopes the feature, so test names are short:

- Happy path: `test_functionName()`
- Revert / failure: `test_revert_reason()`
- Fuzz tests: `test_functionName(uint256 _param)`

Do NOT prefix test names with the contract name — the child contract provides that context.

### Adding New Tests

1. **Always append to the existing test file** for the contract being tested (e.g., `CollateralToken.t.sol` for `CollateralToken.sol`). Do not create separate files like `*Coverage.t.sol`.
2. Find the appropriate child contract (e.g., `CollateralTokenTest_mint` for a new mint test).
3. Add the test function there.
4. If no suitable child exists, create a new one with a section separator above it.
5. **Never** add test functions to the parent contract.

### Abstract Base Test Contracts

Some domains share test logic via abstract bases:

- **`BaseModuleTest`** (`src/modules/test/BaseModule.t.sol`): Shared bridge/hasResult/getPayout assertions as `_assert_*()` internal helpers. Concrete module tests (BinaryModuleTest, NegRiskModuleTest) create dedicated child contracts that wrap these as test functions.
- **`BaseExchangeTest`** (`src/exchange/test/BaseExchangeTest.sol`): Shared exchange setup, order helpers, deal helpers. No test functions.
- **`ModuleTestBase`** (`src/oracle/test/common/ModuleTestBase.sol`): Shared oracle aggregator setup and event creation helpers.
- **Bridge test bases** (`src/bridge/test/base/`): `BridgeTestBase` (shared multi-chain bridge infrastructure), per-flow `BridgeUnit`/`Standard`/`Collateral`/`MigrationTestBase` contracts, and `CcipBridgeTestBase` (wires the mock CCIP router and peers).

### Error/Event Inheritance

Inherit error and event contracts in the **parent** so `.selector` is available in all children. Don't re-declare errors locally.

### Coverage Requirements

- **CI threshold**: 90% line coverage and 80% branch coverage for all production files (`bash/check-coverage.sh`).
- **Goal**: 100% line and branch coverage wherever feasible. When adding or modifying production code, add tests that cover every new line and branch.
- **Every positive test** must include `vm.expectEmit` for any event-emitting code path, and `assertEq` for every state/balance change.
- **Every revert test** must use `vm.expectRevert(ErrorName.selector)` with the specific error.
- **Uncoverable lines**: Assembly overflow guards, unreachable enum fallthrough, and migration code requiring legacy CTF infrastructure may remain uncovered. Document these with inline comments.

### Patterns

- Use `vm.prank(address)` / `vm.startPrank` / `vm.stopPrank` for caller impersonation
- Use `vm.expectRevert(ErrorName.selector)` before the reverting call
- Use `vm.expectEmit(true, true, true, true, address)` + `emit EventName(...)` before the emitting call
- Assertions: `assertEq()`, `assertTrue()`, `assertFalse()`

### Test Helpers

- `TestHelper` (`src/dev/TestHelper.sol`) — base test contract
- `Addresses` (`src/dev/Addresses.sol`) — preset accounts: `owner`, `admin`, `creator`, `oracle`, `operator`, `manager`, `alice`, `brian`, `carly`, `devin` (all wallet-derived addresses)
- `CollateralSetup` (`src/collateral/dev/CollateralSetup.sol`) — deploys full collateral system. Two overloads: `_deploy(address _owner)` (owner=admin) and `_deploy(address _owner, address _admin)`
- `PositionManagerSetup` (`src/positionManager/dev/PositionManagerSetup.sol`) — deploys position manager with modules

### Build Warning Policy

`forge build` must produce **zero warnings**. After every change, verify the build is clean.

- **Non-production file warnings** (test, dev, mock files): Add the directory to `ignored_warnings_from` in `foundry.toml`. Keep this list updated as new test/dev directories are added.
- **`warning[incorrect-shift]` false positives**: These occur with intentional large bit shifts (e.g., `(1 << 160) - 1` for masks). Verify the code logic is correct, then suppress with `// forge-lint: disable-next-line(incorrect-shift)` on the line above.
- **Unused override parameters** in production files: Comment out the name rather than removing it (e.g., `Origin calldata, /*_origin*/`). This silences the solc warning while preserving readability.
- **Other production file warnings**: Fix them in the source code. Do not suppress legitimate warnings from production files.

### Suppressing Warnings

- **Solc warnings** from test/dev files: suppressed via `ignored_warnings_from` in `foundry.toml` (list of directory paths)
- **Lint warnings** from test/dev files: suppressed via `[lint] ignore` in `foundry.toml` (glob patterns)
- **Lint false positives** on specific lines: use `// forge-lint: disable-next-line(lint-id)` inline comment
- **Lint rules** excluded globally: listed in `[lint] exclude_lints` in `foundry.toml`

## Dependencies

- **Solady**: Gas-optimized contracts (ERC1155, ERC20, EIP712, ECDSA, SafeTransferLib, LibClone, UUPSUpgradeable, Initializable, OwnableRoles)
- **Chainlink CCIP**: `@chainlink/contracts-ccip` for cross-chain messaging (CCIPReceiver, IRouterClient, Client)
- **OpenZeppelin Contracts 5.0.2**: Transitive dependency used by Chainlink CCIPReceiver
- **UMA managed-oracle**: Managed OOReporter implementation and interfaces used by OOReporterModule
- **forge-std**: Foundry testing framework

## Keeping This File Up to Date

After completing any task that changes project architecture, conventions, structure, or workflows, update this file to reflect those changes. Specifically:

- **New contracts or directories**: Update the Project Structure tree.
- **New dependencies**: Add to the Dependencies section.
- **Changed conventions**: If a naming pattern, test pattern, pragma version, or formatting rule changes, update the relevant section so future sessions follow the new convention.
- **New error/event contracts**: Note where they live.
- **New build steps or CI changes**: Update Build & Verification Commands.
- **New test helpers or accounts**: Update the Test Helpers section.
- **Position ID encoding changes**: Update the Position ID Encoding section if bit layout changes.
- **New oracle modules**: Note them in the Project Structure under `oracle/modules/`.
- **New `foundry.toml` warning suppressions**: If new test/dev directories are added, add them to `ignored_warnings_from` and `[lint] ignore` in `foundry.toml`, and document the pattern here.
- **New contracts or functions**: Every new production contract, function, error, event, modifier, and struct must include NatSpec following the patterns in the NatSpec Documentation section. This applies to all files in `src/` except `dev/`, `mocks/`, and test files.
- **Named parameter conventions**: If the threshold for using named parameters changes (e.g., lowered to 4+ params, or extended to external protocol calls), update the "Named Parameters in Function Calls" section under Solidity Conventions. When adding new functions with 5+ params or new call sites, follow the convention.

### CI & Storage Layout Maintenance

When **any production contract** is added or modified:

- **Contract size check** and **coverage** are automatically discovered — no manual list maintenance needed. `bash/check-contract-sizes.sh` scans build artifacts for `src/` contracts (excluding `test/`, `dev/`, `mocks/`, `legacy/`, `external/`) and enforces Polygon's 32KB PIP-30 runtime size limit. `bash/check-coverage.sh` similarly auto-discovers from `forge coverage` output.
- **Edge cases** (e.g., constructor-only contracts that always report 0%): add to the `EXCLUDE_FILES` array in `bash/check-coverage.sh`.
- **Raising the threshold**: update the `THRESHOLD` variable in `bash/check-coverage.sh` and the coverage job name in `.github/workflows/foundry.yml`.

When an **upgradeable contract** (UUPS) is added or modified:

- **New upgradeable contract**: Create a storage layout baseline file in `.storage-layouts/ContractName.md` (run `forge inspect src/Path/ContractName.sol:ContractName storage-layout | grep -E '^\|' > .storage-layouts/ContractName.md`). Add a corresponding check block in `bash/check-storage-layout.sh`.
- **Modified upgradeable contract**: If storage variables are added, removed, reordered, or retyped, update the baseline in `.storage-layouts/`. CI will fail until the baseline matches.

Current upgradeable contracts with storage baselines:
- `PositionManager` → `.storage-layouts/PositionManager.md`
- `CollateralToken` → `.storage-layouts/CollateralToken.md`
- `BinaryModule` → `.storage-layouts/BinaryModule.md`
- `NegRiskModule` → `.storage-layouts/NegRiskModule.md`
- `OracleAggregator` → `.storage-layouts/OracleAggregator.md`
- `OOReporterModule` → `.storage-layouts/OOReporterModule.md`
- `Exchange` → `.storage-layouts/Exchange.md`
- `CombinatorialModule` → `.storage-layouts/CombinatorialModule.md`
- `Router` → `.storage-layouts/Router.md`
- `BridgeRouter` → `.storage-layouts/BridgeRouter.md`
- `CtfRouter` → `.storage-layouts/CtfRouter.md`
- `CcipBridge` → `.storage-layouts/CcipBridge.md`

### Custom Storage Slot Tests

`src/test/integration/StorageSlots.t.sol` validates that custom storage slots (assembly-level slots from Solady and custom code) have not accidentally changed. CI runs these via `make storage-check` → `forge test --mc StorageSlots -vvv`.

**What the tests cover:**

Slots shared by all upgradeable contracts (from Solady):
- ERC1967 implementation slot, Initializable slot, Owner slot, Handover slot seed, Role slot seed

PositionManager-specific (from Solady ERC1155):
- `_ERC1155_MASTER_SLOT_SEED` — balance and approval slot derivation

CollateralToken-specific (from Solady ERC20):
- `_TOTAL_SUPPLY_SLOT`, `_BALANCE_SLOT_SEED`, `_ALLOWANCE_SLOT_SEED`, `_NONCES_SLOT_SEED`

Each slot is tested two ways:
1. **Pure computation test** — verifies the keccak formula produces the expected constant
2. **Storage verification test** — deploys the proxied contract, performs an action, then uses `vm.load` to confirm data is stored at the expected slot

**When to update `StorageSlots.t.sol`:**

- **Solady upgrade**: If Solady changes any slot constant or derivation formula, the pure computation tests will fail. Update the `_EXPECTED_*` constants in the parent contract to match.
- **New upgradeable contract**: Add a new child contract (`StorageSlotsTest_contractName`) with implementation/owner/role slot tests plus any token-specific slot tests.
- **New custom storage slot** (e.g., `bytes32 private constant _SLOT = keccak256("...") - 1`): Add the expected value as a constant in the parent, add a pure computation test in the appropriate child, and add a `vm.load` verification test.
- **New Solady inheritance** (e.g., an upgradeable contract starts using ERC20 or ERC1155): Add the corresponding slot seed tests to that contract's child test contract.

### Documentation Files

In addition to this `CLAUDE.md`, the following documentation files must be kept in sync when relevant changes are made:

**Root-level:**
- **`README.md`**: Update when top-level project architecture, position ID encoding, or the high-level system overview changes.

**Oracle subsystem (`src/oracle/`):**
- **`src/oracle/README.md`**: Update when oracle architecture, module types, resolution lifecycle, file structure, or key design decisions change.
- **`src/oracle/GLOSSARY.md`**: Update when oracle terminology, resolution statuses, ID scheme, or module naming conventions change.

**System documentation (`docs/`):**
- **`docs/architecture.md`**: Update when contract relationships, design patterns (pre-transfer, module-based), or the overall system diagram changes.
- **`docs/position-ids.md`**: Update when position ID bit layout, encoding/decoding functions, or ID derivation logic changes.
- **`docs/position-manager.md`**: Update when PositionManager storage, module registration, mint/burn, or upgrade logic changes.
- **`docs/modules.md`**: Update when module lifecycle (split/merge/redeem), BaseModule, BinaryModule, NegRiskModule, CombinatorialModule, resolver roles, or replay semantics change.
- **`docs/collateral.md`**: Update when CollateralToken, onramp/offramp, PermissionedRamp, or vault interactions change.
- **`docs/exchange.md`**: Update when Exchange order matching, signature types, fee logic, or direct-to-module transfer flow changes.
- **`docs/router.md`**: Update when Router, BridgeRouter, or CtfRouter split/merge/redeem flow, pre-transfer pattern, bridge operations, NegRisk horizontal operations, combinatorial wrappers, or the collateral-return flow change.
- **`docs/oracle.md`**: Update when OracleAggregator, resolution lifecycle, module types (reporter/disputer/arbitrator), or request initialization changes.
- **`docs/bridge.md`**: Update when bridge architecture, CcipBridge, BridgeBase, message payloads, or cross-chain position/collateral/result bridging changes.
- **`docs/reporters.md`**: Removed — `src/reporters/` no longer exists. Modules now receive results directly from the OracleAggregator.
- **`docs/adapters.md`**: Removed — `src/adapters/` no longer exists (CtfCollateral adapters were dropped along with LzBridge).
- **`docs/auth.md`**: Update when Roles, InitializableRoles, Exchange roles, OracleAggregator roles, bridge roles, or the role hierarchy changes.
- **`docs/migration.md`**: Update when legacy CTF migration flows, prepareMigrationCondition/Event, or migratePositions change.

When modifying contracts in a subsystem, review the corresponding `docs/` file and update it if the change affects documented behavior, architecture, or terminology. Similarly, review `src/oracle/README.md` and `GLOSSARY.md` for oracle-related changes.

Do not add session-specific notes (current task details, in-progress work). This file should only contain stable, reusable instructions.

## Rule
- Use `AskUserQuestion` tool whenever requirements are ambiguous
- Don't assume — ask

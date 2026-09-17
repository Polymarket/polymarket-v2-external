# Exchange

Source: `src/exchange/Exchange.sol`, `src/exchange/OrderStructs.sol`

The Exchange provides operator-mediated order matching for PositionManager positions using EIP-712 signed orders. It is deployed behind a UUPS proxy, with immutable PositionManager/collateral dependencies baked into each implementation.

## Order Structure

```solidity
struct Order {
    uint256 salt;            // unique nonce
    address maker;           // order owner (asset source/destination)
    address signer;          // signature authority; must equal maker for EOA/1271
    uint256 tokenId;         // position ID
    uint256 makerAmount;     // amount the maker provides
    uint256 takerAmount;     // amount the maker expects in return
    Side side;               // BUY or SELL
    SignatureType signatureType;
    uint256 timestamp;       // order creation timestamp
    bytes32 metadata;        // arbitrary metadata
    bytes32 builder;         // builder identifier
    bytes signature;         // EIP-712 signature
}
```

**Side**: `BUY` (wants positions, offers collateral) or `SELL` (wants collateral, offers positions)

**OrderStatus**: `{ bool filled, uint248 remaining }` — packed into a single storage slot.

## Signature Types

| Type | Validation |
|------|-----------|
| `EOA` | Standard `ecrecover`, with `order.signer == order.maker` |
| `POLY_PROXY` | `ecrecover` against `order.signer`, plus maker must be signer's derived proxy wallet |
| `POLY_GNOSIS_SAFE` | `ecrecover` against `order.signer`, plus maker must be signer's derived safe |
| `POLY_1271` | ERC-1271 `isValidSignature` on `order.maker`, with `order.signer == order.maker` |

EIP-712 domain: name = `"Polymarket Exchange"`, version = `"1"`.

## Upgradeability

The Exchange uses the UUPS proxy pattern. `initialize(owner, admin)` sets the owner, grants the initial admin role, and initializes the user pause interval. Upgrades are restricted to `onlyOwner` via `_authorizeUpgrade`.

## Order Matching

**`matchOrders(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts)`** (`onlyOperator`, `notPaused`)

The operator submits matched orders. `conditionId` is derived from each order's `tokenId`; it is no longer supplied as a call argument. The three taker-side scalars travel together in a file-scope `TakerAmounts` struct: `{ takerFillAmount, takerReceiveAmount, takerFeeAmount }`. `takerReceiveAmount` is the backend-calculated amount the taker actually receives after surplus matching and is checked against on-chain settlement accounting.

**`matchOrdersAndPrepareCombinatorial(takerOrder, makerOrders, makerFillAmounts, makerFeeAmounts, takerAmounts, combinatorialLegs)`** (`onlyOperator`, `notPaused`)

Prepares `combinatorialLegs` on the immutable `COMBINATORIAL_MODULE`, then runs the same matching logic as `matchOrders` (same `TakerAmounts` shape).

### Complementary (P2P)

Makers and taker are on opposite sides of the same position (one BUY, one SELL). Positions and collateral are transferred directly between parties. If all makers are complementary with the same tokenId, a fast path avoids split/merge entirely.

### Mint/Merge

Makers and taker are on the same side but hold complementary positions. The exchange executes a split (if all buying) or merge (if all selling) to fulfill orders. Uses the [pre-transfer pattern](architecture.md#pre-transfer-pattern) via `unsafeBatchTransferFrom`.

### Direct-to-Module Transfers

When matches require a split or merge (same-side matching), the Exchange interacts with the module directly using the [pre-transfer pattern](architecture.md#pre-transfer-pattern). It pre-transfers collateral (for split) or positions (for merge) to the module via `unsafeBatchTransferFrom`, then calls `module.split()` or `module.merge()` . The Exchange contract itself is an `ERC1155TokenReceiver` so it can hold positions temporarily during matching.

## Fee Model

- Fees are deducted from each order's proceeds and sent to `feeReceiver`
- `maxFeeRate` caps fees against the actual collateral value of the fill. For taker BUY matches this is net collateral spent after refunds; for taker SELL matches this is actual collateral proceeds.

## Pre-approved Orders

Operators can pre-approve orders via `preapproveOrder(order)` — this validates the signature once and marks the order hash as pre-approved. Subsequent matches skip signature verification for that order. Pre-approvals can be invalidated via `invalidatePreapprovedOrder(orderHash)`.

## Roles

| Role | Constant | Capabilities |
|------|----------|-------------|
| Admin | `ADMIN_ROLE` (`_ROLE_0`) | Manage operators, pause trading, pause users |
| Operator | `OPERATOR_ROLE` (`_ROLE_1`) | Match orders, pre-approve/invalidate orders |

## Admin Functions

| Function | Access | Description |
|----------|--------|-------------|
| `addAdmin` / `removeAdmin` | `onlyOwner` | Manage admins |
| `addOperator` / `removeOperator` | `onlyRoles(ADMIN_ROLE)` | Manage operators |
| `pauseTrading` / `unpauseTrading` | `onlyRoles(ADMIN_ROLE)` | Global trading pause |
| `pauseUser` / `unpauseUser` | user | Per-user trading pause |
| `setUserPauseBlockInterval(interval)` | `onlyRoles(ADMIN_ROLE)` | Update delayed user-pause interval |

## View Functions

- `hashOrder(order) → bytes32` — EIP-712 order hash
- `domainSeparator() → bytes32` — EIP-712 domain separator
- `orderStatus(orderHash) → OrderStatus`
- `pausedUsers(addr) → bool`

## Deployment

The Exchange constructor takes immutable PositionManager, CombinatorialModule, fee, and Polymarket wallet factory configuration:

```solidity
constructor(
    address _positionManager,
    address _combinatorialModule,
    address _feeReceiver,
    uint256 _maxFeeRate,
    address _proxyFactory,
    address _safeFactory,
    bytes32 _proxyBytecodeHash,
    bytes32 _safeBytecodeHash
)
```

The bytecode hashes are precomputed offline from the factory creation code and implementation addresses. They must match the CREATE2 derivation used by the proxy/safe factories on the target chain. The computation logic lives in `PolyProxyLib` and `PolySafeLib` in `../ctf-exchange-v2/src/exchange/libraries/`.

### Chain-Specific Values

Source: queried from deployed `CTFExchangeV2` at `0xE111180000d2663C0091e4f400237545B87B996B` and `../contract-deployments/config/`.

#### Polygon Mainnet (137)

| Parameter | Value |
|-----------|-------|
| `_proxyFactory` | `0xaB45c5A4B0c941a2F231C04C3f49182e1A254052` |
| `_safeFactory` | `0xaacFeEa03eb1561C4e67d661e40682Bd20E3541b` |
| `_proxyBytecodeHash` | `0xd21df8dc65880a8606f09fe0ce3df9b8869287ab0b058be05aa9e8af6330a00b` |
| `_safeBytecodeHash` | `0x2bce2127ff07fb632d16c8347c4ebf501f4841168bed00d9e6ef715ddb6fcecf` |

Derived from proxy implementation `0x44e999d5c2F66Ef0861317f9A4805AC2e90aEB4f` and safe implementation `0xE51abdf814f8854941b9Fe8e3A4F65CAB4e7A4a8`.

#### Amoy Testnet (80002)

| Parameter | Value |
|-----------|-------|
| `_proxyFactory` | `0xEcA1c266193F03d28517a500007738adfb7754d8` |
| `_safeFactory` | `0xaacFeEa03eb1561C4e67d661e40682Bd20E3541b` |
| `_proxyBytecodeHash` | `0x442a4567f37708329df46daeaa0cd51382fd3c744c1ade32cf562252eeb67920` |
| `_safeBytecodeHash` | `0x2bce2127ff07fb632d16c8347c4ebf501f4841168bed00d9e6ef715ddb6fcecf` |

Derived from proxy implementation `0xeFF56Fd015Fd4b0Fc90a00D0263135000CF5010F` and safe implementation `0xE51abdf814f8854941b9Fe8e3A4F65CAB4e7A4a8`.

Note: the safe factory and safe bytecode hash are the same across both chains. The proxy factory and proxy bytecode hash differ because Amoy uses a different proxy factory and implementation.

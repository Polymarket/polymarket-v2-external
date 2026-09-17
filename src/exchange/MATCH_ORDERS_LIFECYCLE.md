# `matchOrders` Lifecycle

This document describes the **current** `Exchange.matchOrders()` execution path and where gas is spent.

## High-Level Overview

```
matchOrders()
├── 1) Validate calldata and taker position ID
├── 2) Execute complementary fast path or batch split/merge path
│   ├── Validate orders and update fill state
│   ├── Phase 1: maker loop
│   │   ├── validate maker/taker pair
│   │   ├── validate & update maker order status
│   │   ├── pull maker making asset
│   │   ├── accumulate mint/merge totals
│   │   └── emit maker OrderFilled
│   ├── Phase 2: optional split/merge
│   ├── Phase 3: distribute maker proceeds (loop)
│   └── settle taker and fees
└── 3) Validate taker fee rate and emit taker OrderFilled/OrdersMatched
```

## Entry Point

```solidity
function matchOrders(
    Order calldata takerOrder,
    Order[] calldata makerOrders,
    uint256[] calldata fillAmounts,
    uint256[] calldata makerFees,
    TakerAmounts calldata takerAmounts
) external onlyOperator notPaused
```

```solidity
struct TakerAmounts {
    uint256 takerFillAmount;
    uint256 takerReceiveAmount;
    uint256 takerFeeAmount;
}
```

Modifiers:
- `onlyOperator`
- `notPaused`

`conditionId` is derived from `takerOrder.tokenId` for split/merge calls. The supplied `takerAmounts.takerReceiveAmount` must equal the amount the taker actually receives from settlement. The three taker-side scalars are bundled into `TakerAmounts` (file-scope struct in `Exchange.sol`) to keep the entry point within stack limits; `matchOrdersAndPrepareCombinatorial` accepts the same struct.

## Phase 1: Taker Validation

Complementary matches validate the taker before execution and update status after actual fill accounting. Batch matches validate and update the taker before the split/merge path; a revert unwinds the status update.

Core actions:
1. Hash order (`_hashOrder`)
2. Validate paused user and binary position ID
3. Validate signature (`_validateSignature`)
4. Update `orderStatus`

### Signature Validation Path

`_validateSignature` uses:
1. `_isValidSignature(orderHash, order)` first
2. fallback to `preapproved[orderHash]`
3. revert `InvalidSignature` if both fail

Supported signature semantics:
- `EOA` -> recovered signer must equal `order.maker`
- `POLY_PROXY` / `POLY_GNOSIS_SAFE` -> recovered signer must equal `order.signer`
- `POLY_1271` -> `isValidSignature` check on `order.maker`

### Packed OrderStatus Update

`OrderStatus` is packed as:
- low 8 bits: `filled`
- high 248 bits: `remaining`

`_validateAndUpdate` reads/writes this slot with a single packed `sload`/`sstore`.

## Phase 2: Execute Match

### 2.1 Pull taker making asset for batch paths

If taker is:
- `BUY`: pull collateral from taker -> exchange
- `SELL`: transfer positions to makers directly and only route merge inventory through the module

### 2.2 Maker Collection Loop

For each maker:
1. Validate the maker/taker pair
2. Compute `takingAmount = fillAmount * maker.takerAmount / maker.makerAmount`
3. `_validateAndUpdate(makerOrder, fillAmount, makerFee)`
4. Pull maker making asset into exchange:
   - maker `BUY` -> collateral
   - maker `SELL` -> position token
5. Accumulate:
   - both `BUY` -> `totalMintAmount += takingAmount`
   - both `SELL` -> `totalMergeAmount += fillAmount`
6. Emit maker `OrderFilled`

### 2.3 Phase 2 Batched CTF operation

After loop:
- if `totalMintAmount > 0` -> `_split(decodeConditionId(takerTokenId), totalMintAmount)`
- if `totalMergeAmount > 0` -> `_merge(decodeConditionId(takerTokenId), totalMergeAmount)`

### 2.4 Phase 3 Maker proceeds loop

The maker proceeds loop recomputes each maker's `takingAmount` from calldata:
- maker `SELL`: proceeds net of fee from exchange, fee batched
- maker `BUY`: position tokens from exchange

### 2.5 Taker settlement

- BUY taker: receives actual positions collected/minted; collateral refund reduces taker maker amount for events and fee-rate checks.
- SELL taker: receives actual collateral proceeds less taker fee.
- `takerAmounts.takerReceiveAmount` must match the settled taker receive amount or the call reverts.

## Phase 3: Emit Taker Event

After settlement, taker events are emitted once:
- `OrderFilled(takerHash, taker, exchange, actualMakerAmountFilled, actualTakerAmountFilled, takerFee)`
- `OrdersMatched(takerHash, taker, side, tokenId, actualMakerAmountFilled, actualTakerAmountFilled)`

## Match Validation Rules

- `COMPLEMENTARY`:
  - tokenId must match
  - crossing check via cross-multiplication
- `MINT` / `MERGE`:
  - must be valid complements (same condition, opposite outcomes)
  - crossing checks via cross-multiplication

## Loop Count (Current)

For `n` makers:
1. maker phase-1 loop: `n`
2. maker proceeds loop: `n`

Total core maker loops: **2n**  
(plus internal loops inside split/merge sub-calls)

## Main Gas Hotspots

- Per-order signature validation (`ecrecover` / ERC1271 staticcall)
- External transfers (`ERC20` and `ERC1155`)
- Per-maker validation + status update in hot loops
- Split/merge cross-contract sub-calls

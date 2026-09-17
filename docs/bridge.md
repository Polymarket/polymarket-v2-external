# Bridge

Source: `src/bridge/abstract/BridgeBase.sol`, `src/bridge/CcipBridge.sol`, `src/bridge/interfaces/IBridge.sol`

The bridge enables cross-chain position, collateral, and result transfers via a transport-agnostic abstraction layer. The tree currently ships one transport: Chainlink CCIP (`CcipBridge`). Recipients and peers are specified as `bytes32` to support non-EVM destinations. Until a non-EVM destination exists, send functions require recipients to be left-padded EVM addresses (top 12 bytes zero, `InvalidRecipient` otherwise) — a malformed recipient would burn on source and permanently fail the address decode on the destination.

## Architecture

```
                    ┌─────────────────────┐
                    │     IBridge          │  (shared interface, uint256 chain IDs)
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │     BridgeBase      │  (abstract — all bridging logic)
                    │  send/receive/pause │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │     CcipBridge      │  (CCIPReceiver, UUPS)
                    │  uint64 chain sel.  │
                    └─────────────────────┘
```

- **BridgeBase** (abstract): Implements all `IBridge` functions — send logic, receive dispatch, module support gating, and pause management. Transport-agnostic.
- **CcipBridge**: UUPS-upgradeable ERC1967 proxy implementation extending Chainlink
  `CCIPReceiver` + Solady `OwnableRoles` + `BridgeBase`. Uses CCIP chain selectors
  (uint64 range).

A transport implementation overrides five abstract methods: `_transportSend`, `_bridgeQuote`, `_validateChain`, `_checkBridgeOwner`, and `_checkBridgeAdmin`.

The `IBridge` interface uses `uint256` for chain identifiers; each transport narrows internally (uint64 chain selectors for CCIP).

## Topology

Hub-and-spoke: a single hub chain hosts the authoritative PositionManager and modules. Spoke chains deploy their own PositionManager + modules + bridge instances. The bridge handles minting/burning on both sides. The hub is the resolution chain — the only chain that resolves conditions and the only valid source of a bridged result (Polygon on mainnet, Amoy on testnet; see [Result direction](#result-direction)).

## Message Types

Three message types for hub-to-spoke or spoke-to-hub communication:

| MessageType | Function | Description |
|-------------|----------|-------------|
| `POSITIONS` | `bridgePositions(dstChain, positionIds, amounts, recipient, options)` | Burns binary or neg-risk positions on source and mints them on destination. All positions must belong to the same module. Combinatorial positions are explicitly unsupported. |
| `COLLATERAL` | `bridgeCollateral(dstChain, amount, recipient, options)` | Burns PMCT on source, mints on destination. |
| `RESULT` | `bridgeResult(dstChain, conditionId, options)` | Sends resolution result for a condition, including the neg-risk synthetic Other. Permissionless, but hub-to-spoke only — enforced on both the send and receive paths. |

Each function has a corresponding `quote*` view for fee estimation. Position and collateral bridging are `payable` (messaging fees in native gas). Result bridging is also `payable`.

## Messaging Options

Callers do not pass raw CCIP `extraArgs`. The `options` parameter is either:

- **empty** — the destination gas limit defaults to `DEFAULT_GAS_LIMIT` (200,000), or
- **`abi.encode(uint256 gasLimit)`** — an explicit destination gas limit.

Any other encoding reverts with `InvalidOptions`. The bridge builds `GenericExtraArgsV2` internally with `allowOutOfOrderExecution` always `true`: the bridge contract is the shared CCIP sender for all users, so an ordered message that fails to execute would block every subsequent message on that lane.

## Events & Correlation

Each send path captures the transport message identifier returned by the transport
(`ccipSend`'s `messageId`) and emits it on the source-side event. The destination emits the
same identifier on its receive-side event, so an off-chain indexer can correlate a send with
its delivery purely from the bridge's own events.

| Side | Event | Indexed fields |
|------|-------|----------------|
| Send | `PositionsBridged(messageId, dstChain, sender, recipient, positionCount)` | `messageId`, `dstChain`, `sender` |
| Send | `CollateralBridged(messageId, dstChain, sender, recipient, amount)` | `messageId`, `dstChain`, `sender` |
| Send | `ResultBridged(messageId, dstChain, conditionId)` | `messageId`, `dstChain`, `conditionId` |
| Receive | `PositionReceived(messageId, recipient, positionId, amount)` | `messageId`, `recipient`, `positionId` |
| Receive | `CollateralReceived(messageId, recipient, amount)` | `messageId`, `recipient` |
| Receive | `ResultReceived(messageId, conditionId)` | `messageId`, `conditionId` |

`recipient` is carried in the data (non-indexed) on `PositionsBridged`/`CollateralBridged` to stay within the three-topic limit while keeping `messageId` indexed.

## Receive Handling

`_processMessage(messageId, srcChain, message)` in `BridgeBase` dispatches incoming messages by `MessageType` byte prefix:

- **Positions**: Calls `mintFromBridge` to mint positions to the recipient.
- **Collateral**: Mints PMCT to the recipient via `collateralToken.mint`.
- **Result**: Calls `reportResult` on the module, after the resolution-direction check below.

The transport-specific receive entry point calls `_processMessage`:
- CcipBridge: `_ccipReceive(message)` verifies `peers[sourceChainSelector] == sender` (full 32-byte compare, `UnauthorizedSender` otherwise), then passes `message.messageId` and `message.sourceChainSelector`.

For positions, the receive side re-checks that every position in the batch belongs to the same module before minting (defense in depth against a buggy peer). `mintFromBridge`/`reportResult` on the modules are gated by the bridge role, which each module admin grants to the bridge contract.

### Result direction

A result makes exactly one hop: out of the resolution chain, into every other chain, and no
further. Three checks enforce it, from two constructor-set immutables. `BridgeBase` holds
`RESOLUTION_CHAIN_ID`, an EVM chain id (`137` on mainnet, `80002` for an Amoy testnet deployment).
`CcipBridge` holds `RESOLUTION_CHAIN_SELECTOR`, the same chain's CCIP chain selector
(`4051577828743386545` for Polygon). Both name the resolution chain, so both carry the same value on
every deployment, hub and spoke alike.

- **Send** — `bridgeResult` reverts `InvalidResolutionChainId` unless the local chain is the
  resolution chain. Only the hub exports; a spoke can neither push a result back to the hub nor
  relay one onward to another spoke.
- **Receive, receiver identity** — `_handleResultReceive` reverts `LocalResolutionChain` on the
  resolution chain, which never imports a result.
- **Receive, message provenance** — `_handleResultReceive` reverts `UnexpectedResultSource` unless
  the message arrived on the resolution chain's own lane, per `_isResolutionChainSource(_srcChain)`.

Two immutables are needed because the two namespaces are disjoint: the receive path only ever learns
the transport's identifier for the source chain (for CCIP, a chain selector), never an EVM chain id,
and there is no on-chain mapping between them. Comparing a selector against a chain id would refuse
every inbound result.

The provenance comparison therefore lives in the transport, not the base. `BridgeBase` declares
`_isResolutionChainSource(uint256)` alongside its other five transport hooks and `CcipBridge`
implements it against `RESOLUTION_CHAIN_SELECTOR`, keeping CCIP's addressing out of the
transport-agnostic layer. A second transport supplies its own identifier in its own namespace.

**The receive-side checks are independent, and neither subsumes the other.** The provenance check is
what makes the topology self-enforcing: the send-side guard lives in the *sending* bridge, so it is
absent from exactly the cases it would need to cover — a peer that is upgraded (`_authorizeUpgrade`
is `onlyOwner`), misconfigured, or compromised. Without it, a spoke could resolve conditions on every
other spoke it is peered with. The identity check remains necessary because a peer may be configured
for the resolution chain's own selector (`_validateChain` admits any non-zero `uint64`, including the
local chain's), which satisfies the provenance check by construction and would otherwise let the hub
import a result. Both are pinned by tests — `test_revert_CcipBridge_receiveResult_fromSpokePeer` and
`test_revert_CcipBridge_receiveResult_hubSelfLane` — and removing either one turns the other's test
red. Do not collapse them into a single comparison.

Only results are direction-bound. Positions and collateral are deliberately lane-agnostic, since
spoke-to-spoke transfers are supported.

Because the role is derived from `block.chainid` rather than asserted outright, a hub implementation
deployed to the wrong network reads as a spoke — the direction that refuses to export. The
`BridgeBase` constructor rejects a zero chain id with `InvalidResolutionChainId`, since zero names no
chain. `CcipBridge`'s rejects a zero selector with `InvalidResolutionChainSelector`, and one above the
`uint64` selector range with `InvalidChainSelector`, since neither could ever appear as a source chain
and both would refuse every inbound result.

Condition IDs also carry a `resolutionChain` field (see [position-ids.md](./position-ids.md)) that
the modules check on the resolver path. The bridge does not read it: the enum names the logical
resolution chain and is `POLYGON` on testnet deployments too, so the physical chain id and selector
have to come from deploy configuration.

### Bridgeable position types

Position bridging is an **allowlist**, not a blocklist. `_isBridgeablePositionModule(moduleId)`
admits only `BINARY` and `NEGRISK`, and both the outbound (`_sendPositionsMessage`) and inbound
(`_handlePositionsReceive`) paths consult it, reverting `PositionTypeNotSupported` otherwise. A
module added later is therefore refused by default rather than depending on someone remembering to
add a blocklist entry.

The inbound path is the one that needs this. Outbound is already opt-in per route via
`moduleSupported[moduleId][dstChain]`, but inbound has no per-route configuration of its own — it
would otherwise accept a batch purely on the strength of the *sending* chain's configuration.

Only modules whose positions carry their full meaning in the ID belong on the allowlist. A binary or
neg-risk ID is a label whose value is pushed to it by a resolver, so it means the same thing
wherever it lands.

**Combinatorial positions (`moduleId = 3`) are deliberately not bridgeable.** They fail that test: a
combinatorial ID *pulls* its meaning from `legs[conditionId]`, which is per-chain state, and the ID
commits to that array in only 128 bits. Two chains can each bind a different array to the same ID as
a legitimate first write, and a position payload carries only an ID and an amount, which is not
enough to detect the divergence on the destination.

They are excluded by omission from the allowlist rather than by a dedicated check, so both paths
revert `PositionTypeNotSupported` regardless of `moduleSupported` configuration. `CombinatorialModule`
exposes no bridge mint or burn entry point either, so the invariant does not depend on a particular
transport, on role hygiene, or on a future `IBridge` implementation inheriting this base.

Supporting them later needs one of:

- **Transport the definition.** Extend the payload to `(positionId, amount, legs[])`, bind it on
  receive through the module's guarded write, and require the derived conditionId to match the
  bridged one. Divergence then surfaces as a `ConditionDefinitionMismatch` revert instead of a
  silent repricing. Still leaves a 2^64 grind able to brick a route (denial of service, not theft).
- **Widen the commitment.** A combinatorial ID leaves `arity` (16 bits) and `reserved` (64 bits)
  unused, so the base hash could grow from 128 to 208 bits — 104-bit collision resistance, which
  removes the security dependency and leaves definition transport as a pure operability concern.
  Breaking: it rewrites every existing combinatorial ID.

Until then, the supported path is to bridge collateral and construct the combinatorial position
locally on the destination chain, where its definition is bound by the local `legs[]` write.

## Module Support Gating

`moduleSupported[moduleId][dstChain]` controls which modules can bridge to which chains.

| Function | Access | Description |
|----------|--------|-------------|
| `setModuleSupported(module, dstChain, supported)` | Owner | Enable/disable a module for a destination. Takes the local module **address** and validates it is registered on the PositionManager under its self-reported `moduleId()` |
| `setBatchModuleSupported(module, dstChains, supported)` | Owner | Batch version |

Checked on the send side for positions and results.

This mapping cannot enable combinatorial position bridging: module 3 is rejected explicitly
on both position send and receive paths.

## Pause Management

Send and receive paths can be paused independently, both globally and per remote chain:

| Flag | Modifier | Effect |
|------|----------|--------|
| `sendPaused` | `whenSendUnpaused(dstChain)` | Blocks all outbound bridging |
| `receivePaused` | `whenReceiveUnpaused(srcChain)` | Blocks all inbound message processing |
| `chainSendPaused[chain]` | `whenSendUnpaused(dstChain)` | Blocks outbound bridging to one chain |
| `chainReceivePaused[chain]` | `whenReceiveUnpaused(srcChain)` | Blocks inbound message processing from one chain |

| Function | Access | Description |
|----------|--------|-------------|
| `pauseSend()` / `unpauseSend()` | Admin | Toggle global outbound pause |
| `pauseReceive()` / `unpauseReceive()` | Admin | Toggle global inbound pause |
| `pauseChainSend(chain)` / `unpauseChainSend(chain)` | Admin | Toggle per-chain outbound pause |
| `pauseChainReceive(chain)` / `unpauseChainReceive(chain)` | Admin | Toggle per-chain inbound pause |

Per-chain pause is the incident-response tool for disabling a single lane without touching peer configuration; `removePeer` remains the owner-gated permanent kill switch. Paused receives revert and can be retried via CCIP manual execution after unpausing.

## Replay Behavior

Result messages are safe to replay. The receiving module treats a bridge-role `reportResult` as follows (see [Modules — Result Reporting & Replays](modules.md#result-reporting--replays)):

- **Matching replay** (payouts equal the stored result): returns silently — a redelivered or re-sent result message is a no-op.
- **Conflicting replay** (payouts differ from the stored result): reverts `ExistingPayoutMismatch`.
- **Migration conditions**: the module resolves from the legacy CTF and verifies the bridged payouts against the CTF-derived result.

Position and collateral messages are mint instructions, not idempotent — the transport's exactly-once delivery (CCIP) is relied on for those.

## Configuration

### CcipBridge

CcipBridge is deployed behind an ERC1967 proxy. The implementation constructor pins the
CCIP router, PositionManager, collateral token, resolution chain id, and resolution chain selector as
immutables, and the proxy is initialized with `initialize(owner, admin)`. Upgrades are
owner-authorized and may intentionally point to an implementation with different immutable
dependencies — including a different `RESOLUTION_CHAIN_ID`, which changes whether that deployment may
export results, or a different `RESOLUTION_CHAIN_SELECTOR`, which changes which lane it accepts results
from.

Peers are `bytes32` identifiers — left-padded addresses for EVM chains, raw 32-byte
identifiers for future non-EVM chains.

| Function | Access | Description |
|----------|--------|-------------|
| `setPeer(chainSelector, peer)` | Owner | Set CCIP peer (bytes32) for a destination chain |
| `removePeer(chainSelector)` | Owner | Remove a CCIP peer |
| `addAdmin(addr)` / `removeAdmin(addr)` | Owner | Manage admins (Solady `ADMIN_ROLE` / `_ROLE_0`) |

## Payload Encoding

Source: `src/libraries/BridgePayloads.sol`

Each message is encoded as `bytes1(MessageType) ++ abi.encode(payload)`. The library provides pure encoding functions: `positions(recipient, BridgedPosition[])`, `collateral(recipient, amount)`, and `result(conditionId, result)`. Result payloads carry the `ConditionId` as its underlying `bytes31`; the strict ABI decoder on the receive side rejects non-zero padding, preserving canonicality at the wire boundary.

## Cross-Chain Types

Source: `src/libraries/CrossChainTypes.sol`

| Type | Values |
|------|--------|
| `MessageType` | `POSITIONS`, `COLLATERAL`, `RESULT` |
| `BridgedPosition` | `{ PositionId positionId, uint256 amount }` |

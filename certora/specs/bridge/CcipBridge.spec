// ============================================================
// [BRIDGE-01] CcipBridge — a burn on the source chain is followed by an
// equivalent mint on the destination chain.
//
// Property is decomposed into:
//
//   SOURCE FIDELITY   bridgePositions / bridgeCollateral burn exactly the
//                     tuple they encode into the outbound message.
//   GENERIC FRAME     value is destroyed only alongside an outbound message, 
//                     created only by ccipReceive, and messages originate 
//                     only from the three bridge entry points.
//   DELIVERABILITY    liveness: a destination chain must be
//                     able to execute the mint.
// ============================================================

/*
 * MODULE
 * @module CcipBridge Cross-Chain Fidelity
 * @contract CcipBridge
 * @impact A transfer could mint more than was burned, or be delivered by an untrusted sender, forging value across chains
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 4 iterations
 * @global_assumption The legacy condition-id helpers are replaced by CVL models or over-approximated
 * @global_assumption Bridge mint and burn effects on the position manager are summarized with CVL models
 * @global_assumption The CCIP message send is handled by a CVL model acting as the router
 * PROPERTIES
 * @property BRIDGE-01 A burn on the source chain is followed by an equivalent mint on the destination chain.
 * @property BRIDGE-ALLOWLIST-01 A position whose module is not on the bridgeable allowlist is refused on both the send and the receive path.
 * @property BRIDGE-RESULT-01 A result leaves only the resolution chain, and is accepted only off it, only on its lane.
 */

import "../summaries/CcipBridge_base_summaries.spec";
import "../summaries/CcipBridge_call_resolution.spec";

methods {
    // ---- CcipBridge views (envfree) ----
    function peers(uint256) external returns (bytes32) envfree;
    function getRouter() external returns (address) envfree;
    function receivePaused() external returns (bool) envfree;
    function RESOLUTION_CHAIN_ID() external returns (uint256) envfree;
    function localChainId() external returns (uint256);
    function RESOLUTION_CHAIN_SELECTOR() external returns (uint256) envfree;
    function chainReceivePaused(uint256) external returns (bool) envfree;

    // ---- harness helpers (pure, envfree) — see certora/harnesses/CcipBridge.sol ----
    function buildPositionsPayload(bytes32, CcipBridge.PositionId[], uint256[]) external returns (bytes) envfree;
    function buildCollateralPayload(bytes32, uint256) external returns (bytes) envfree;
    function buildResultPayload(CcipBridge.ConditionId, uint256[]) external returns (bytes) envfree;
    function encodeAddress(address) external returns (bytes) envfree;
    function encodeBytes32(bytes32) external returns (bytes) envfree;
    function pidToUint(CcipBridge.PositionId) external returns (uint256) envfree;
    function addressToRecipient(address) external returns (bytes32) envfree;
    function sentCount() external returns (uint256) envfree;
    function sentMsgType(uint256) external returns (uint8) envfree;
    function sentRecipient(uint256) external returns (bytes32) envfree;
    function sentAmount(uint256) external returns (uint256) envfree;
    function sentLegCount(uint256) external returns (uint256) envfree;
    function sentLegId(uint256, uint256) external returns (uint256) envfree;
    function sentLegAmount(uint256, uint256) external returns (uint256) envfree;

    // ---- CollateralToken (REAL in scene, linked) — reads only ----
    function CollateralToken.totalSupply() external returns (uint256) envfree;
    function CollateralToken.balanceOf(address) external returns (uint256) envfree;
}

// ---------------------------------------------------------------
//  definitions
// ---------------------------------------------------------------

// MessageType enum values
definition POSITIONS_MSG() returns uint8 = 0;
definition COLLATERAL_MSG() returns uint8 = 1;

// ---------------------------------------------------------------
//  helpers
// ---------------------------------------------------------------

// Duplicate-aware amount a batch of up to 3 legs moves for token id q.
function batchAmountFor(
    uint256 q,
    uint256 len,
    uint256 id0,
    uint256 id1,
    uint256 id2,
    uint256 a0,
    uint256 a1,
    uint256 a2
) returns mathint {
    mathint s0 = (len > 0 && id0 == q) ? to_mathint(a0) : 0;
    mathint s1 = (len > 1 && id1 == q) ? to_mathint(a1) : 0;
    mathint s2 = (len > 2 && id2 == q) ? to_mathint(a2) : 0;
    return s0 + s1 + s2;
}

// CollateralToken state integrity (single account).
function requireCollateralCoherence() {
    require CollateralToken.balanceOf(currentContract) <= CollateralToken.totalSupply(),
        "reachable state: the bridge's pUSD balance never exceeds total supply";
}

// CollateralToken state integrity (two accounts). Same assumption as above.
function requireCollateralPairCoherence(address a, address b) {
    if (a == b) {
        require CollateralToken.balanceOf(a) <= CollateralToken.totalSupply(),
            "reachable state: a single balance never exceeds total supply";
    } else {
        require CollateralToken.balanceOf(a) + CollateralToken.balanceOf(b)
                <= CollateralToken.totalSupply(),
            "reachable state: two distinct balances sum within total supply";
    }
}

// ---------------------------------------------------------------
//  SOURCE FIDELITY
// ---------------------------------------------------------------

/**
 * @title bridgePositions burns what it sends
 * @description One message to the configured peer of the requested chain, carrying exactly the burned (recipient, positionIds, amounts) tuple; only the bridge's own balance is debited and no collateral moves.
 * @link_property BRIDGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule bridgePositionsBurnsWhatItSends(env e) {
    require gCcipSendCount == 0, "fresh ghost: the send log starts empty (recording ghosts are havoc'd initially)";
    require sentCount() == 0, "fresh harness recorder: the decoded-send log starts empty (read at index 0)";

    uint256 dstChain;
    CcipBridge.PositionId[] pids;
    uint256[] amounts;
    bytes32 recipient;
    bytes options;
    require pids.length <= 3 && amounts.length <= 3, "bounded proof: 3-leg batches (ghost batch helpers unroll to 3)";

    // retrieve individual ids based on pids and actual length
    uint256 id0 = pids.length > 0 ? pidToUint(pids[0]) : 0;
    uint256 id1 = pids.length > 1 ? pidToUint(pids[1]) : 0;
    uint256 id2 = pids.length > 2 ? pidToUint(pids[2]) : 0;

    // Allow any holder / token id / collateral state
    address holder;
    uint256 q;
    mathint balBefore = ghostBalance[holder][q];
    mathint supBefore = ghostSupply[q];
    mathint colSupBefore = CollateralToken.totalSupply();

    bridgePositions(e, dstChain, pids, amounts, recipient, options);

    // exactly one outbound message, to the requested chain, addressed to its peer
    assert gCcipSendCount == 1, "bridgePositions must send exactly one message";
    assert to_mathint(gCcipDstChain[0]) == to_mathint(dstChain), "message goes to the requested chain selector";
    assert gCcipReceiverHash[0] == keccak256(encodeBytes32(peers(dstChain))),
        "message is addressed to the configured peer bridge";

    // Payload fidelity: the burned tuple is the message, compared as the decoded scalar
    // tuple recorded by the harness _transportSend override.
    assert sentMsgType(0) == POSITIONS_MSG(), "the message is a POSITIONS message";
    assert sentRecipient(0) == recipient, "the message carries exactly the requested recipient";
    assert to_mathint(sentLegCount(0)) == to_mathint(pids.length),
        "the message carries exactly one leg per bridged position";
    assert pids.length > 0 => (sentLegId(0, 0) == id0 && sentLegAmount(0, 0) == amounts[0]),
        "leg 0 carries exactly (id, amount) of position 0";
    assert pids.length > 1 => (sentLegId(0, 1) == id1 && sentLegAmount(0, 1) == amounts[1]),
        "leg 1 carries exactly (id, amount) of position 1";
    assert pids.length > 2 => (sentLegId(0, 2) == id2 && sentLegAmount(0, 2) == amounts[2]),
        "leg 2 carries exactly (id, amount) of position 2";

    // Supply drops by exactly the bridged amounts, debited from the
    // bridge's own balance (pre-transferred positions); the module nets to zero
    mathint moved = batchAmountFor(q, pids.length, id0, id1, id2, amounts[0], amounts[1], amounts[2]);
    assert ghostSupply[q] == supBefore - moved, "supply of every id drops by exactly the bridged amount";
    assert ghostBalance[holder][q] == balBefore - (holder == currentContract ? moved : 0),
        "only the bridge's balance is debited, by exactly the bridged amount";

    // cross-asset frame
    assert to_mathint(CollateralToken.totalSupply()) == colSupBefore, "collateral is untouched by position bridging";
}

/**
 * @title bridgeCollateral burns what it sends
 * @description One message to the configured peer carrying exactly (recipient, amount); collateral supply and the bridge's own balance both drop by that amount and positions are untouched.
 * @link_property BRIDGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule bridgeCollateralBurnsWhatItSends(env e) {
    require gCcipSendCount == 0, "fresh ghost: the send log starts empty";
    require sentCount() == 0, "fresh harness recorder: the decoded-send log starts empty (read at index 0)";

    uint256 dstChain;
    uint256 amount;
    bytes32 recipient;
    bytes options;
    requireCollateralCoherence();

    address holder;
    uint256 q;
    mathint colSupBefore = CollateralToken.totalSupply();
    mathint colBalBefore = CollateralToken.balanceOf(holder);
    mathint supBefore = ghostSupply[q];

    bridgeCollateral(e, dstChain, amount, recipient, options);

    assert gCcipSendCount == 1, "bridgeCollateral must send exactly one message";
    assert to_mathint(gCcipDstChain[0]) == to_mathint(dstChain), "message goes to the requested chain selector";
    assert gCcipReceiverHash[0] == keccak256(encodeBytes32(peers(dstChain))),
        "message is addressed to the configured peer bridge";

    // Payload fidelity via decoded scalars — see bridgePositionsBurnsWhatItSends.
    assert sentMsgType(0) == COLLATERAL_MSG(), "the message is a COLLATERAL message";
    assert sentRecipient(0) == recipient, "the message carries exactly the requested recipient";
    assert sentAmount(0) == amount, "the message carries exactly the burned amount";

    assert to_mathint(CollateralToken.totalSupply()) == colSupBefore - amount,
        "collateral supply drops by exactly the bridged amount";
    assert to_mathint(CollateralToken.balanceOf(holder))
            == colBalBefore - (holder == currentContract ? to_mathint(amount) : 0),
        "only the bridge's own collateral balance is debited";

    assert ghostSupply[q] == supBefore, "positions are untouched by collateral bridging";
}

/**
 * @title bridgeResult moves no value
 * @description bridgeResult pushes resolution data only: exactly one message, and no mint or burn of positions or collateral.
 * @link_property BRIDGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule bridgeResultMovesNoValue(env e) {
    require gCcipSendCount == 0, "fresh ghost: the send log starts empty";
    require sentCount() == 0, "fresh harness recorder: the decoded-send log starts empty (read at index 0)";

    uint256 dstChain;
    CcipBridge.ConditionId conditionId;
    bytes options;

    uint256 q;
    address holder;
    mathint balBefore = ghostBalance[holder][q];
    mathint supBefore = ghostSupply[q];
    mathint colSupBefore = CollateralToken.totalSupply();

    bridgeResult(e, dstChain, conditionId, options);

    assert gCcipSendCount == 1, "bridgeResult must send exactly one message";
    assert ghostSupply[q] == supBefore && ghostBalance[holder][q] == balBefore,
        "result bridging burns and mints no positions";
    assert to_mathint(CollateralToken.totalSupply()) == colSupBefore, "result bridging moves no collateral";
}

// ---------------------------------------------------------------
//  RESULT ROUTING — one hop out of the resolution chain
// ---------------------------------------------------------------

/**
 * @title a result may only be exported from the resolution chain
 * @description bridgeResult reverts on every chain other than the resolution chain.
 * @link_property BRIDGE-RESULT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule resultExportOnlyFromResolutionChain(env e) {
    uint256 dstChain;
    CcipBridge.ConditionId conditionId;
    bytes options;

    bridgeResult@withrevert(e, dstChain, conditionId, options);
    bool reverted = lastReverted;

    assert localChainId(e) != RESOLUTION_CHAIN_ID() => reverted,
        "a result may only be exported from the resolution chain";
    satisfy localChainId(e) != RESOLUTION_CHAIN_ID();
}

/**
 * @title the resolution chain never accepts an inbound result
 * @description A RESULT message delivered to the chain that produced it reverts.
 * @link_property BRIDGE-RESULT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule resultReceiveRejectedOnResolutionChain(
    env e, bytes32 messageId, uint64 srcSel, address srcSender,
    CcipBridge.ConditionId condId, uint256[] resultData
) {
    require resultData.length <= 4, "bounded proof: matches the scene's loop_iter";
    bytes payload = buildResultPayload(condId, resultData);

    deliverMessage@withrevert(e, messageId, srcSel, srcSender, payload);
    bool reverted = lastReverted;

    assert localChainId(e) == RESOLUTION_CHAIN_ID() => reverted,
        "the resolution chain must refuse an inbound result";
    satisfy localChainId(e) == RESOLUTION_CHAIN_ID();
}

/**
 * @title an inbound result is only accepted on the resolution chain lane
 * @description A RESULT message arriving on any lane other than the resolution chain's reverts.
 * @link_property BRIDGE-RESULT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule resultReceiveOnlyFromResolutionLane(
    env e, bytes32 messageId, uint64 srcSel, address srcSender,
    CcipBridge.ConditionId condId, uint256[] resultData
) {
    require resultData.length <= 4, "bounded proof: matches the scene's loop_iter";
    bytes payload = buildResultPayload(condId, resultData);

    deliverMessage@withrevert(e, messageId, srcSel, srcSender, payload);
    bool reverted = lastReverted;

    assert srcSel != RESOLUTION_CHAIN_SELECTOR() => reverted,
        "an inbound result is only accepted on the resolution chain's own lane";
    satisfy srcSel != RESOLUTION_CHAIN_SELECTOR();
}

// ---------------------------------------------------------------
//  DESTINATION FIDELITY
// ---------------------------------------------------------------

/**
 * @title receiving positions mints what was sent
 * @description A POSITIONS receive credits only the decoded recipient, by exactly the per-id amounts the payload carries, moves no collateral, and sends nothing onward.
 * @link_property BRIDGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule receivePositionsMintsWhatWasSent(env e) {
    require gCcipSendCount == 0, "fresh ghost: the send log starts empty";
    require sentCount() == 0, "fresh harness recorder: the decoded-send log starts empty (read at index 0)";

    address recipient;
    CcipBridge.PositionId[] pids;
    uint256[] amounts;
    require pids.length <= 3 && amounts.length <= 3, "bounded proof: 3-leg batches";

    uint256 id0 = pids.length > 0 ? pidToUint(pids[0]) : 0;
    uint256 id1 = pids.length > 1 ? pidToUint(pids[1]) : 0;
    uint256 id2 = pids.length > 2 ? pidToUint(pids[2]) : 0;

    bytes payload = buildPositionsPayload(addressToRecipient(recipient), pids, amounts);
    bytes32 messageId;
    uint64 srcChainSel;
    address srcSender;

    address holder;
    uint256 q;
    mathint balBefore = ghostBalance[holder][q];
    mathint supBefore = ghostSupply[q];
    mathint colSupBefore = CollateralToken.totalSupply();

    // harnessed method to execute a message in the dst chain
    deliverMessage(e, messageId, srcChainSel, srcSender, payload);

    mathint minted = batchAmountFor(q, pids.length, id0, id1, id2, amounts[0], amounts[1], amounts[2]);
    assert ghostSupply[q] == supBefore + minted, "supply of every id grows by exactly the received amount";
    assert ghostBalance[holder][q] == balBefore + (holder == recipient ? minted : 0),
        "only the decoded recipient is credited, by exactly the received amount";
    assert to_mathint(CollateralToken.totalSupply()) == colSupBefore, "collateral is untouched by a POSITIONS receive";
    assert gCcipSendCount == 0, "receiving mints locally and sends nothing onward";
}

/**
 * @title receiving collateral mints what was sent
 * @description A COLLATERAL receive credits only the decoded recipient, by exactly the decoded amount, touches no positions, and sends nothing onward.
 * @link_property BRIDGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule receiveCollateralMintsWhatWasSent(env e) {
    require gCcipSendCount == 0, "fresh ghost: the send log starts empty";
    require sentCount() == 0, "fresh harness recorder: the decoded-send log starts empty (read at index 0)";

    address recipient;
    uint256 amount;
    requireCollateralPairCoherence(recipient, recipient);

    // delivered via the harness function deliverMessage
    bytes payload = buildCollateralPayload(addressToRecipient(recipient), amount);
    bytes32 messageId;
    uint64 srcChainSel;
    address srcSender;

    address holder;
    uint256 q;
    mathint colSupBefore = CollateralToken.totalSupply();
    mathint colBalBefore = CollateralToken.balanceOf(holder);
    mathint supBefore = ghostSupply[q];

    deliverMessage(e, messageId, srcChainSel, srcSender, payload);

    assert to_mathint(CollateralToken.totalSupply()) == colSupBefore + amount,
        "collateral supply grows by exactly the received amount";
    assert to_mathint(CollateralToken.balanceOf(holder))
            == colBalBefore + (holder == recipient ? to_mathint(amount) : 0),
        "only the decoded recipient is credited";
    assert ghostSupply[q] == supBefore, "positions are untouched by a COLLATERAL receive";
    assert gCcipSendCount == 0, "receiving mints locally and sends nothing onward";
}

/**
 * @title only trusted messages are processed
 * @description ccipReceive reverts unless the caller is the CCIP router and the decoded sender is the registered peer of the source chain selector.
 * @link_property BRIDGE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule receiveAuth(env e) {
    Client.Any2EVMMessage m;
    bytes32 decodedSender;
    require keccak256(m.sender) == keccak256(encodeBytes32(decodedSender)),
        "couples m.sender to its hashed bytes32 decode.";

    ccipReceive@withrevert(e, m);
    bool reverted = lastReverted;

    assert e.msg.sender != getRouter() => reverted, "only the CCIP router may deliver";
    assert peers(require_uint256(m.sourceChainSelector)) != decodedSender => reverted,
        "only the registered peer of the source chain is trusted";

    satisfy !reverted, "witness: an honest delivery goes through";
}

// ---------------------------------------------------------------
//  DELIVERABILITY 
// ---------------------------------------------------------------

/**
 * @title sent positions are deliverable
 * @description Every accepted POSITIONS send executes on an honestly-configured destination, for an unconstrained recipient.
 * @link_property BRIDGE-01
 * @status VERIFIED AFTER FIX
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule sentPositionsAreDeliverable(env eSrc, env eDst) {
    require gCcipSendCount == 0, "fresh ghost: the send log starts empty";
    require sentCount() == 0, "fresh harness recorder: the decoded-send log starts empty (read at index 0)";

    uint256 dstChain;
    CcipBridge.PositionId[] pids;
    uint256[] amounts;
    bytes32 recipient; // unconstrained, can be an invalid address
    bytes options;
    require pids.length <= 3 && amounts.length <= 3, "bounded proof: 3-leg batches (ghost batch helpers unroll to 3)";

    bridgePositions(eSrc, dstChain, pids, amounts, recipient, options);

    require !receivePaused(), "honest config: receiving is not paused";
    bytes sentPayload = buildPositionsPayload(recipient, pids, amounts);
    bytes32 messageId;
    uint64 srcChainSel;
    address srcSender;
    require peers(require_uint256(srcChainSel)) == addressToRecipient(srcSender),
        "honest config: the destination trusts the source bridge as its peer";
    require !chainReceivePaused(require_uint256(srcChainSel)),
        "honest config: receiving from the source chain is not paused";
    require eDst.msg.value == 0, "deliverMessage is non-payable";

    deliverMessage@withrevert(eDst, messageId, srcChainSel, srcSender, sentPayload);

    assert !lastReverted, "every sent positions message must be deliverable on an honest destination";
}

/**
 * @title sent collateral is deliverable
 * @description Every accepted COLLATERAL send executes on an honestly-configured destination, for an unconstrained recipient.
 * @link_property BRIDGE-01
 * @status VERIFIED AFTER FIX
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule sentCollateralIsDeliverable(env eSrc, env eDst) {
    require gCcipSendCount == 0, "fresh ghost: the send log starts empty";
    require sentCount() == 0, "fresh harness recorder: the decoded-send log starts empty (read at index 0)";

    uint256 dstChain;
    uint256 amount;
    bytes32 recipient; // unconstrained, can be an invalid address
    bytes options;
    requireCollateralCoherence();

    bridgeCollateral(eSrc, dstChain, amount, recipient, options);

    require !receivePaused(), "honest config: receiving is not paused";
    bytes sentPayload = buildCollateralPayload(recipient, amount);
    bytes32 messageId;
    uint64 srcChainSel;
    address srcSender;
    require peers(require_uint256(srcChainSel)) == addressToRecipient(srcSender),
        "honest config: the destination trusts the source bridge as its peer";
    require !chainReceivePaused(require_uint256(srcChainSel)),
        "honest config: receiving from the source chain is not paused";
    require eDst.msg.value == 0, "deliverMessage is non-payable";

    deliverMessage@withrevert(eDst, messageId, srcChainSel, srcSender, sentPayload);

    assert !lastReverted, "every sent collateral message must be deliverable on an honest destination";
}
/*--------------------------------------------------------------
    BRIDGE-ALLOWLIST-01 — only allowlisted position modules bridge
--------------------------------------------------------------*/

definition MODULE_BINARY() returns mathint = 1;
definition MODULE_NEGRISK() returns mathint = 2;

/**
 * @title a non-bridgeable module is refused on the send path
 * @description bridgePositions reverts for a position whose module is not on the bridgeable allowlist
 * @link_property BRIDGE-ALLOWLIST-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule bridgeRejectsNonBridgeableModule(env e) {
    uint256 dstChain;
    CcipBridge.PositionId[] pids;
    uint256[] amounts;
    bytes32 recipient;
    bytes options;

    mathint m = moduleIdOf(pidToUint(pids[0]));
    require m != MODULE_BINARY() && m != MODULE_NEGRISK(), "a module outside the bridgeable allowlist";

    bridgePositions@withrevert(e, dstChain, pids, amounts, recipient, options);

    assert lastReverted, "a position outside the allowlist must not be sent";
}

/**
 * @title a non-bridgeable module is refused on the receive path
 * @description Delivering a POSITIONS message whose module is not on the bridgeable allowlist reverts
 * @link_property BRIDGE-ALLOWLIST-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/aea3ea864a804aedac7679f68f1e120d?anonymousKey=0c169fdc29b373de264ba0fcaee0fbfce86e0861
 */
rule receiveRejectsNonBridgeableModule(env e) {
    address recipient;
    CcipBridge.PositionId[] pids;
    uint256[] amounts;
    bytes32 messageId;
    uint64 srcChainSel;
    address srcSender;

    mathint m = moduleIdOf(pidToUint(pids[0]));
    require m != MODULE_BINARY() && m != MODULE_NEGRISK(), "a module outside the bridgeable allowlist";

    bytes payload = buildPositionsPayload(addressToRecipient(recipient), pids, amounts);
    deliverMessage@withrevert(e, messageId, srcChainSel, srcSender, payload);

    assert lastReverted, "a position outside the allowlist must not be minted on receipt";
}

// Ghost-recording summary for IRouterClient.ccipSend.
//
// The CCIP Router is not part of the verification scene (see the unresolved
// `i_ccipRouter` link in the call-resolution report), so the ccipSend call made by
// CcipBridge._transportSend is unresolved. This wildcard summary intercepts it and
// logs every outbound message into ghosts, indexed by send order, so rules can
// assert on what was sent and how many times.
//
// Dynamic fields (receiver / data / extraArgs) cannot live in ghosts directly, so
// their keccak256 fingerprints are stored instead — a rule can compare them against
// the hash of an expected encoding. Hashing unbounded bytes is subject to the
// prover's hashing bound; add `"optimistic_hashing": true` (with a suitable
// `hashing_length_bound`) to the conf if hashing asserts start firing.
//
// Usage in rules: `require gCcipSendCount == 0;` at the start (the recording
// mappings are havoc'd initially), then check gCcipSendCount / gCcip*[i] after
// the call.

// number of CCIP messages sent through the router
ghost uint256 gCcipSendCount {
    init_state axiom gCcipSendCount == 0;
}

// per-message log, keyed by send order (0-based)
ghost mapping(uint256 => uint64) gCcipDstChain; // destinationChainSelector
ghost mapping(uint256 => bytes32) gCcipReceiverHash; // keccak256(message.receiver)
ghost mapping(uint256 => bytes32) gCcipDataHash; // keccak256(message.data)
ghost mapping(uint256 => bytes32) gCcipExtraArgsHash; // keccak256(message.extraArgs)
ghost mapping(uint256 => address) gCcipFeeToken; // message.feeToken
ghost mapping(uint256 => uint256) gCcipNumTokenAmounts; // message.tokenAmounts.length
ghost mapping(uint256 => uint256) gCcipMsgValue; // native fee attached to the call

function ccipSendCVL(env e, uint64 _dstChainSelector, Client.EVM2AnyMessage _message) returns bytes32 {
    gCcipDstChain[gCcipSendCount] = _dstChainSelector;
    gCcipReceiverHash[gCcipSendCount] = keccak256(_message.receiver);
    gCcipDataHash[gCcipSendCount] = keccak256(_message.data);
    gCcipExtraArgsHash[gCcipSendCount] = keccak256(_message.extraArgs);
    gCcipFeeToken[gCcipSendCount] = _message.feeToken;
    gCcipNumTokenAmounts[gCcipSendCount] = _message.tokenAmounts.length;
    gCcipMsgValue[gCcipSendCount] = e.msg.value;
    gCcipSendCount = require_uint256(gCcipSendCount + 1);

    bytes32 messageId; // unconstrained, as the router's return value is arbitrary
    return messageId;
}

methods {
    function _.ccipSend(uint64 destinationChainSelector, Client.EVM2AnyMessage message) external
        with (env e) => ccipSendCVL(e, destinationChainSelector, message) expect bytes32;
}
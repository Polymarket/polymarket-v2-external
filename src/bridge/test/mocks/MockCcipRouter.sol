// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/// @title MockCcipRouter
/// @notice Simple mock of Chainlink CCIP Router for testing
contract MockCcipRouter is IRouterClient {
    uint64 public immutable chainSelector;

    // Track sent messages for verification
    struct SentMessage {
        uint64 destChainSelector;
        bytes receiver;
        bytes data;
        bytes extraArgs;
        uint256 nativeFee;
    }

    SentMessage[] public sentMessages;
    uint256 public nonce;

    // For quote simulation
    uint256 public quoteFee = 0.001 ether;

    constructor(uint64 _chainSelector) {
        chainSelector = _chainSelector;
    }

    function isChainSupported(uint64) external pure returns (bool) {
        return true;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory _message) external view returns (uint256) {
        return quoteFee + (_message.data.length * 100);
    }

    function ccipSend(uint64 _destChainSelector, Client.EVM2AnyMessage calldata _message)
        external
        payable
        returns (bytes32)
    {
        nonce++;

        // Store sent message for test verification
        sentMessages.push(
            SentMessage({
                destChainSelector: _destChainSelector,
                receiver: _message.receiver,
                data: _message.data,
                extraArgs: _message.extraArgs,
                nativeFee: msg.value
            })
        );

        return keccak256(abi.encode(chainSelector, _destChainSelector, nonce, _message.data));
    }

    // Test helpers

    function getSentMessageCount() external view returns (uint256) {
        return sentMessages.length;
    }

    function getLastSentMessage() external view returns (SentMessage memory) {
        require(sentMessages.length > 0, "No messages sent");
        return sentMessages[sentMessages.length - 1];
    }

    function setQuoteFee(uint256 _fee) external {
        quoteFee = _fee;
    }

    function clearMessages() external {
        delete sentMessages;
    }

    /// @notice Simulate receiving a message (for testing receive path)
    /// @param _srcChainSelector Source chain selector
    /// @param _sender Sender address on source chain
    /// @param _receiver Receiver CCIPReceiver address
    /// @param _data The message payload
    function simulateReceive(uint64 _srcChainSelector, address _sender, address _receiver, bytes calldata _data)
        external
    {
        _deliver(_srcChainSelector, abi.encode(_sender), _receiver, _data);
    }

    /// @notice Simulate receiving a message with raw sender bytes (e.g. non-EVM senders)
    /// @param _srcChainSelector Source chain selector
    /// @param _sender Raw sender bytes as delivered by the offramp
    /// @param _receiver Receiver CCIPReceiver address
    /// @param _data The message payload
    function simulateReceiveRaw(
        uint64 _srcChainSelector,
        bytes calldata _sender,
        address _receiver,
        bytes calldata _data
    ) external {
        _deliver(_srcChainSelector, _sender, _receiver, _data);
    }

    function _deliver(uint64 _srcChainSelector, bytes memory _sender, address _receiver, bytes calldata _data)
        internal
    {
        nonce++;
        bytes32 messageId = keccak256(abi.encode(_srcChainSelector, chainSelector, nonce, _data));

        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: _srcChainSelector,
            sender: _sender,
            data: _data,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        // Call ccipReceive on the receiver - this works because msg.sender is this contract
        // (the router), which satisfies CCIPReceiver's onlyRouter modifier
        IAny2EVMMessageReceiver(_receiver).ccipReceive(message);
    }
}

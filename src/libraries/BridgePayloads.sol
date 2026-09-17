// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

import { ConditionId } from "./Ids.sol";
import { MessageType, BridgedPosition } from "./CrossChainTypes.sol";

/// @title BridgePayloads
/// @notice Shared payload encoding for cross-chain bridge messages
/// @dev Transport-agnostic: used by BridgeBase and its transport implementations
///      (currently CcipBridge). All functions are internal pure and get inlined
///      by the compiler.
library BridgePayloads {
    /// @notice Encodes a positions bridge payload.
    /// @param _recipient The recipient on the destination chain.
    /// @param _positions Array of bridged position data.
    /// @return The encoded payload.
    function positions(bytes32 _recipient, BridgedPosition[] memory _positions) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(MessageType.POSITIONS)), abi.encode(_recipient, _positions));
    }

    /// @notice Encodes a collateral bridge payload.
    /// @param _recipient The recipient on the destination chain.
    /// @param _amount The amount of collateral.
    /// @return The encoded payload.
    function collateral(bytes32 _recipient, uint256 _amount) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), abi.encode(_recipient, _amount));
    }

    /// @notice Encodes a result bridge payload.
    /// @dev `_conditionId` ABI-encodes as its underlying bytes31; the strict ABI decoder on
    ///      the receive side rejects payloads with non-zero padding, preserving the
    ///      canonicality guard at the wire boundary.
    /// @param _conditionId The condition identifier.
    /// @param _result The payout vector.
    /// @return The encoded payload.
    function result(ConditionId _conditionId, uint256[] memory _result) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(uint8(MessageType.RESULT)), abi.encode(_conditionId, _result));
    }
}

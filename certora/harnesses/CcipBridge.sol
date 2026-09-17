// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CcipBridge as CcipBridgeBase } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import { BridgePayloads } from "@polymarket-v2/src/libraries/BridgePayloads.sol";
import { BridgedPosition, MessageType } from "@polymarket-v2/src/libraries/CrossChainTypes.sol";
import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title CcipBridge verification harness
/// @notice Extends the production CcipBridge with pure helpers the BRIDGE-01 spec needs but CVL
///         cannot express (abi encoding of payloads / addresses, UDVT unwrapping). Named
///         `CcipBridge` (rename-import of the base) so specs, links and UDVT qualifiers written
///         against the production name keep resolving when this harness replaces it in scene.
contract CcipBridge is CcipBridgeBase {
    constructor(
        address _router,
        address _positionManager,
        address _collateralToken,
        uint256 _resolutionChainId,
        uint256 _resolutionChainSelector
    ) CcipBridgeBase(_router, _positionManager, _collateralToken, _resolutionChainId, _resolutionChainSelector) { }

    /// @notice The exact positions wire payload for (recipient, positionIds, amounts).
    function buildPositionsPayload(
        bytes32 _recipient,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts
    ) external pure returns (bytes memory) {
        uint256 length = _positionIds.length;
        BridgedPosition[] memory positions = new BridgedPosition[](length);
        for (uint256 i = 0; i < length; ++i) {
            positions[i] = BridgedPosition({ positionId: _positionIds[i], amount: _amounts[i] });
        }
        return BridgePayloads.positions(_recipient, positions);
    }

    /// @notice The exact collateral wire payload for (recipient, amount).
    function buildCollateralPayload(bytes32 _recipient, uint256 _amount) external pure returns (bytes memory) {
        return BridgePayloads.collateral(_recipient, _amount);
    }

    /// @notice The exact result wire payload for (conditionId, result).
    function buildResultPayload(ConditionId _conditionId, uint256[] calldata _result)
        external
        pure
        returns (bytes memory)
    {
        return BridgePayloads.result(_conditionId, _result);
    }

    /// @notice `block.chainid` of the verified execution. CVL's `env` exposes only `block.number`
    ///         and `block.timestamp`, so the resolution-chain gate needs this read Solidity-side.
    function localChainId() external view returns (uint256) {
        return block.chainid;
    }

    /// @notice abi.encode of an address
    function encodeAddress(address _addr) external pure returns (bytes memory) {
        return abi.encode(_addr);
    }
    /// @notice abi.encode of a bytes32
    function encodeBytes32(bytes32 _value) external pure returns (bytes memory) {
        return abi.encode(_value);
    }

    /// @notice Unwraps a PositionId UDVT to its raw uint256.
    function pidToUint(PositionId _positionId) external pure returns (uint256) {
        return PositionId.unwrap(_positionId);
    }

    /// @notice The canonical clean bytes32 recipient encoding of an EVM address.
    function addressToRecipient(address _addr) external pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /*--------------------------------------------------------------
                     SEND RECORDING (harness storage)
    --------------------------------------------------------------*/

    /// @notice Number of transport sends recorded by the harness override.
    uint256 public sentCount;

    /// @notice MessageType byte of the i-th sent payload (0-based send order).
    mapping(uint256 => uint8) public sentMsgType;

    /// @notice Decoded recipient of the i-th sent POSITIONS / COLLATERAL payload.
    /// @dev Recorded as bytes32 (the wire type) so dirty recipients appear verbatim.
    mapping(uint256 => bytes32) public sentRecipient;

    /// @notice Decoded amount of the i-th sent COLLATERAL payload.
    mapping(uint256 => uint256) public sentAmount;

    /// @notice Decoded leg count of the i-th sent POSITIONS payload.
    mapping(uint256 => uint256) public sentLegCount;

    /// @notice Decoded position id of leg j of the i-th sent POSITIONS payload.
    mapping(uint256 => mapping(uint256 => uint256)) public sentLegId;

    /// @notice Decoded amount of leg j of the i-th sent POSITIONS payload.
    mapping(uint256 => mapping(uint256 => uint256)) public sentLegAmount;

    /// @dev Decodes the sent payload and records its tuple values, then hands off to the
    ///      production transport.
    function _transportSend(uint256 _dstChain, bytes memory _payload, bytes calldata _options)
        internal
        override
        returns (bytes32)
    {
        uint8 msgType = uint8(_payload[0]);
        bytes memory body = this.stripPrefix(_payload);

        sentMsgType[sentCount] = msgType;
        if (msgType == uint8(MessageType.POSITIONS)) {
            (bytes32 recipient, BridgedPosition[] memory positions) = abi.decode(body, (bytes32, BridgedPosition[]));
            sentRecipient[sentCount] = recipient;
            sentLegCount[sentCount] = positions.length;
            for (uint256 i = 0; i < positions.length; ++i) {
                sentLegId[sentCount][i] = PositionId.unwrap(positions[i].positionId);
                sentLegAmount[sentCount][i] = positions[i].amount;
            }
        } else if (msgType == uint8(MessageType.COLLATERAL)) {
            (bytes32 recipient, uint256 amount) = abi.decode(body, (bytes32, uint256));
            sentRecipient[sentCount] = recipient;
            sentAmount[sentCount] = amount;
        }

        ++sentCount;
        return super._transportSend(_dstChain, _payload, _options);
    }

    /// @notice Calldata slice dropping the MessageType prefix byte
    function stripPrefix(bytes calldata _data) external pure returns (bytes memory) {
        return _data[1:];
    }

    /// @notice Fallback delivery entry: builds the CCIP message struct Solidity-side and hands it
    ///         to the production `_ccipReceive`.
    function deliverMessage(bytes32 _messageId, uint64 _srcChainSelector, address _srcSender, bytes calldata _data)
        external
    {
        _ccipReceive(
            Client.Any2EVMMessage({
                messageId: _messageId,
                sourceChainSelector: _srcChainSelector,
                sender: abi.encode(_srcSender),
                data: _data,
                destTokenAmounts: new Client.EVMTokenAmount[](0)
            })
        );
    }
}
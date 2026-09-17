// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { MessageType, BridgedPosition } from "@polymarket-v2/src/libraries/CrossChainTypes.sol";
import { BridgePayloads } from "@polymarket-v2/src/libraries/BridgePayloads.sol";
import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { ICollateralToken } from "@polymarket-v2/src/collateral/interfaces/ICollateralToken.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";

/// @title BridgeBase
/// @author Polymarket
/// @notice Shared bridge logic for cross-chain position and collateral transfers
/// @dev Implements all IBridge external functions and receive-side message
///      processing. Transport-specific contracts override _transportSend,
///      _bridgeQuote, and _validateChain to plug in their messaging layer.
///      Send and receive paths can be paused independently, both globally and per remote chain.
abstract contract BridgeBase is ERC1155TokenReceiver, IBridge {
    /*--------------------------------------------------------------
                            STATE VARIABLES
    --------------------------------------------------------------*/

    /// @notice Whether outbound bridging is paused
    bool public sendPaused;

    /// @notice Whether inbound message processing is paused
    bool public receivePaused;

    /// @notice Position manager contract
    PositionManager public immutable POSITION_MANAGER;

    /// @notice Collateral token contract
    ICollateralToken public immutable COLLATERAL_TOKEN;

    /// @notice Chain id of the chain that resolves conditions and exports their results
    uint256 public immutable RESOLUTION_CHAIN_ID;

    /// @notice Module ID => Destination chain => Supported
    mapping(uint256 => mapping(uint256 => bool)) public moduleSupported;

    /// @notice Destination chain => Whether outbound bridging to it is paused
    mapping(uint256 => bool) public chainSendPaused;

    /// @notice Source chain => Whether inbound message processing from it is paused
    mapping(uint256 => bool) public chainReceivePaused;

    /// @dev Reserved storage gap padding BridgeBase to 50 slots total.
    uint256[46] private __gap;

    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when module support is set for a destination
    /// @param moduleId The module identifier
    /// @param dstChain The destination chain identifier
    /// @param supported Whether the route is supported
    event ModuleSupportedSet(uint256 indexed moduleId, uint256 indexed dstChain, bool supported);

    /// @notice Emitted when positions are bridged to another chain
    /// @param messageId The transport message identifier, for cross-chain correlation
    /// @param dstChain The destination chain identifier
    /// @param sender The address initiating the bridge
    /// @param recipient The recipient on the destination chain
    /// @param positionCount The number of positions bridged
    event PositionsBridged(
        bytes32 indexed messageId,
        uint256 indexed dstChain,
        address indexed sender,
        bytes32 recipient,
        uint256 positionCount
    );

    /// @notice Emitted when collateral is bridged to another chain
    /// @param messageId The transport message identifier, for cross-chain correlation
    /// @param dstChain The destination chain identifier
    /// @param sender The address initiating the bridge
    /// @param recipient The recipient on the destination chain
    /// @param amount The amount of collateral bridged
    event CollateralBridged(
        bytes32 indexed messageId, uint256 indexed dstChain, address indexed sender, bytes32 recipient, uint256 amount
    );

    /// @notice Emitted when a result is bridged to another chain
    /// @param messageId The transport message identifier, for cross-chain correlation
    /// @param dstChain The destination chain identifier
    /// @param conditionId The condition identifier
    event ResultBridged(bytes32 indexed messageId, uint256 indexed dstChain, ConditionId indexed conditionId);

    /// @notice Emitted when send pause state changes
    /// @param paused The new pause state
    event SendPauseSet(bool paused);

    /// @notice Emitted when receive pause state changes
    /// @param paused The new pause state
    event ReceivePauseSet(bool paused);

    /// @notice Emitted when per-chain send pause state changes
    /// @param chain The destination chain identifier
    /// @param paused The new pause state
    event ChainSendPauseSet(uint256 indexed chain, bool paused);

    /// @notice Emitted when per-chain receive pause state changes
    /// @param chain The source chain identifier
    /// @param paused The new pause state
    event ChainReceivePauseSet(uint256 indexed chain, bool paused);

    /// @notice Emitted when positions are received from another chain
    /// @param messageId The transport-specific message identifier
    /// @param recipient The recipient address
    /// @param positionId The position token ID
    /// @param amount The amount of positions received
    event PositionReceived(
        bytes32 indexed messageId, address indexed recipient, PositionId indexed positionId, uint256 amount
    );

    /// @notice Emitted when collateral is received from another chain
    /// @param messageId The transport-specific message identifier
    /// @param recipient The recipient address
    /// @param amount The amount of collateral received
    event CollateralReceived(bytes32 indexed messageId, address indexed recipient, uint256 amount);

    /// @notice Emitted when a result is received from another chain
    /// @param messageId The transport-specific message identifier
    /// @param conditionId The condition identifier
    event ResultReceived(bytes32 indexed messageId, ConditionId indexed conditionId);

    /*--------------------------------------------------------------
                                 ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when array lengths do not match
    error ArrayLengthMismatch();

    /// @notice Thrown when no positions are provided
    error NoPositions();

    /// @notice Thrown when the recipient is the zero address
    error ZeroRecipient();

    /// @notice Thrown when the recipient is not a left-padded EVM address
    error InvalidRecipient();

    /// @notice Thrown when positions belong to different modules
    error PositionsNotSameModule();

    /// @notice Thrown when a position's module is not on the bridgeable allowlist.
    error PositionTypeNotSupported();

    /// @notice Thrown when the module is not configured
    error ModuleNotConfigured();

    /// @notice Thrown when the module is not registered
    error ModuleNotRegistered();

    /// @notice Thrown when the module type is invalid
    error InvalidModule();

    /// @notice Thrown when the route is not supported
    error RouteNotSupported();

    /// @notice Thrown when the result has not been reported
    error ResultNotReported();

    /// @notice Thrown when outbound bridging is paused
    error SendIsPaused();

    /// @notice Thrown when inbound message processing is paused
    error ReceiveIsPaused();

    /// @notice Thrown when outbound bridging to the destination chain is paused
    error ChainSendIsPaused();

    /// @notice Thrown when inbound message processing from the source chain is paused
    error ChainReceiveIsPaused();

    /// @notice Thrown when a result names the local chain as its resolution chain
    error LocalResolutionChain();

    /// @notice Thrown when the resolution chain id is zero or is not the local chain
    error InvalidResolutionChainId();

    /// @notice Thrown when a result arrives on a lane other than the resolution chain's
    error UnexpectedResultSource();

    /*--------------------------------------------------------------
                              MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts to unpaused send state, globally and for the destination chain.
    modifier whenSendUnpaused(uint256 _dstChain) {
        require(!sendPaused, SendIsPaused());
        require(!chainSendPaused[_dstChain], ChainSendIsPaused());
        _;
    }

    /// @dev Restricts to unpaused receive state, globally and for the source chain.
    modifier whenReceiveUnpaused(uint256 _srcChain) {
        require(!receivePaused, ReceiveIsPaused());
        require(!chainReceivePaused[_srcChain], ChainReceiveIsPaused());
        _;
    }

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploys the bridge base contract.
    /// @param _positionManager The PositionManager contract address.
    /// @param _collateralToken The collateral token contract address.
    /// @param _resolutionChainId The chain id of the resolution chain.
    constructor(address _positionManager, address _collateralToken, uint256 _resolutionChainId) {
        require(_resolutionChainId != 0, InvalidResolutionChainId());

        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = ICollateralToken(_collateralToken);
        RESOLUTION_CHAIN_ID = _resolutionChainId;
    }

    /*--------------------------------------------------------------
                           EXTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    // ============ Position Bridging ============

    /// @inheritdoc IBridge
    /// @dev All positions must belong to the same module. For multi-module bridging, make
    ///      separate calls. Combinatorial positions are not supported. Positions must be
    ///      pre-transferred to this contract before calling.
    function bridgePositions(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes32 _recipient,
        bytes calldata _options
    ) external payable {
        uint256 positionIdlength = _positionIds.length;
        require(positionIdlength == _amounts.length, ArrayLengthMismatch());
        require(positionIdlength != 0, NoPositions());
        _validateRecipient(_recipient);

        (address moduleAddr, bytes32 messageId) =
            _sendPositionsMessage(_dstChain, _positionIds, _amounts, _recipient, _options);

        emit PositionsBridged(messageId, _dstChain, msg.sender, _recipient, positionIdlength);

        POSITION_MANAGER.unsafeBatchTransferFrom(address(this), moduleAddr, _positionIds, _amounts);
        BaseModule(moduleAddr).burnFromBridge(_positionIds, _amounts);
    }

    /// @inheritdoc IBridge
    function quoteBridgePositions(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes32 _recipient,
        bytes calldata _options
    ) external view returns (uint256 nativeFee, uint256 alternativeFee) {
        uint256 length = _positionIds.length;
        if (length == 0) return (0, 0);
        require(length == _amounts.length, ArrayLengthMismatch());

        // Build placeholder positions (actual values don't affect payload size)
        BridgedPosition[] memory positions = new BridgedPosition[](length);
        for (uint256 i = 0; i < length; ++i) {
            positions[i] = BridgedPosition({ positionId: PositionId.wrap(0), amount: _amounts[i] });
        }

        bytes memory payload = BridgePayloads.positions(_recipient, positions);
        return _bridgeQuote(_dstChain, payload, _options);
    }

    // ============ Collateral Bridging ============

    /// @inheritdoc IBridge
    /// @dev Collateral must be pre-transferred to this contract before calling.
    function bridgeCollateral(uint256 _dstChain, uint256 _amount, bytes32 _recipient, bytes calldata _options)
        external
        payable
    {
        _validateRecipient(_recipient);

        bytes32 messageId = _bridgeSend(_dstChain, BridgePayloads.collateral(_recipient, _amount), _options);

        emit CollateralBridged(messageId, _dstChain, msg.sender, _recipient, _amount);

        COLLATERAL_TOKEN.burn(_amount);
    }

    /// @inheritdoc IBridge
    function quoteBridgeCollateral(uint256 _dstChain, uint256 _amount, bytes32 _recipient, bytes calldata _options)
        external
        view
        returns (uint256 nativeFee, uint256 alternativeFee)
    {
        bytes memory payload = BridgePayloads.collateral(_recipient, _amount);
        return _bridgeQuote(_dstChain, payload, _options);
    }

    /// @inheritdoc IBridge
    /// @dev Only the resolution chain can bridge results
    function bridgeResult(uint256 _dstChain, ConditionId _conditionId, bytes calldata _options) external payable {
        require(block.chainid == RESOLUTION_CHAIN_ID, InvalidResolutionChainId());

        uint256 moduleId = _conditionId.moduleId();
        address moduleAddr = POSITION_MANAGER.moduleById(moduleId);
        require(moduleAddr != address(0), ModuleNotConfigured());

        require(moduleSupported[moduleId][_dstChain], RouteNotSupported());

        uint256[] memory resultData = BaseModule(moduleAddr).getResultForBridge(_conditionId);

        require(resultData.length == 2, ResultNotReported());

        bytes32 messageId = _bridgeSend(_dstChain, BridgePayloads.result(_conditionId, resultData), _options);

        emit ResultBridged(messageId, _dstChain, _conditionId);
    }

    /// @inheritdoc IBridge
    function quoteBridgeResult(uint256 _dstChain, ConditionId _conditionId, bytes calldata _options)
        external
        view
        returns (uint256 nativeFee, uint256 alternativeFee)
    {
        // Use placeholder result array - actual values don't affect payload size
        uint256[] memory placeholderResult = new uint256[](2);
        bytes memory payload = BridgePayloads.result(_conditionId, placeholderResult);
        return _bridgeQuote(_dstChain, payload, _options);
    }

    /*--------------------------------------------------------------
                           ADMIN FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Set whether a module type is supported on a destination chain
    /// @param _module The local module address (validates registration)
    /// @param _dstChain The destination chain identifier
    /// @param _supported Whether the route is supported
    function setModuleSupported(address _module, uint256 _dstChain, bool _supported) external {
        _checkBridgeOwner();
        _validateChain(_dstChain);
        _setModuleSupported(_module, _dstChain, _supported);
    }

    /// @notice Batch set module support for multiple destination chains
    /// @param _module The local module address (validates registration)
    /// @param _dstChains Array of destination chain identifiers
    /// @param _supported Whether the routes are supported
    function setBatchModuleSupported(address _module, uint256[] calldata _dstChains, bool _supported) external {
        _checkBridgeOwner();
        uint256 length = _dstChains.length;
        for (uint256 i = 0; i < length; ++i) {
            _validateChain(_dstChains[i]);
            _setModuleSupported(_module, _dstChains[i], _supported);
        }
    }

    /*--------------------------------------------------------------
                           PAUSE MANAGEMENT
    --------------------------------------------------------------*/

    /// @notice Pause outbound bridging
    function pauseSend() external {
        _checkBridgeAdmin();
        sendPaused = true;
        emit SendPauseSet(true);
    }

    /// @notice Unpause outbound bridging
    function unpauseSend() external {
        _checkBridgeAdmin();
        sendPaused = false;
        emit SendPauseSet(false);
    }

    /// @notice Pause inbound message processing
    function pauseReceive() external {
        _checkBridgeAdmin();
        receivePaused = true;
        emit ReceivePauseSet(true);
    }

    /// @notice Unpause inbound message processing
    function unpauseReceive() external {
        _checkBridgeAdmin();
        receivePaused = false;
        emit ReceivePauseSet(false);
    }

    /// @notice Pause outbound bridging to a destination chain
    /// @param _chain The destination chain identifier
    function pauseChainSend(uint256 _chain) external {
        _checkBridgeAdmin();
        _validateChain(_chain);
        chainSendPaused[_chain] = true;
        emit ChainSendPauseSet(_chain, true);
    }

    /// @notice Unpause outbound bridging to a destination chain
    /// @param _chain The destination chain identifier
    function unpauseChainSend(uint256 _chain) external {
        _checkBridgeAdmin();
        _validateChain(_chain);
        chainSendPaused[_chain] = false;
        emit ChainSendPauseSet(_chain, false);
    }

    /// @notice Pause inbound message processing from a source chain
    /// @param _chain The source chain identifier
    function pauseChainReceive(uint256 _chain) external {
        _checkBridgeAdmin();
        _validateChain(_chain);
        chainReceivePaused[_chain] = true;
        emit ChainReceivePauseSet(_chain, true);
    }

    /// @notice Unpause inbound message processing from a source chain
    /// @param _chain The source chain identifier
    function unpauseChainReceive(uint256 _chain) external {
        _checkBridgeAdmin();
        _validateChain(_chain);
        chainReceivePaused[_chain] = false;
        emit ChainReceivePauseSet(_chain, false);
    }

    /*--------------------------------------------------------------
                           INTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @dev The set of position modules whose positions may be bridged, as an allowlist: a module
    ///      must be named here to be sent or minted, so a module added later is excluded until it is
    ///      added here.
    /// @dev Consulted on both the outbound and inbound paths. Outbound is additionally gated per
    ///      route by `moduleSupported`; inbound carries no per-route configuration, so this is what
    ///      constrains the module type on that side.
    /// @dev A module belongs here only if its positions are fully interpretable from the position ID,
    ///      since a payload carries just an ID and an amount. `CombinatorialModule` is excluded: its
    ///      leg definitions are per-chain state. Not `virtual`, so the set is fixed at compile time.
    ///      See `docs/bridge.md`.
    /// @param _moduleId The module identifier decoded from a position ID.
    /// @return True if positions belonging to the module may be bridged.
    function _isBridgeablePositionModule(uint256 _moduleId) internal pure returns (bool) {
        return _moduleId == ModuleIds.BINARY || _moduleId == ModuleIds.NEGRISK;
    }

    /// @dev Routes an incoming bridge message by type and processes it.
    /// @param _messageId The transport-specific message identifier.
    /// @param _srcChain The source chain identifier.
    /// @param _message The full payload including the MessageType prefix byte.
    function _processMessage(bytes32 _messageId, uint256 _srcChain, bytes memory _message)
        internal
        whenReceiveUnpaused(_srcChain)
    {
        // _message is mutated in place below; the caller's buffer must never be used again after this call.
        MessageType msgType = MessageType(uint8(_message[0]));

        assembly ("memory-safe") {
            // payload = _message[1:], update _message in place
            let payloadLength := sub(mload(_message), 1)
            _message := add(_message, 1)
            mstore(_message, payloadLength)
        }

        if (msgType == MessageType.POSITIONS) _handlePositionsReceive(_messageId, _message);
        else if (msgType == MessageType.COLLATERAL) _handleCollateralReceive(_messageId, _message);
        else if (msgType == MessageType.RESULT) _handleResultReceive(_messageId, _srcChain, _message);
    }

    /*--------------------------------------------------------------
                           PRIVATE FUNCTIONS
    --------------------------------------------------------------*/

    /// @dev Validates the recipient is a non-zero, left-padded EVM address. A recipient with
    ///      dirty upper bits would burn on source and permanently fail the address decode on
    ///      the destination. The shape check becomes destination-dependent once non-EVM
    ///      chains are supported.
    /// @param _recipient The recipient on the destination chain.
    function _validateRecipient(bytes32 _recipient) private pure {
        require(_recipient != bytes32(0), ZeroRecipient());
        require(uint256(_recipient) <= type(uint160).max, InvalidRecipient());
    }

    /// @dev Sets module support with registration validation.
    /// @param _module The local module address.
    /// @param _dstChain The destination chain identifier.
    /// @param _supported Whether the route is supported.
    function _setModuleSupported(address _module, uint256 _dstChain, bool _supported) private {
        uint256 id = BaseModule(_module).moduleId();
        require(POSITION_MANAGER.moduleById(id) == _module, ModuleNotRegistered());
        moduleSupported[id][_dstChain] = _supported;
        emit ModuleSupportedSet(id, _dstChain, _supported);
    }

    /// @dev Build metadata and send message for positions
    /// @param _dstChain The destination chain identifier
    /// @param _positionIds Array of position IDs to bridge
    /// @param _amounts Array of amounts for each position
    /// @param _recipient The recipient on the destination chain
    /// @param _options Transport-specific messaging options
    /// @return moduleAddr The resolved module address
    /// @return messageId The transport message identifier
    function _sendPositionsMessage(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes32 _recipient,
        bytes calldata _options
    ) private returns (address moduleAddr, bytes32 messageId) {
        uint256 length = _positionIds.length;
        BridgedPosition[] memory positions = new BridgedPosition[](length);

        // Get module from first position (derived from position ID)
        uint256 moduleIdValue = _positionIds[0].moduleId();
        require(_isBridgeablePositionModule(moduleIdValue), PositionTypeNotSupported());

        moduleAddr = POSITION_MANAGER.moduleById(moduleIdValue);
        require(moduleAddr != address(0), ModuleNotConfigured());

        require(moduleSupported[moduleIdValue][_dstChain], RouteNotSupported());

        positions[0] = BridgedPosition({ positionId: _positionIds[0], amount: _amounts[0] });

        for (uint256 i = 1; i < length; ++i) {
            PositionId positionId = _positionIds[i];

            // Validate all positions belong to the same module
            require(positionId.moduleId() == moduleIdValue, PositionsNotSameModule());

            positions[i] = BridgedPosition({ positionId: positionId, amount: _amounts[i] });
        }

        messageId = _bridgeSend(_dstChain, BridgePayloads.positions(_recipient, positions), _options);
    }

    /// @dev Pause-gated wrapper around the transport-specific send.
    /// @param _dstChain The destination chain identifier.
    /// @param _payload The encoded message payload.
    /// @param _options Transport-specific messaging options.
    /// @return messageId The transport message identifier.
    function _bridgeSend(uint256 _dstChain, bytes memory _payload, bytes calldata _options)
        private
        whenSendUnpaused(_dstChain)
        returns (bytes32 messageId)
    {
        return _transportSend(_dstChain, _payload, _options);
    }

    /// @dev Mints received positions to the recipient.
    /// @param _messageId The transport-specific message identifier.
    /// @param _data ABI-encoded (address recipient, BridgedPosition[]).
    function _handlePositionsReceive(bytes32 _messageId, bytes memory _data) private {
        (address recipient, BridgedPosition[] memory positions) = abi.decode(_data, (address, BridgedPosition[]));

        // Resolve module once for all positions (they all belong to the same module)
        uint256 moduleId = positions[0].positionId.moduleId();
        require(_isBridgeablePositionModule(moduleId), PositionTypeNotSupported());

        address moduleAddr = POSITION_MANAGER.moduleById(moduleId);
        require(moduleAddr != address(0), ModuleNotConfigured());

        uint256 length = positions.length;
        for (uint256 i = 0; i < length; ++i) {
            BridgedPosition memory pos = positions[i];

            // Defense-in-depth: send side enforces same-module batches, but if a peer bridge or
            // transport bug ever delivers a mismatched batch we'd otherwise mint a token via
            // moduleAddr whose ID bits route redemption elsewhere.
            require(pos.positionId.moduleId() == moduleId, PositionsNotSameModule());

            // Mint positions directly - no condition preparation needed
            BaseModule(moduleAddr).mintFromBridge(recipient, pos.positionId, pos.amount);

            emit PositionReceived(_messageId, recipient, pos.positionId, pos.amount);
        }
    }

    /// @dev Mints received collateral to the recipient.
    /// @param _messageId The transport-specific message identifier.
    /// @param _data ABI-encoded (address recipient, uint256 amount).
    function _handleCollateralReceive(bytes32 _messageId, bytes memory _data) private {
        (address recipient, uint256 amount) = abi.decode(_data, (address, uint256));

        // Mint collateral to recipient
        COLLATERAL_TOKEN.mint(recipient, amount);

        emit CollateralReceived(_messageId, recipient, amount);
    }

    /// @dev Reports a received result.
    /// @param _messageId The transport-specific message identifier.
    /// @param _srcChain The source chain identifier, in the transport's namespace.
    /// @param _data ABI-encoded (ConditionId conditionId, uint256[] result).
    function _handleResultReceive(bytes32 _messageId, uint256 _srcChain, bytes memory _data) private {
        (ConditionId conditionId, uint256[] memory resultData) = abi.decode(_data, (ConditionId, uint256[]));

        require(block.chainid != RESOLUTION_CHAIN_ID, LocalResolutionChain());
        require(_isResolutionChainSource(_srcChain), UnexpectedResultSource());

        uint256 moduleIdValue = conditionId.moduleId();
        address moduleAddr = POSITION_MANAGER.moduleById(moduleIdValue);
        require(moduleAddr != address(0), ModuleNotConfigured());

        // Bridge is the oracle, so it can call reportResult.
        BaseModule(moduleAddr).reportResult(conditionId, resultData);
        emit ResultReceived(_messageId, conditionId);
    }

    /*--------------------------------------------------------------
                           VIRTUAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @dev Send a cross-chain message via the transport layer
    /// @return messageId The transport message identifier
    function _transportSend(uint256 _dstChain, bytes memory _payload, bytes calldata _options)
        internal
        virtual
        returns (bytes32 messageId);

    /// @dev Quote the fee for a cross-chain message
    function _bridgeQuote(uint256 _dstChain, bytes memory _payload, bytes calldata _options)
        internal
        view
        virtual
        returns (uint256 nativeFee, uint256 alternativeFee);

    /// @dev Validate chain identifier is within transport-specific range
    function _validateChain(uint256 _chain) internal view virtual;

    /// @dev Whether a source chain is the resolution chain, in the transport's own namespace.
    function _isResolutionChainSource(uint256 _srcChain) internal view virtual returns (bool);

    /// @dev Revert if caller is not the bridge owner
    function _checkBridgeOwner() internal view virtual;

    /// @dev Revert if caller is not a bridge admin (or owner)
    function _checkBridgeAdmin() internal view virtual;
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";

import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";
import { PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { Router } from "./Router.sol";

/// @title BridgeRouter
/// @author Polymarket
/// @notice Extends Router with cross-chain position and collateral bridging.
/// @dev No native-fee refund: callers must pre-quote the exact fee via `IBridge.quoteBridge*`
///      and pass exactly `msg.value == fee`. CCIP silently captures any overpayment on the
///      upstream side (see `IRouterClient.ccipSend`).
contract BridgeRouter is Router {
    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when a user initiates a position bridge through the router.
    /// @param initiator The user that called the router.
    /// @param dstChain Destination chain identifier.
    /// @param recipient Recipient on the destination chain as bytes32.
    /// @param positionIds Array of position IDs bridged.
    /// @param amounts Array of amounts bridged for each position.
    event BridgePositionsInitiated(
        address indexed initiator,
        uint256 indexed dstChain,
        bytes32 indexed recipient,
        PositionId[] positionIds,
        uint256[] amounts
    );

    /// @notice Emitted when a user initiates a collateral bridge through the router.
    /// @param initiator The user that called the router.
    /// @param dstChain Destination chain identifier.
    /// @param recipient Recipient on the destination chain as bytes32.
    /// @param amount Amount of collateral bridged.
    event BridgeCollateralInitiated(
        address indexed initiator, uint256 indexed dstChain, bytes32 indexed recipient, uint256 amount
    );

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The bridge contract address.
    address public immutable BRIDGE;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploy the BridgeRouter
    /// @param _positionManager Address of the PositionManager contract
    /// @param _bridge Address of the bridge contract
    constructor(address _positionManager, address _bridge) Router(_positionManager) {
        BRIDGE = _bridge;
    }

    /*--------------------------------------------------------------
                              BRIDGE
    --------------------------------------------------------------*/

    /// @notice Bridge positions to another chain (recipient = msg.sender)
    /// @param _dstChain Destination chain identifier
    /// @param _positionIds Array of position IDs to bridge
    /// @param _amounts Array of amounts for each position
    /// @param _options Bridge-specific options
    function bridgePositions(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes calldata _options
    ) external payable {
        _bridgePositions(_dstChain, _positionIds, _amounts, bytes32(uint256(uint160(msg.sender))), _options);
    }

    /// @notice Bridge positions to another chain with an explicit recipient
    /// @param _dstChain Destination chain identifier
    /// @param _positionIds Array of position IDs to bridge
    /// @param _amounts Array of amounts for each position
    /// @param _recipient Recipient on destination chain as bytes32
    /// @param _options Bridge-specific options
    function bridgePositionsTo(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes32 _recipient,
        bytes calldata _options
    ) external payable {
        _bridgePositions(_dstChain, _positionIds, _amounts, _recipient, _options);
    }

    /// @notice Bridge collateral to another chain (recipient = msg.sender)
    /// @param _dstChain Destination chain identifier
    /// @param _amount Amount of collateral to bridge
    /// @param _options Bridge-specific options
    function bridgeCollateral(uint256 _dstChain, uint256 _amount, bytes calldata _options) external payable {
        _bridgeCollateral(_dstChain, _amount, bytes32(uint256(uint160(msg.sender))), _options);
    }

    /// @notice Bridge collateral to another chain with an explicit recipient
    /// @param _dstChain Destination chain identifier
    /// @param _amount Amount of collateral to bridge
    /// @param _recipient Recipient on destination chain as bytes32
    /// @param _options Bridge-specific options
    function bridgeCollateralTo(uint256 _dstChain, uint256 _amount, bytes32 _recipient, bytes calldata _options)
        external
        payable
    {
        _bridgeCollateral(_dstChain, _amount, _recipient, _options);
    }

    /*--------------------------------------------------------------
                           INTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @dev Transfers positions to bridge and initiates cross-chain send.
    /// @param _dstChain Destination chain identifier.
    /// @param _positionIds Array of position IDs to bridge.
    /// @param _amounts Array of amounts for each position.
    /// @param _recipient Recipient on destination chain as bytes32.
    /// @param _options Bridge-specific options.
    function _bridgePositions(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes32 _recipient,
        bytes calldata _options
    ) internal {
        POSITION_MANAGER.unsafeBatchTransferFrom(msg.sender, BRIDGE, _positionIds, _amounts);

        emit BridgePositionsInitiated(msg.sender, _dstChain, _recipient, _positionIds, _amounts);

        IBridge(BRIDGE).bridgePositions{ value: msg.value }(_dstChain, _positionIds, _amounts, _recipient, _options);
    }

    /// @dev Transfers collateral to bridge and initiates cross-chain send.
    /// @param _dstChain Destination chain identifier.
    /// @param _amount Amount of collateral to bridge.
    /// @param _recipient Recipient on destination chain as bytes32.
    /// @param _options Bridge-specific options.
    function _bridgeCollateral(uint256 _dstChain, uint256 _amount, bytes32 _recipient, bytes calldata _options)
        internal
    {
        SafeTransferLib.safeTransferFrom(COLLATERAL_TOKEN, msg.sender, BRIDGE, _amount);

        emit BridgeCollateralInitiated(msg.sender, _dstChain, _recipient, _amount);

        IBridge(BRIDGE).bridgeCollateral{ value: msg.value }(_dstChain, _amount, _recipient, _options);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

import { ConditionId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title IBridge
/// @notice Shared interface for cross-chain bridge operations
/// @dev Uses uint256 for chain identifiers — each bridge narrows
///      internally. All payable functions require msg.value to cover
///      the messaging fee. Use the corresponding quoteBridge*()
///      view to determine the exact fee before calling. Excess
///      msg.value may not be refunded depending on the transport.
interface IBridge {
    /*--------------------------------------------------------------
                           POSITION BRIDGING
    --------------------------------------------------------------*/

    /// @notice Bridge positions to another chain. Positions must be pre-transferred to the
    ///         bridge before calling.
    /// @param _dstChain Destination chain identifier
    /// @param _positionIds Array of position IDs to bridge
    /// @param _amounts Array of amounts for each position
    /// @param _recipient Recipient on destination chain as bytes32
    /// @param _options Bridge-specific options (gas, etc.)
    function bridgePositions(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes32 _recipient,
        bytes calldata _options
    ) external payable;

    /// @notice Quote fee for bridging positions
    function quoteBridgePositions(
        uint256 _dstChain,
        PositionId[] calldata _positionIds,
        uint256[] calldata _amounts,
        bytes32 _recipient,
        bytes calldata _options
    ) external view returns (uint256 nativeFee, uint256 alternativeFee);

    /*--------------------------------------------------------------
                          COLLATERAL BRIDGING
    --------------------------------------------------------------*/

    /// @notice Bridge collateral to another chain. Collateral must be pre-transferred to the
    ///         bridge before calling.
    /// @param _dstChain Destination chain identifier
    /// @param _amount Amount to bridge
    /// @param _recipient Recipient on destination chain as bytes32
    /// @param _options Bridge-specific options
    function bridgeCollateral(uint256 _dstChain, uint256 _amount, bytes32 _recipient, bytes calldata _options)
        external
        payable;

    /// @notice Quote fee for bridging collateral
    function quoteBridgeCollateral(uint256 _dstChain, uint256 _amount, bytes32 _recipient, bytes calldata _options)
        external
        view
        returns (uint256 nativeFee, uint256 alternativeFee);

    /*--------------------------------------------------------------
                         RESULT BRIDGING (PUSH)
    --------------------------------------------------------------*/

    /// @notice Push result to a spoke chain
    /// @param _dstChain Destination chain identifier
    /// @param _conditionId Condition ID (result is fetched from local module)
    /// @param _options Bridge-specific options
    /// @dev Permissionless - anyone can push results to spoke chains
    /// @dev Callable only on the resolution chain
    function bridgeResult(uint256 _dstChain, ConditionId _conditionId, bytes calldata _options) external payable;

    /// @notice Quote fee for bridging result
    function quoteBridgeResult(uint256 _dstChain, ConditionId _conditionId, bytes calldata _options)
        external
        view
        returns (uint256 nativeFee, uint256 alternativeFee);
}

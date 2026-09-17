// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ICollateralToken
/// @author Polymarket
/// @notice Interface for the Polymarket collateral token (ERC-20) that supports minting, burning,
/// and wrapping/unwrapping underlying assets
interface ICollateralToken {
    /// @notice Mints collateral tokens to a recipient
    /// @param _to The address to receive the minted tokens
    /// @param _amount The amount of tokens to mint
    function mint(address _to, uint256 _amount) external;

    /// @notice Burns collateral tokens from the caller
    /// @param _amount The amount of tokens to burn
    function burn(uint256 _amount) external;

    /// @notice Wraps a supported underlying asset into collateral tokens
    /// @dev The underlying asset must be transferred into the contract before this call.
    /// @param _asset The address of the underlying asset to wrap
    /// @param _to The address to receive the minted collateral tokens
    /// @param _amount The amount of the underlying asset to wrap
    function wrap(address _asset, address _to, uint256 _amount) external;

    /// @notice Unwraps collateral tokens back into a supported underlying asset
    /// @dev Collateral tokens to be burned must be transferred to this contract before calling.
    /// @param _asset The address of the underlying asset to receive
    /// @param _to The address to receive the unwrapped underlying asset
    /// @param _amount The amount of collateral tokens to unwrap
    function unwrap(address _asset, address _to, uint256 _amount) external;

    /// @notice Wraps a supported underlying asset into collateral tokens (legacy overload)
    /// @dev Selector-compatible with the previously deployed CollateralToken for the benefit of
    ///      the deployed ramps and adapters. The callback parameters are ignored; the underlying
    ///      asset must be transferred into the contract before this call.
    /// @param _asset The address of the underlying asset to wrap
    /// @param _to The address to receive the minted collateral tokens
    /// @param _amount The amount of the underlying asset to wrap
    /// @param _callbackReceiver Ignored, kept for ABI compatibility (deployed callers pass 0)
    /// @param _data Ignored, kept for ABI compatibility
    function wrap(address _asset, address _to, uint256 _amount, address _callbackReceiver, bytes calldata _data)
        external;

    /// @notice Unwraps collateral tokens back into a supported asset (legacy overload)
    /// @dev Selector-compatible with the previously deployed CollateralToken for the benefit of
    ///      the deployed ramps and adapters. The callback parameters are ignored; collateral
    ///      tokens to be burned must be transferred into the contract before this call.
    /// @param _asset The address of the underlying asset to receive
    /// @param _to The address to receive the unwrapped underlying asset
    /// @param _amount The amount of collateral tokens to unwrap
    /// @param _callbackReceiver Ignored, kept for ABI compatibility (deployed callers pass 0)
    /// @param _data Ignored, kept for ABI compatibility
    function unwrap(address _asset, address _to, uint256 _amount, address _callbackReceiver, bytes calldata _data)
        external;
}

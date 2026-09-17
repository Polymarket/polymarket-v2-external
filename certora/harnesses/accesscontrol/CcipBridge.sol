// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CcipBridge as CcipBridgeBase } from "@polymarket-v2/src/bridge/CcipBridge.sol";

/// @title CcipBridge init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `CcipBridge` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract CcipBridge is CcipBridgeBase {
    constructor(
        address _router,
        address _positionManager,
        address _collateralToken,
        uint256 _resolutionChainId,
        uint256 _resolutionChainSelector
    ) CcipBridgeBase(_router, _positionManager, _collateralToken, _resolutionChainId, _resolutionChainSelector) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

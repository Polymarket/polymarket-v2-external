// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { PositionManager as PositionManagerBase } from "@polymarket-v2/src/positionManager/PositionManager.sol";

/// @title PositionManager init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `PositionManager` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract PositionManager is PositionManagerBase {
    constructor(address _collateralToken) PositionManagerBase(_collateralToken) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

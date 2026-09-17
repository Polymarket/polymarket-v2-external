// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { CombinatorialModule as CombinatorialModuleBase } from "@polymarket-v2/src/modules/CombinatorialModule.sol";

/// @title CombinatorialModule init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `CombinatorialModule` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract CombinatorialModule is CombinatorialModuleBase {
    constructor(address _positionManager) CombinatorialModuleBase(_positionManager) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

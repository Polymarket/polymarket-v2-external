// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { BinaryModule as BinaryModuleBase } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title BinaryModule init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `BinaryModule` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract BinaryModule is BinaryModuleBase {
    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        ResolutionChain _moduleResolutionChain
    ) BinaryModuleBase(_positionManager, _conditionalTokens, _usdceToken, _moduleResolutionChain) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

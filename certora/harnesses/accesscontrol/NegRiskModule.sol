// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { NegRiskModule as NegRiskModuleBase } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title NegRiskModule init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `NegRiskModule` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract NegRiskModule is NegRiskModuleBase {
    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        address _negRiskAdapter,
        ResolutionChain _moduleResolutionChain
    ) NegRiskModuleBase(_positionManager, _conditionalTokens, _usdceToken, _negRiskAdapter, _moduleResolutionChain) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

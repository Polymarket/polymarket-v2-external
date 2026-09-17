// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { OracleAggregator as OracleAggregatorBase } from "@polymarket-v2/src/oracle/OracleAggregator.sol";

/// @title OracleAggregator init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `OracleAggregator` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract OracleAggregator is OracleAggregatorBase {
    constructor(address _positionManager) OracleAggregatorBase(_positionManager) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

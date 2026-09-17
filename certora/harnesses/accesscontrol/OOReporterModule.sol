// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { OOReporterModule as OOReporterModuleBase } from "@polymarket-v2/src/oracle/modules/OOReporterModule.sol";

/// @title OOReporterModule init-harness
/// @notice Rename-import harness for accesscontrol/Initializable.spec (ACCESS-INIT-01):
///         exposes Solady Initializable's internal version read. Named `OOReporterModule` so
///         specs and confs written against the production name keep resolving.
/// @dev View-only addition; changes no behaviour.
contract OOReporterModule is OOReporterModuleBase {
    /// @dev Forwards the immutable OOReporter address to the base; the value is irrelevant to
    ///      ACCESS-INIT-01 (constructors are not executed by the Prover — only the init slot
    ///      semantics are verified).
    constructor(address _ooReporter) OOReporterModuleBase(_ooReporter) { }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

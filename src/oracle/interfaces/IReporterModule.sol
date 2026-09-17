// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title IReporterModule
/// @author Polymarket
/// @notice Interface for reporter modules that serve as entry points for reporting outcomes
/// @dev Modules are singletons that call into the OracleAggregator to register reports
interface IReporterModule {
    /// @notice Initialize request-specific configuration for this module
    /// @param eventId The event identifier
    /// @param data Module-specific initialization data (e.g., list of authorized reporters)
    function initializeReporterModule(EventId eventId, bytes calldata data) external;

    /// @notice Forward a per-request rule update from the aggregator to this module
    /// @dev Called by the OracleAggregator for every registered reporter when rules change.
    ///      Modules that mirror rules to external systems act on it; others may no-op.
    /// @param requestId The request identifier whose rules were updated
    /// @param updatedRules The new rule blob (forwarded verbatim)
    function updateRules(bytes32 requestId, bytes calldata updatedRules) external;
}

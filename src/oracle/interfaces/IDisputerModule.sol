// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title IDisputerModule
/// @author Polymarket
/// @notice Interface for disputer modules that serve as entry points for disputing outcomes
/// @dev Modules are singletons that call into the OracleAggregator to register disputes
interface IDisputerModule {
    /// @notice Initialize request-specific configuration for this module
    /// @param eventId The event identifier
    /// @param data Module-specific initialization data
    function initializeDisputerModule(EventId eventId, bytes calldata data) external;

    /// @notice Get the bond requirements for disputing
    /// @param eventId The event identifier
    /// @return token The bond token address (address(0) for no bond required)
    /// @return amount The bond amount (0 for trusted disputers)
    function getDisputeBond(EventId eventId) external view returns (address token, uint256 amount);
}

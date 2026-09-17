// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title IArbitratorModule
/// @author Polymarket
/// @notice Interface for arbitrator modules that handle final dispute resolution
/// @dev Init is per-event; arbitration callbacks take the aggregator's opaque `requestId`.
interface IArbitratorModule {
    /// @notice Initialize request-specific configuration for this module
    /// @param eventId The event identifier
    /// @param data Module-specific initialization data
    function initializeArbitratorModule(EventId eventId, bytes calldata data) external;

    /// @notice Called when arbitration is triggered by disputers or conflicting reporter quorums.
    /// @dev On reporter conflict, the arbitrator can query `conflictingResultHash(requestId)` from
    ///      the aggregator for the later threshold-supported result hash.
    /// @param requestId The request identifier
    /// @param proposedResultHash Hash of the result array proposed before arbitration
    function onArbitrationTriggered(bytes32 requestId, bytes32 proposedResultHash) external;

    /// @notice Called when the aggregator makes an in-arbitration request terminal through a
    ///         path other than this arbitrator module (e.g. admin override or payout skip).
    /// @dev Lets the module clear its local arbitration state so it does not appear active after
    ///      the aggregator considers the request terminal. Implementations MUST be idempotent
    ///      (no-op if not currently active). The aggregator invokes this hook best-effort: any
    ///      revert is caught and surfaced via an event so it cannot block admin resolution.
    /// @param requestId The request identifier
    function onArbitrationResolved(bytes32 requestId) external;

    /// @notice Get the current arbitration state for a request
    /// @param requestId The request identifier
    /// @return isActive Whether arbitration is active
    /// @return proposedResultHash The originally proposed result hash
    function getArbitrationState(bytes32 requestId) external view returns (bool isActive, bytes32 proposedResultHash);
}

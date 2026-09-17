// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title IOracleAggregator
/// @author Polymarket
/// @notice Unified interface for modules interacting with the OracleAggregator
/// @dev `requestId` stays raw `bytes32` — opaque (conditionId or eventId depending on market).
interface IOracleAggregator {
    /// @notice Submit a result report, incrementing the vote count.
    /// @dev Only callable by registered reporter modules. After a proposal exists, reports remain
    ///      open during its dispute window. A different result reaching threshold triggers
    ///      arbitration automatically.
    /// @param requestId The request identifier (conditionId or eventId)
    /// @param result The result array matching the configured length
    function reportResult(bytes32 requestId, uint256[] calldata result) external;

    /// @notice Disputes the currently proposed result for a request
    /// @dev Only callable by registered disputer modules during the active dispute window.
    ///      If the dispute threshold is met, arbitration is triggered.
    /// @param requestId The identifier of the request to dispute
    function disputeResult(bytes32 requestId) external;

    /// @notice Finalizes a threshold-supported result once the dispute window expires.
    /// @dev Callable by anyone when no finalizer is configured, otherwise only by the configured
    ///      finalizer. A zero liveness window permits finalization in the proposal's block.
    /// @param requestId The identifier of the request to finalize.
    /// @param result The result array whose hash must match the proposed result.
    function finalize(bytes32 requestId, uint256[] calldata result) external;

    /// @notice Resolves a request with a final result, bypassing the normal report/dispute flow
    /// @dev Only callable by the configured arbitrator module or by an admin, at any point
    ///      before resolution — arbitration does not need to have been triggered. Returns
    ///      silently (no revert, no event) when the request is already resolved.
    /// @param requestId The identifier of the request to resolve
    /// @param result The final result array to report to the target contract
    function resolveResult(bytes32 requestId, uint256[] calldata result) external;

    /// @notice Returns the current resolution state for a request
    /// @param requestId The identifier of the request to query
    /// @return status The resolution status (0=None, 1=Active, 2=ArbitrationRequested, 3=Resolved)
    /// @return proposedResultHash Hash of the proposed result, or bytes32(0)
    /// @return disputeWindowEnd Timestamp when the dispute window closes
    /// @return disputeCount The number of disputes received for the current proposal
    function getRequestState(bytes32 requestId)
        external
        view
        returns (uint8 status, bytes32 proposedResultHash, uint256 disputeWindowEnd, uint256 disputeCount);

    /// @notice Returns the first threshold-supported result that conflicts with the proposal.
    /// @param requestId The identifier of the request to query.
    /// @return The conflicting result hash, or zero when no reporter conflict occurred.
    function conflictingResultHash(bytes32 requestId) external view returns (bytes32);

    /// @notice Returns the expected result array length for a request
    /// @param requestId The identifier of the request to query
    /// @return The number of elements expected in a result array for this request
    function getResultLength(bytes32 requestId) external view returns (uint256);

    /// @notice Returns the authoritative market type and result length for a request.
    /// @param requestId The identifier of the request to query.
    /// @return marketType The market type (0=Binary, 1=Incremental NegRisk, 2=Atomic NegRisk).
    /// @return resultLength The expected number of result elements.
    function getRequestShape(bytes32 requestId) external view returns (uint8 marketType, uint16 resultLength);
}

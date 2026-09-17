// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title OracleAggregatorErrors
/// @author Polymarket
/// @notice Custom errors for the OracleAggregator.
abstract contract OracleAggregatorErrors {
    // Configuration Errors

    /// @notice Thrown when request configuration is invalid (zero thresholds, missing target,
    /// etc.).
    error InvalidConfig();
    /// @notice Thrown when the provided event ID is malformed for the configured request.
    error InvalidEventId();
    /// @notice Thrown when the provided request ID is malformed.
    error InvalidRequestId();
    /// @notice Thrown when a request target is not the registered module for its event ID.
    error InvalidTargetContract();
    /// @notice Thrown when the provided condition index is out of bounds for the request.
    error InvalidConditionIndex();
    /// @notice Thrown when a proposed upgrade changes an immutable dependency.
    error IncompatibleImplementation();
    /// @notice Thrown when a liveness window exceeds the protocol maximum.
    error LivenessWindowTooLong();

    // Request Status Errors

    /// @notice Thrown when attempting to initialize a request that already exists.
    error RequestAlreadyExists();
    /// @notice Thrown when the request has not been initialized.
    error RequestNotFound();
    /// @notice Thrown when the request is not in Active status.
    error RequestNotActive();
    /// @notice Thrown when a rule is posted for an already-resolved request.
    error RequestAlreadyResolved();

    // Challenge Errors

    /// @notice Thrown when attempting to dispute but no proposal exists.
    error NoProposalToChallenge();

    // Module Errors

    /// @notice Thrown when the caller is not a registered reporter or disputer module.
    error NotRegisteredModule();
    /// @notice Thrown when a reporter or disputer module has already voted on this request.
    error AlreadyVoted();
    /// @notice Thrown when the caller is not authorized for the operation.
    error NotAuthorized();

    // Result Errors

    /// @notice Thrown when the provided result hash does not match the stored proposal hash.
    error InvalidResultHash();
    /// @notice Thrown when the result array length does not match the expected length.
    error InvalidResultLength();
    /// @notice Thrown when result values exceed RESULT_DENOMINATOR.
    error InvalidResultSum();
    /// @notice Thrown when a neg-risk result element is neither 0 nor RESULT_DENOMINATOR.
    error InvalidResult();
    // Dispute/Timing Errors

    /// @notice Thrown when attempting to finalize while the dispute window is still active.
    error DisputeWindowActive();
    /// @notice Thrown when attempting to report or dispute after the dispute window has expired.
    error DisputeWindowExpired();
    /// @notice Thrown when the vote count has not reached the required threshold.
    error ThresholdNotMet();

    // Market Pause Errors

    /// @notice Thrown when attempting to finalize a market that is paused at the per-event level.
    error MarketPaused();
}

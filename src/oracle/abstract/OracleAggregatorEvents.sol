// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title OracleAggregatorEvents
/// @author Polymarket
/// @notice Events emitted by the OracleAggregator.
/// @dev `requestId` topics stay raw `bytes32` — the field is opaque (conditionId or eventId).
abstract contract OracleAggregatorEvents {
    /// @notice Emitted when a new resolution request is initialized.
    /// @param eventId The event ID the request is registered under.
    /// @param targetContract The contract that will receive the final result.
    /// @param reporterThreshold Number of matching votes needed to propose an outcome.
    /// @param disputerThreshold Number of disputes needed to trigger arbitration.
    /// @param resultLength Expected length of the result array.
    /// @param marketType Request shape (0=Binary, 1=Incremental NegRisk, 2=Atomic NegRisk).
    /// @param arbitratorModule Module responsible for resolving escalated requests.
    /// @param livenessWindow Seconds after proposal during which disputes may be submitted.
    /// @param finalizer Address allowed to finalize the request (zero means permissionless).
    event RequestInitialized(
        EventId indexed eventId,
        address targetContract,
        uint256 reporterThreshold,
        uint256 disputerThreshold,
        uint16 resultLength,
        uint8 marketType,
        address arbitratorModule,
        uint32 livenessWindow,
        address finalizer
    );

    /// @notice Emitted when a request is resolved (finalized, arbitrator- or admin-resolved).
    /// @param requestId The condition or event ID that was resolved.
    /// @param resultHash The hash of the final result array.
    /// @param resolver The source of the result: `address(this)` for a stored proposal finalized
    ///                 from aggregator state, else the arbitrator module or admin that called
    ///                 `resolveResult`.
    event RequestResolved(bytes32 indexed requestId, bytes32 resultHash, address indexed resolver);

    // Reporting

    /// @notice Emitted when a reporter module submits a result vote.
    /// @param requestId The condition ID being reported on.
    /// @param module The reporter module that submitted the vote.
    /// @param resultHash The hash of the submitted result.
    /// @param votes The total vote count for this result after this submission.
    event ResultReported(bytes32 indexed requestId, address indexed module, bytes32 resultHash, uint256 votes);

    /// @notice Emitted when votes reach the threshold and a proposal is created.
    /// @param requestId The condition ID with the new proposal.
    /// @param resultHash The hash of the proposed result.
    /// @param result The proposed result array.
    event OutcomeProposed(bytes32 indexed requestId, bytes32 resultHash, uint256[] result);

    /// @notice Emitted when a second, different result reaches the reporter threshold.
    /// @param requestId The condition or event ID whose reporters conflict.
    /// @param proposedResultHash The first threshold-supported result hash.
    /// @param conflictingResultHash The later threshold-supported result hash.
    /// @param conflictingResult The later threshold-supported result array.
    event ReporterConflict(
        bytes32 indexed requestId,
        bytes32 indexed proposedResultHash,
        bytes32 indexed conflictingResultHash,
        uint256[] conflictingResult
    );

    // Dispute & Arbitration

    /// @notice Emitted when a disputer module challenges the proposed result.
    /// @param requestId The condition ID being disputed.
    /// @param module The disputer module that submitted the challenge.
    event ResultDisputed(bytes32 indexed requestId, address indexed module);

    /// @notice Emitted when disputes reach threshold or conflicting reporter quorums emerge.
    /// @param requestId The condition ID entering arbitration.
    event ArbitrationTriggered(bytes32 indexed requestId);

    /// @notice Emitted when the arbitrator's `onArbitrationResolved` hook reverts during an admin
    ///         override of an in-arbitration request. The admin's resolution still succeeds; the
    ///         arbitrator module's local state may be stale and require manual reconciliation.
    /// @param requestId The condition or event ID that was resolved.
    /// @param arbitratorModule The arbitrator module whose hook reverted.
    event ArbitratorHookFailed(bytes32 indexed requestId, address indexed arbitratorModule);

    // Market Management

    /// @notice Emitted when a reporter module is registered for an event.
    /// @param eventId The event the module was registered for.
    /// @param module The reporter module address.
    event ReporterModuleAdded(EventId indexed eventId, address indexed module);

    /// @notice Emitted when a reporter module is deregistered from an event.
    /// @param eventId The event the module was deregistered from.
    /// @param module The reporter module address.
    event ReporterModuleRemoved(EventId indexed eventId, address indexed module);

    /// @notice Emitted when a disputer module is registered for an event.
    /// @param eventId The event the module was registered for.
    /// @param module The disputer module address.
    event DisputerModuleAdded(EventId indexed eventId, address indexed module);

    /// @notice Emitted when a disputer module is deregistered from an event.
    /// @param eventId The event the module was deregistered from.
    /// @param module The disputer module address.
    event DisputerModuleRemoved(EventId indexed eventId, address indexed module);

    /// @notice Emitted when the arbitrator module for an event is changed.
    /// @param eventId The event whose arbitrator changed.
    /// @param arbitratorModule The new arbitrator module address.
    event ArbitratorModuleSet(EventId indexed eventId, address indexed arbitratorModule);

    /// @notice Emitted when the finalizer for an event is set or cleared.
    /// @param eventId The event whose finalizer changed.
    /// @param finalizer The new finalizer address (zero means permissionless finalize).
    event FinalizerSet(EventId indexed eventId, address indexed finalizer);

    /// @notice Emitted when the liveness window for an event is changed.
    /// @param eventId The event whose liveness window changed.
    /// @param livenessWindow The new liveness window in seconds.
    event LivenessWindowSet(EventId indexed eventId, uint32 livenessWindow);

    /// @notice Emitted when an event's per-event pause state is changed.
    /// @dev Independent of the global pause; only gates `finalize`.
    /// @param eventId The event whose pause state changed.
    /// @param paused The new per-event pause state.
    event MarketPauseSet(EventId indexed eventId, bool paused);

    /// @notice Emitted when a request's rules are updated and forwarded to its reporter modules.
    /// @dev The rule blob itself is recorded by `MarketDataRegistry.RuleAdded`; this event
    ///      records the propagation step and the number of reporters notified.
    /// @param requestId The request whose rules were updated.
    /// @param reportersNotified Number of reporter modules that received `updateRules`.
    event RequestRulesUpdated(bytes32 indexed requestId, uint256 reportersNotified);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OracleModuleBase } from "@polymarket-v2/src/oracle/abstract/OracleModuleBase.sol";
import { IOracleAggregator } from "@polymarket-v2/src/oracle/interfaces/IOracleAggregator.sol";
import { IReporterModule } from "@polymarket-v2/src/oracle/interfaces/IReporterModule.sol";
import { ConditionId, ConditionIdLib, EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title EOAReporterModule
/// @author Polymarket
/// @notice Reporter module through which authorized EOA addresses submit results
/// @dev A single proxied instance serves all events. Reporters call report() directly and the
///      module forwards to aggregator.reportResult(). The aggregator counts votes per module
///      address, so this module contributes at most one vote per request: the first authorized
///      reporter to report casts it, and later reports revert in the aggregator with
///      AlreadyVoted. Authorizing multiple reporters provides sender redundancy (any-of-N can
///      cast the module's vote), not additional votes — meeting a reporterThreshold of N
///      requires N registered reporter modules.
contract EOAReporterModule is OracleModuleBase, IReporterModule {
    /*--------------------------------------------------------------
                                 ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when caller is not an authorized reporter.
    error NotAuthorizedReporter();
    /// @notice Thrown when reporter initialization contains no authorized reporters.
    error EmptyReporters();

    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when a reporter is authorized for an event.
    /// @param eventId The event identifier
    /// @param reporter The authorized reporter address
    event ReporterAdded(EventId indexed eventId, address indexed reporter);
    /// @notice Emitted when a reporter submits a result.
    /// @param conditionId The condition identifier (raw bytes32, matches aggregator surface)
    /// @param reporter The reporter address that submitted the result
    /// @param resultHash The keccak256 hash of the reported result
    event Reported(bytes32 indexed conditionId, address indexed reporter, bytes32 resultHash);

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice Authorized reporters per event: eventId => reporter => isAuthorized
    mapping(EventId => mapping(address => bool)) public authorizedReporters;

    /// @notice Whether a reporter has voted: conditionId => reporter => hasReported
    /// @dev For Binary/Atomic: conditionId == eventId.
    ///      For Incremental NegRisk: conditionId == eventId + index.
    mapping(ConditionId => mapping(address => bool)) public hasReported;

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied EOA reporter module.
    /// @param _owner The contract owner (can upgrade).
    /// @param _admin The initial admin address.
    /// @param _aggregator The oracle aggregator address.
    function initialize(address _owner, address _admin, address _aggregator) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, ADMIN_ROLE);
        aggregator = _aggregator;
    }

    /*--------------------------------------------------------------
                     IREPORTERMODULE IMPLEMENTATION
    --------------------------------------------------------------*/

    /// @inheritdoc IReporterModule
    /// @dev Called by aggregator during request initialization
    /// @param data ABI encoded array of authorized reporter addresses
    function initializeReporterModule(EventId eventId, bytes calldata data)
        external
        override
        onlyAggregator
        initOnce(eventId.asCondition())
    {
        // Decode list of authorized reporters
        address[] memory reporters = abi.decode(data, (address[]));
        if (reporters.length == 0) revert EmptyReporters();

        for (uint256 i = 0; i < reporters.length; i++) {
            authorizedReporters[eventId][reporters[i]] = true;
            emit ReporterAdded(eventId, reporters[i]);
        }

        emit RequestInitialized(eventId.asCondition());
    }

    /// @inheritdoc IReporterModule
    /// @dev EOA reporters have no rules concept beyond the aggregator's canonical history, so this
    ///      hook is a no-op. Restricted to the aggregator so external callers cannot spoof rule
    ///      propagation events on individual modules.
    function updateRules(
        bytes32,
        /*requestId*/
        bytes calldata /*updatedRules*/
    )
        external
        override
        onlyAggregator
    { }

    /*--------------------------------------------------------------
                            REPORT FUNCTION
    --------------------------------------------------------------*/

    /// @notice Report result for a condition (unified for all event types)
    /// @dev Entry point for reporters - validates and forwards to aggregator. Only the first
    ///      report per condition succeeds: the aggregator rejects the module's second vote
    ///      with AlreadyVoted, so subsequent authorized reporters' calls revert.
    /// @param _conditionId The condition identifier (== eventId for Binary/Atomic)
    /// @param _result The result array
    function report(bytes32 _conditionId, uint256[] calldata _result) external {
        ConditionId conditionId = ConditionIdLib.from(_conditionId);
        EventId eventId = conditionId.eventId();

        require(requestInitialized[eventId.asCondition()], RequestNotInitialized());
        require(authorizedReporters[eventId][msg.sender], NotAuthorizedReporter());
        require(!hasReported[conditionId][msg.sender], AlreadyReported());

        hasReported[conditionId][msg.sender] = true;

        emit Reported(_conditionId, msg.sender, keccak256(abi.encode(_result)));

        // Forward to aggregator
        IOracleAggregator(aggregator).reportResult(_conditionId, _result);
    }

    /*--------------------------------------------------------------
                                 VIEWS
    --------------------------------------------------------------*/

    /// @notice Check if an address is an authorized reporter.
    /// @param _eventId The event identifier.
    /// @param _reporter The reporter address to check.
    /// @return True if the reporter is authorized.
    function isReporter(EventId _eventId, address _reporter) external view returns (bool) {
        return authorizedReporters[_eventId][_reporter];
    }

    /// @notice Check if a reporter has already reported on a condition.
    /// @param _conditionId The condition identifier.
    /// @param _reporter The reporter address to check.
    /// @return True if the reporter has already reported.
    function hasReporterReported(ConditionId _conditionId, address _reporter) external view returns (bool) {
        return hasReported[_conditionId][_reporter];
    }
}

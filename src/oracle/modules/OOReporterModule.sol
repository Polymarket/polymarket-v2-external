// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { IOOReporter } from "managed-oracle/pm-v2-oo-reporter/interfaces/IOOReporter.sol";

import { OracleModuleBase } from "@polymarket-v2/src/oracle/abstract/OracleModuleBase.sol";
import { IOracleAggregator } from "@polymarket-v2/src/oracle/interfaces/IOracleAggregator.sol";
import { IReporterModule } from "@polymarket-v2/src/oracle/interfaces/IReporterModule.sol";
import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { OptimisticOraclePayoutLib } from "@polymarket-v2/src/oracle/libraries/OptimisticOraclePayoutLib.sol";
import { ConditionId, ConditionIdLib, EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title OOReporterModule
/// @author Polymarket
/// @notice Reporter module that relays settled UMA OOReporter results into the oracle aggregator.
/// @dev UMA owns request initialization and settlement. This module registers Polymarket request
///      metadata, reports settled results into the normal threshold flow, and may relay normal
///      finalization once the aggregator liveness window ends. It has no arbitration authority.
contract OOReporterModule is OracleModuleBase, IReporterModule {
    /*--------------------------------------------------------------
                                 STRUCTS
    --------------------------------------------------------------*/

    /// @notice UMA registration data optionally supplied through reporter module init data.
    struct RequestRegistration {
        /// @dev Polymarket request identifier.
        bytes32 requestId;
        /// @dev Prediction market rules forwarded to UMA's OOReporter.
        bytes requestRules;
        /// @dev Minimum custom liveness the UMA oracle initializer may select.
        uint64 minimumLiveness;
        /// @dev Maximum custom liveness the UMA oracle initializer may select.
        uint64 maximumLiveness;
    }

    /*--------------------------------------------------------------
                                 ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when the UMA reporter address is zero.
    error ZeroOOReporter();
    /// @notice Thrown when reporter initialization contains no request registrations.
    error EmptyRequestRegistrations();
    /// @notice Thrown when an initialized request does not belong to the supplied event.
    error EventIdMismatch();
    /// @notice Thrown when UMA has not resolved the request yet.
    error RequestNotResolved();
    /// @notice Thrown when UMA returned a raw result this module cannot report.
    error InvalidPrice();
    /// @notice Thrown when minimum liveness is greater than maximum liveness.
    error InvalidLivenessRange(uint64 minimumLiveness, uint64 maximumLiveness);

    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when a Polymarket request is registered with UMA's OOReporter.
    /// @param requestId Polymarket request identifier.
    /// @param identifier UMA price identifier derived from the request shape.
    event OOReporterRequestCreated(bytes32 indexed requestId, bytes32 identifier);

    /// @notice Emitted when a settled UMA result is submitted to the oracle aggregator.
    /// @param requestId Polymarket request identifier.
    /// @param price Settled raw UMA price.
    /// @param resultHash Hash of the translated Polymarket result array.
    event OOReporterResultReported(bytes32 indexed requestId, int256 price, bytes32 resultHash);

    /// @notice Emitted when a rule update is successfully forwarded to UMA's OOReporter.
    /// @dev Paired with `OOReporterRulesForwardFailed` so offchain consumers can confirm the
    ///      UMA-side mirror stayed in sync with the aggregator's canonical rule history.
    /// @param requestId Polymarket request identifier.
    /// @param updatedRules Rule blob forwarded to UMA.
    event OOReporterRulesForwarded(bytes32 indexed requestId, bytes updatedRules);

    /// @notice Emitted when forwarding a rule update is skipped because UMA's OOReporter request
    ///         is already resolved or no longer registered.
    /// @dev All other OOReporter failures are bubbled to the aggregator and revert its rule update.
    /// @param requestId Polymarket request identifier.
    /// @param reason Raw revert payload returned by UMA's OOReporter.
    event OOReporterRulesForwardFailed(bytes32 indexed requestId, bytes reason);

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice UMA OOReporter contract.
    /// @dev Immutable and baked into the implementation bytecode; each implementation is deployed
    ///      against a fixed UMA OOReporter, so an upgrade must redeploy with the same address.
    IOOReporter public immutable ooReporter;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Sets the immutable UMA OOReporter. The base constructor disables initializers.
    /// @param _ooReporter The UMA OOReporter address.
    constructor(address _ooReporter) {
        if (_ooReporter == address(0)) revert ZeroOOReporter();
        ooReporter = IOOReporter(_ooReporter);
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied OOReporter module.
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
    /// @dev Decodes `RequestRegistration[]`. Empty aggregator init data skips this hook and lets an
    ///      authorized operator register requests later through `createRequest`.
    function initializeReporterModule(EventId _eventId, bytes calldata _data) external override onlyAggregator {
        RequestRegistration[] memory registrations = abi.decode(_data, (RequestRegistration[]));
        if (registrations.length == 0) revert EmptyRequestRegistrations();

        for (uint256 i; i < registrations.length; ++i) {
            RequestRegistration memory registration = registrations[i];
            ConditionId scopeId = ConditionIdLib.from(registration.requestId);
            if (scopeId.eventId() != _eventId) revert EventIdMismatch();

            _registerRequest({
                _scopeId: scopeId,
                _requestId: registration.requestId,
                _requestRules: registration.requestRules,
                _minimumLiveness: registration.minimumLiveness,
                _maximumLiveness: registration.maximumLiveness
            });
        }
    }

    /// @inheritdoc IReporterModule
    /// @dev Forwards the rule update to UMA's OOReporter so offchain consumers see the new rules
    ///      under the original request. Two resilience guards:
    ///      1. Silently skips request IDs this module never registered with UMA (so the
    ///         aggregator's per-event broadcast loop does not revert on incremental neg-risk
    ///         subconditions that this module did not own).
    ///      2. Treats `RequestAlreadyResolved` and `RequestNotRegistered` as non-blocking because
    ///         neither request can accept new rule metadata. Every other revert is bubbled so
    ///         authorization, registrar, and unexpected failures roll back the aggregator update.
    function updateRules(bytes32 _requestId, bytes calldata _updatedRules) external override onlyAggregator {
        ConditionId scopeId = ConditionIdLib.from(_requestId);
        if (!requestInitialized[scopeId]) return;

        try ooReporter.updateRequestRules(_requestId, _updatedRules) {
            emit OOReporterRulesForwarded(_requestId, _updatedRules);
        } catch (bytes memory reason) {
            if (!_isIgnorableRulesUpdateError(reason)) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            emit OOReporterRulesForwardFailed(_requestId, reason);
        }
    }

    /*--------------------------------------------------------------
                           REQUEST REGISTRATION
    --------------------------------------------------------------*/

    /// @notice Registers a UMA reporter request after aggregator request initialization.
    /// @dev This is the flexible alternative to aggregator-supplied reporter init data.
    /// @param _requestId Polymarket request identifier.
    /// @param _requestRules Raw UMA request rules.
    /// @param _minimumLiveness Minimum custom liveness the UMA oracle initializer may use.
    /// @param _maximumLiveness Maximum custom liveness the UMA oracle initializer may use.
    function createRequest(
        bytes32 _requestId,
        bytes calldata _requestRules,
        uint64 _minimumLiveness,
        uint64 _maximumLiveness
    ) external onlyOperator {
        _registerRequest({
            _scopeId: ConditionIdLib.from(_requestId),
            _requestId: _requestId,
            _requestRules: _requestRules,
            _minimumLiveness: _minimumLiveness,
            _maximumLiveness: _maximumLiveness
        });
    }

    /*--------------------------------------------------------------
                         REPORT AND FINALIZE
    --------------------------------------------------------------*/

    /// @notice Pulls a settled UMA result and submits one reporter vote to the aggregator.
    /// @dev Permissionless relay. The aggregator enforces reporter registration and one vote per module.
    /// @param _requestId Polymarket request identifier.
    function report(bytes32 _requestId) external {
        (int256 price, uint256[] memory result) = _getSettledResult(_requestId);

        emit OOReporterResultReported(_requestId, price, keccak256(abi.encode(result)));

        IOracleAggregator(aggregator).reportResult(_requestId, result);
    }

    /// @notice Relays normal aggregator finalization once the proposal liveness window ends.
    /// @dev Permissionless relay. The aggregator enforces threshold, liveness, finalizer, and result hash.
    /// @param _requestId Polymarket request identifier.
    function finalize(bytes32 _requestId) external {
        (, uint256[] memory result) = _getSettledResult(_requestId);
        IOracleAggregator(aggregator).finalize(_requestId, result);
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @dev Returns true only for canonical no-argument errors that mean the UMA mirror cannot
    ///      accept an update because the request is absent or already final.
    function _isIgnorableRulesUpdateError(bytes memory _reason) private pure returns (bool) {
        if (_reason.length != 4) return false;

        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(_reason, 0x20))
        }
        return selector == IOOReporter.RequestAlreadyResolved.selector
            || selector == IOOReporter.RequestNotRegistered.selector;
    }

    /// @dev Registers one request through the shared aggregator-init/operator path.
    /// @param _scopeId Canonical condition ID used by the module initialization guard.
    /// @param _requestId Raw Polymarket request identifier forwarded to UMA.
    /// @param _requestRules Prediction market rules forwarded to UMA.
    /// @param _minimumLiveness Minimum custom liveness the UMA initializer may select.
    /// @param _maximumLiveness Maximum custom liveness the UMA initializer may select.
    function _registerRequest(
        ConditionId _scopeId,
        bytes32 _requestId,
        bytes memory _requestRules,
        uint64 _minimumLiveness,
        uint64 _maximumLiveness
    ) internal initOnce(_scopeId) {
        (bytes32 identifier,,) = _determineRequestShape(_requestId);
        if (_minimumLiveness > _maximumLiveness) revert InvalidLivenessRange(_minimumLiveness, _maximumLiveness);

        ooReporter.registerRequest({
            requestId: _requestId,
            priceIdentifier: identifier,
            requestRules: _requestRules,
            minimumLiveness: _minimumLiveness,
            maximumLiveness: _maximumLiveness
        });

        emit RequestInitialized(_scopeId);
        emit OOReporterRequestCreated(_requestId, identifier);
    }

    /// @dev Reads and validates a settled UMA result, then translates it into Polymarket payouts.
    /// @param _requestId Polymarket request identifier.
    /// @return price Settled raw UMA price.
    /// @return result Translated Polymarket result array.
    function _getSettledResult(bytes32 _requestId) internal view returns (int256 price, uint256[] memory result) {
        if (!requestInitialized[ConditionIdLib.from(_requestId)]) revert RequestNotInitialized();
        if (!ooReporter.isRequestResolved(_requestId)) revert RequestNotResolved();

        price = ooReporter.getRequestResolution(_requestId);
        (, uint8 marketType, uint16 outcomeCount) = _determineRequestShape(_requestId);
        if (marketType == uint8(OracleAggregator.MarketType.ATOMIC_NEGRISK)) {
            if (price < 0 || uint256(price) % 1e18 != 0) revert InvalidPrice();
            uint256 winnerIndex = uint256(price) / 1e18;
            if (winnerIndex >= ConditionIdLib.from(_requestId).eventId().arity()) revert InvalidPrice();

            result = new uint256[](1);
            result[0] = winnerIndex;
            return (price, result);
        }

        if (!_isValidBinaryPrice(price, marketType)) revert InvalidPrice();
        result = OptimisticOraclePayoutLib.priceToPayouts(price, outcomeCount);
    }

    /// @dev Checks whether a settled YES_OR_NO_QUERY price is valid for the aggregator request shape.
    /// @param _price The price to validate.
    /// @param _marketType The aggregator market type.
    /// @return True if the price is valid.
    function _isValidBinaryPrice(int256 _price, uint8 _marketType) internal pure returns (bool) {
        if (_price == OptimisticOraclePayoutLib.YES_PRICE || _price == OptimisticOraclePayoutLib.NO_PRICE) {
            return true;
        }
        return _marketType == uint8(OracleAggregator.MarketType.BINARY) && _price == OptimisticOraclePayoutLib.P3_PRICE;
    }

    /// @dev Determines the UMA identifier and authoritative aggregator request shape.
    /// @param _requestId The Polymarket request ID.
    /// @return identifier The UMA price identifier.
    /// @return marketType The aggregator market type.
    /// @return outcomeCount The number of result elements.
    function _determineRequestShape(bytes32 _requestId)
        internal
        view
        returns (bytes32 identifier, uint8 marketType, uint16 outcomeCount)
    {
        (marketType, outcomeCount) = IOracleAggregator(aggregator).getRequestShape(_requestId);
        identifier = marketType == uint8(OracleAggregator.MarketType.ATOMIC_NEGRISK)
            ? OptimisticOraclePayoutLib.NUMERICAL_IDENTIFIER
            : OptimisticOraclePayoutLib.BINARY_IDENTIFIER;
    }
}

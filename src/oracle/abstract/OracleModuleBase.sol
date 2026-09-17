// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { Auth } from "@polymarket-v2/src/oracle/mixins/Auth.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title OracleModuleBase
/// @author Polymarket
/// @notice Shared base contract for all oracle modules (reporters, disputers, arbitrators)
/// @dev Provides UUPS upgradeability, aggregator state, admin/role management,
///      and conditionId resolution. Upgrades are restricted to the owner; all
///      other privileged operations are restricted to the admin role.
abstract contract OracleModuleBase is UUPSUpgradeable, Initializable, Auth {
    /*--------------------------------------------------------------
                            ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when the caller is not the aggregator.
    error NotAggregator();
    /// @notice Thrown when the request has not been initialized.
    error RequestNotInitialized();
    /// @notice Thrown when the request has already been initialized.
    error RequestAlreadyInitialized();
    /// @notice Thrown when a reporter has already reported.
    error AlreadyReported();
    /// @notice Thrown when a disputer has already disputed.
    error AlreadyDisputed();
    /// @notice Thrown when arbitration is not active.
    error ArbitrationNotActive();
    /// @notice Thrown when arbitration is already active.
    error ArbitrationAlreadyActive();

    /*--------------------------------------------------------------
                            EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when the aggregator address is updated.
    /// @param aggregator The new aggregator address.
    event AggregatorSet(address indexed aggregator);

    /// @notice Emitted when a request is initialized for this module.
    /// @dev The key is a conditionId or eventId depending on market
    ///      type, not module type. See `requestInitialized`.
    /// @param scopeId The scope ID keyed in `requestInitialized`.
    event RequestInitialized(ConditionId indexed scopeId);

    /*--------------------------------------------------------------
                             STATE
    --------------------------------------------------------------*/

    /// @notice The oracle aggregator address
    address public aggregator;

    /// @notice Tracks whether a request has been initialized for a
    ///         given scope ID on this module.
    /// @dev Typed `ConditionId` key. Binary and incremental neg-risk write the conditionId
    ///      directly; atomic neg-risk writes `eventId.asCondition()` — every canonical EventId
    ///      is also a canonical ConditionId (outcome byte is zero by the event-suffix invariant).
    mapping(ConditionId => bool) public requestInitialized;

    /// @dev Reserved storage gap for future base upgrades.
    uint256[48] private __gap;

    /*--------------------------------------------------------------
                           MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to the aggregator contract.
    modifier onlyAggregator() {
        require(msg.sender == aggregator, NotAggregator());
        _;
    }

    /// @dev Ensures a request is initialized only once per scope ID. Accepts a typed
    ///      `ConditionId`; canonical `EventId` values can be passed via `eventId.asCondition()`.
    /// @param _scopeId The scope ID to guard.
    modifier initOnce(ConditionId _scopeId) {
        require(!requestInitialized[_scopeId], RequestAlreadyInitialized());
        requestInitialized[_scopeId] = true;
        _;
    }

    /*--------------------------------------------------------------
                          CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @dev Disables initializers on the implementation contract.
    constructor() {
        _disableInitializers();
    }

    /*--------------------------------------------------------------
                       ADMIN FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Set the aggregator address.
    /// @param _aggregator The new aggregator address.
    function setAggregator(address _aggregator) external onlyAdmin {
        aggregator = _aggregator;
        emit AggregatorSet(_aggregator);
    }

    /*--------------------------------------------------------------
                        UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the contract owner.
    function _authorizeUpgrade(address) internal override onlyOwner { }
}

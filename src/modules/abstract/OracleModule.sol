// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { InitializableRoles } from "@polymarket-v2/src/auth/InitializableRoles.sol";
import { ConditionId, EventId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title OracleModuleEvents
/// @notice Events emitted by the OracleModule
abstract contract OracleModuleEvents {
    /// @notice Emitted when a resolver is paused
    /// @param resolver The paused resolver address
    /// @param timestamp The block timestamp when paused
    event ResolverPaused(address indexed resolver, uint256 timestamp);
    /// @notice Emitted when a resolver is unpaused
    /// @param resolver The unpaused resolver address
    event ResolverUnpaused(address indexed resolver);
    /// @notice Emitted when resolution is paused for an event
    /// @param id The event identifier
    /// @param timestamp The block timestamp when paused
    event ResolutionPaused(EventId indexed id, uint256 timestamp);
    /// @notice Emitted when resolution is unpaused for an event
    /// @param id The event identifier
    event ResolutionUnpaused(EventId indexed id);
}

/// @title OracleModuleErrors
/// @notice Custom errors for the OracleModule
abstract contract OracleModuleErrors {
    /// @notice Thrown when the resolver is currently paused
    error ResolverIsPaused();
    /// @notice Thrown when resolution is currently paused for the id
    error ResolutionIsPaused();
    /// @notice Thrown when a resolver reports an id for a different resolution chain
    error InvalidResolutionChain();
}

/// @title OracleModule
/// @author Polymarket
/// @notice Role-based resolution controls with event-level pause management
/// @dev Resolution is authorized by bridge or resolver role. No per-condition oracle assignment.
///      Pause controls operate on resolver addresses and event IDs.
abstract contract OracleModule is InitializableRoles, OracleModuleEvents, OracleModuleErrors {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice Resolver address to the timestamp when it was paused.
    mapping(address => uint256) public resolverPausedAt;

    /// @notice Event key to the timestamp when paused.
    mapping(EventId => uint256) public resolutionPausedAt;

    /// @dev Reserved storage gap for future base upgrades.
    uint256[48] private __gap;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to addresses that hold the bridge role.
    modifier onlyBridge() {
        _checkRoles(BRIDGE_ROLE);
        _;
    }

    /// @dev Restricts to bridge or resolver role; reverts if paused. Accepts a typed
    ///      `ConditionId` so non-canonical inputs are caught at the caller boundary; the
    ///      function body may revalidate as defense in depth.
    modifier onlyResolver(ConditionId _id) {
        require(hasAnyRole(msg.sender, BRIDGE_ROLE | RESOLVER_ROLE), Unauthorized());
        if (hasAllRoles(msg.sender, RESOLVER_ROLE)) {
            require(_id.resolutionChain() == uint256(_resolutionChain()), InvalidResolutionChain());
        }
        require(resolverPausedAt[msg.sender] == 0, ResolverIsPaused());
        require(resolutionPausedAt[_id.eventId()] == 0, ResolutionIsPaused());
        _;
    }

    function _resolutionChain() internal view virtual returns (ResolutionChain);

    /*--------------------------------------------------------------
                               ONLY ADMIN
    --------------------------------------------------------------*/

    /// @notice Grant the bridge role to an address
    /// @dev Only callable by an admin.
    /// @param _bridge Address to receive the bridge role
    function addBridge(address _bridge) external onlyAdmin {
        _grantRoles(_bridge, BRIDGE_ROLE);
    }

    /// @notice Revoke the bridge role from an address
    /// @dev Only callable by an admin.
    /// @param _bridge Address to lose the bridge role
    function removeBridge(address _bridge) external onlyAdmin {
        _removeRoles(_bridge, BRIDGE_ROLE);
    }

    /// @notice Grant the resolver role to an address
    /// @dev Only callable by an admin. Used for oracle aggregators that report results.
    /// @param _resolver Address to receive the resolver role
    function addResolver(address _resolver) external onlyAdmin {
        _grantRoles(_resolver, RESOLVER_ROLE);
    }

    /// @notice Revoke the resolver role from an address
    /// @dev Only callable by an admin.
    /// @param _resolver Address to lose the resolver role
    function removeResolver(address _resolver) external onlyAdmin {
        _removeRoles(_resolver, RESOLVER_ROLE);
    }

    /// @notice Pause a resolver, blocking all its resolutions
    /// @param _resolver The resolver address to pause
    function pauseResolver(address _resolver) external onlyAdmin {
        resolverPausedAt[_resolver] = block.timestamp;

        emit ResolverPaused(_resolver, block.timestamp);
    }

    /// @notice Unpause a resolver, re-enabling its resolutions
    /// @param _resolver The resolver address to unpause
    function unpauseResolver(address _resolver) external onlyAdmin {
        resolverPausedAt[_resolver] = 0;

        emit ResolverUnpaused(_resolver);
    }

    /// @notice Pause resolution writes for an event.
    /// @param _eventId The event identifier to pause
    function pauseResolution(EventId _eventId) external onlyAdmin {
        resolutionPausedAt[_eventId] = block.timestamp;

        emit ResolutionPaused(_eventId, block.timestamp);
    }

    /// @notice Unpause resolution writes for an event.
    /// @param _eventId The event identifier to unpause
    function unpauseResolution(EventId _eventId) external onlyAdmin {
        resolutionPausedAt[_eventId] = 0;

        emit ResolutionUnpaused(_eventId);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";

/// @title Roles
/// @author Polymarket
/// @notice Abstract role-based access control built on Solady OwnableRoles
/// @dev Defines five roles: admin (_ROLE_0), operator (_ROLE_1), creator (_ROLE_2), bridge
/// (_ROLE_3), and resolver (_ROLE_4). The owner can grant the admin role; admins can grant/revoke
/// all other roles including admin.
abstract contract Roles is OwnableRoles {
    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @dev Role flag for admin privileges.
    uint256 internal constant ADMIN_ROLE = _ROLE_0;

    /// @dev Role flag for operator privileges.
    uint256 internal constant OPERATOR_ROLE = _ROLE_1;

    /// @dev Role flag for creator privileges.
    uint256 internal constant CREATOR_ROLE = _ROLE_2;

    /// @dev Role flag for bridge privileges.
    uint256 internal constant BRIDGE_ROLE = _ROLE_3;

    /// @dev Role flag for resolver privileges.
    uint256 internal constant RESOLVER_ROLE = _ROLE_4;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts access to addresses that hold the admin role.
    modifier onlyAdmin() {
        _checkRoles(ADMIN_ROLE);
        _;
    }

    /// @dev Restricts access to addresses that hold the operator role.
    modifier onlyOperator() {
        _checkRoles(OPERATOR_ROLE);
        _;
    }

    /// @dev Restricts access to addresses that hold the creator role.
    modifier onlyCreator() {
        _checkRoles(CREATOR_ROLE);
        _;
    }

    /// @dev Restricts access to addresses that hold the bridge role.
    modifier onlyBridge() {
        _checkRoles(BRIDGE_ROLE);
        _;
    }

    /// @dev Restricts access to addresses that hold the resolver role.
    modifier onlyResolverRole() {
        _checkRoles(RESOLVER_ROLE);
        _;
    }

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    constructor(address _owner) {
        _initializeOwner(_owner);
    }

    /*--------------------------------------------------------------
                                EXTERNAL
    --------------------------------------------------------------*/

    /// @notice Grant the admin role to an address
    /// @dev Only callable by the contract owner.
    /// @param _admin Address to receive the admin role
    function addAdmin(address _admin) external onlyOwner {
        _grantRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Revoke the admin role from an address
    /// @dev Only callable by an existing admin.
    /// @param _admin Address to lose the admin role
    function removeAdmin(address _admin) external onlyAdmin {
        _removeRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Grant the operator role to an address
    /// @dev Only callable by an admin.
    /// @param _operator Address to receive the operator role
    function addOperator(address _operator) external onlyAdmin {
        _grantRoles(_operator, OPERATOR_ROLE);
    }

    /// @notice Revoke the operator role from an address
    /// @dev Only callable by an admin.
    /// @param _operator Address to lose the operator role
    function removeOperator(address _operator) external onlyAdmin {
        _removeRoles(_operator, OPERATOR_ROLE);
    }

    /// @notice Grant the creator role to an address
    /// @dev Only callable by an admin.
    /// @param _creator Address to receive the creator role
    function addCreator(address _creator) external onlyAdmin {
        _grantRoles(_creator, CREATOR_ROLE);
    }

    /// @notice Revoke the creator role from an address
    /// @dev Only callable by an admin.
    /// @param _creator Address to lose the creator role
    function removeCreator(address _creator) external onlyAdmin {
        _removeRoles(_creator, CREATOR_ROLE);
    }

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
}

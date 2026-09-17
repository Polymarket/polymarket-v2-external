// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";

/// @title Auth
/// @author Polymarket
/// @notice Role management mixin: admin (_ROLE_0) and operator (_ROLE_1)
abstract contract Auth is OwnableRoles {
    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @dev Role flag for admin privileges.
    uint256 internal constant ADMIN_ROLE = _ROLE_0;

    /// @dev Role flag for operator privileges.
    uint256 internal constant OPERATOR_ROLE = _ROLE_1;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts to admin role holders.
    modifier onlyAdmin() {
        _checkRoles(ADMIN_ROLE);
        _;
    }

    /// @dev Restricts to operator role holders.
    modifier onlyOperator() {
        _checkRoles(OPERATOR_ROLE);
        _;
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
}

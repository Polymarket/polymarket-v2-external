// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title Pausable
/// @author Polymarket
/// @notice Pause mixin with internal controls and unpaused guard
abstract contract Pausable {
    /// @notice Thrown when the system is globally paused.
    error GlobalPaused();

    /// @notice Emitted when global pause state changes.
    /// @param paused The new pause state.
    event GlobalPauseSet(bool paused);

    /// @notice Global pause flag
    bool public globalPaused;

    /// @dev Reserved storage gap for future base upgrades.
    uint256[49] private __gap;

    /// @dev Restricts to unpaused state.
    modifier whenUnpaused() {
        require(!globalPaused, GlobalPaused());
        _;
    }

    /// @notice Pause the system.
    function _pause() internal {
        globalPaused = true;
        emit GlobalPauseSet(true);
    }

    /// @notice Unpause the system.
    function _unpause() internal {
        globalPaused = false;
        emit GlobalPauseSet(false);
    }
}

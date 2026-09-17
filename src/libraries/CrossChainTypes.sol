// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.15;

import { PositionId } from "./Ids.sol";

/*--------------------------------------------------------------
                             ENUMS
--------------------------------------------------------------*/

/// @notice Message types for cross-chain bridge communication
enum MessageType {
    POSITIONS, // Bridge positions between chains
    COLLATERAL, // Bridge collateral (PMCT) between chains
    RESULT // Push resolution result to spoke
}

/*--------------------------------------------------------------
                            STRUCTS
--------------------------------------------------------------*/

/// @notice Position data for cross-chain bridging
/// @dev conditionId is derived from positionId via PositionIdLib.conditionId on the
/// receiving side
struct BridgedPosition {
    /// @dev Position ID (supports both new and legacy).
    PositionId positionId;
    /// @dev Amount to bridge.
    uint256 amount;
}

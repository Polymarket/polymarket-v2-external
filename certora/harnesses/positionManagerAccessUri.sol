// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { PositionManager as PositionManagerBase } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { PositionId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title PositionManager verification harness (ACCESS-URI-PAYOUT-01)
/// @notice Extends production PositionManager with one pure helper: `moduleIdOf` exposes the exact
///         `PositionIdLib.moduleId` bit-extraction the guards in `uri`/`getPayout` use, so the spec
///         states its precondition on `moduleById[moduleIdOf(pid)]` without re-deriving `>> 248`.
contract PositionManagerHarness is PositionManagerBase {
    constructor(address _collateralToken) PositionManagerBase(_collateralToken) { }

    /// @notice The moduleId `uri`/`getPayout` derive from a position id, via the same library call.
    function moduleIdOf(uint256 _pid) external pure returns (uint256) {
        return PositionId.wrap(_pid).moduleId();
    }
}

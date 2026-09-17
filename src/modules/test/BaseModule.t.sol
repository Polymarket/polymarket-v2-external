// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { BaseModule, BaseModuleEvents } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import {
    Collateral,
    Positions,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";

/// @title BaseModuleTest
/// @notice Abstract test contract for BaseModule functionality
/// @dev All concrete module tests should inherit this to ensure base functionality is tested
abstract contract BaseModuleTest is TestHelper, BaseModuleEvents {
    error Unauthorized();

    Positions positions;
    Collateral collateral;

    address bridge;

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);

        bridge = vm.createWallet("bridge").addr;

        // Grant bridge role to bridge address on the module being tested
        vm.prank(admin);
        _module().addBridge(bridge);
    }

    /*--------------------------------------------------------------
                            VIRTUAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Returns the module being tested
    function _module() internal view virtual returns (BaseModule);

    /// @notice Prepares a condition using module-specific logic
    /// @return conditionId The condition ID
    function _prepareCondition() internal virtual returns (bytes32 conditionId);

    /// @notice Returns a condition ID for testing bridge functions
    /// @dev Non-view to allow NegRisk to store eventId for later use in _reportResultFromBridge
    function _getBridgeConditionId() internal virtual returns (bytes32);

    /// @notice Reports a YES result for the given conditionId
    function _reportResult(bytes32 _conditionId) internal virtual;

    /// @notice Reports a 50/50 result for the given conditionId
    /// @dev Used for testing partial payout scenarios
    function _reportPartialResult(bytes32 _conditionId) internal virtual;

    /// @notice Reports a result from the bridge for a bridged condition
    /// @dev Concrete tests implement this based on their module's reportResult signature
    function _reportResultFromBridge(bytes32 _conditionId, uint256[] memory _result) internal virtual;

    /// @notice Redeems a position for the given conditionId
    /// @dev Concrete tests implement this using their router
    function _redeem(address _user, bytes32 _conditionId, uint256 _outcomeIndex, uint256 _amount) internal virtual;

    /*--------------------------------------------------------------
                            mintFromBridge
    --------------------------------------------------------------*/

    function _assert_mintFromBridge() internal {
        bytes32 conditionId = _getBridgeConditionId();

        uint256 amount = 1_000_000;
        uint256 positionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0)); // outcome
        // 0

        // Verify alice has no balance
        assertEq(positions.manager.balanceOf(alice, positionId), 0);

        // Bridge mints to alice
        vm.prank(bridge);
        _module().mintFromBridge(alice, PositionId.wrap(positionId), amount);

        // Verify alice received the position
        assertEq(positions.manager.balanceOf(alice, positionId), amount);
    }

    function _assert_mintFromBridge_zeroAmount() internal {
        bytes32 conditionId = _getBridgeConditionId();

        uint256 positionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0)); // outcome
        // 0

        // Verify alice has no balance
        assertEq(positions.manager.balanceOf(alice, positionId), 0);

        // Bridge mints zero amount - should not revert, just emit event
        vm.prank(bridge);
        _module().mintFromBridge(alice, PositionId.wrap(positionId), 0);

        // Balance should still be zero
        assertEq(positions.manager.balanceOf(alice, positionId), 0);
    }

    function _assert_revert_mintFromBridge_unauthorized() internal {
        bytes32 conditionId = _getBridgeConditionId();

        uint256 positionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));

        // Non-bridge caller should revert
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        _module().mintFromBridge(alice, PositionId.wrap(positionId), 1_000_000);
    }

    function _assert_mintFromBridge_thenRedeem() internal {
        // This test verifies that after bridging positions, redemption works correctly
        // This is critical because onRedeem derives positionId using getPositionId(conditionId,
        // outcomeIndex)
        bytes32 conditionId = _getBridgeConditionId();

        // Bridge mints position (outcome 0)
        uint256 positionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));
        uint256 amount = 1_000_000;
        vm.prank(bridge);
        _module().mintFromBridge(alice, PositionId.wrap(positionId), amount);

        // Verify alice received the position
        assertEq(positions.manager.balanceOf(alice, positionId), amount);

        // Bridge reports result (YES wins - 100% to outcome 0)
        uint256[] memory resultArray = new uint256[](2);
        resultArray[0] = 1_000_000;
        resultArray[1] = 0;
        _reportResultFromBridge(conditionId, resultArray);

        // Alice redeems - this verifies positionId derivation matches
        _redeem(alice, conditionId, 0, amount);

        // Verify alice received collateral
        assertEq(collateral.token.balanceOf(alice), amount);
        // Verify position was burned
        assertEq(positions.manager.balanceOf(alice, positionId), 0);
    }

    /*--------------------------------------------------------------
                          onERC1155Received
    --------------------------------------------------------------*/

    function _assert_burnFromBridge() internal {
        bytes32 conditionId = _getBridgeConditionId();

        uint256 amount = 1_000_000;
        uint256 positionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));

        // Mint to bridge
        vm.prank(bridge);
        _module().mintFromBridge(bridge, PositionId.wrap(positionId), amount);

        // Verify bridge has the position
        assertEq(positions.manager.balanceOf(bridge, positionId), amount);

        // Bridge transfers to module, then calls burnFromBridge
        PositionId[] memory ids = new PositionId[](1);
        ids[0] = PositionId.wrap(positionId);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.startPrank(bridge);
        positions.manager.safeTransferFrom(bridge, address(_module()), positionId, amount, "");
        _module().burnFromBridge(ids, amounts);
        vm.stopPrank();

        // Verify position was burned (module balance is 0, bridge balance is 0)
        assertEq(positions.manager.balanceOf(bridge, positionId), 0);
        assertEq(positions.manager.balanceOf(address(_module()), positionId), 0);
    }

    function _assert_onERC1155Received_normalTransfer() internal {
        bytes32 conditionId = _getBridgeConditionId();

        uint256 amount = 1_000_000;
        uint256 positionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));

        // Mint to alice
        vm.prank(bridge);
        _module().mintFromBridge(alice, PositionId.wrap(positionId), amount);

        // Verify alice has the position
        assertEq(positions.manager.balanceOf(alice, positionId), amount);

        // Alice (non-bridge) transfers to module - should NOT burn
        vm.prank(alice);
        positions.manager.safeTransferFrom(alice, address(_module()), positionId, amount, "");

        // Verify position was NOT burned (module holds it)
        assertEq(positions.manager.balanceOf(alice, positionId), 0);
        assertEq(positions.manager.balanceOf(address(_module()), positionId), amount);
    }

    /*--------------------------------------------------------------
                        onERC1155BatchReceived
    --------------------------------------------------------------*/

    function _assert_burnFromBridge_batch() internal {
        bytes32 conditionId = _getBridgeConditionId();

        uint256 amount = 1_000_000;
        uint256 positionId0 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));
        uint256 positionId1 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 1));

        // Mint both positions to bridge
        vm.startPrank(bridge);
        _module().mintFromBridge(bridge, PositionId.wrap(positionId0), amount);
        _module().mintFromBridge(bridge, PositionId.wrap(positionId1), amount);
        vm.stopPrank();

        // Verify bridge has both positions
        assertEq(positions.manager.balanceOf(bridge, positionId0), amount);
        assertEq(positions.manager.balanceOf(bridge, positionId1), amount);

        // Prepare batch arrays
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId0;
        ids[1] = positionId1;
        PositionId[] memory pIds = new PositionId[](2);
        pIds[0] = PositionId.wrap(positionId0);
        pIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        // Bridge batch transfers to module, then calls burnFromBridge
        vm.startPrank(bridge);
        positions.manager.safeBatchTransferFrom(bridge, address(_module()), ids, amounts, "");
        _module().burnFromBridge(pIds, amounts);
        vm.stopPrank();

        // Verify all positions were burned
        assertEq(positions.manager.balanceOf(bridge, positionId0), 0);
        assertEq(positions.manager.balanceOf(bridge, positionId1), 0);
        assertEq(positions.manager.balanceOf(address(_module()), positionId0), 0);
        assertEq(positions.manager.balanceOf(address(_module()), positionId1), 0);
    }

    function _assert_onERC1155BatchReceived_normalTransfer() internal {
        bytes32 conditionId = _getBridgeConditionId();

        uint256 amount = 1_000_000;
        uint256 positionId0 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));
        uint256 positionId1 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 1));

        // Mint both positions to alice
        vm.startPrank(bridge);
        _module().mintFromBridge(alice, PositionId.wrap(positionId0), amount);
        _module().mintFromBridge(alice, PositionId.wrap(positionId1), amount);
        vm.stopPrank();

        // Verify alice has both positions
        assertEq(positions.manager.balanceOf(alice, positionId0), amount);
        assertEq(positions.manager.balanceOf(alice, positionId1), amount);

        // Prepare batch arrays
        uint256[] memory ids = new uint256[](2);
        ids[0] = positionId0;
        ids[1] = positionId1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        // Alice (non-bridge) batch transfers to module - should NOT burn
        vm.prank(alice);
        positions.manager.safeBatchTransferFrom(alice, address(_module()), ids, amounts, "");

        // Verify positions were NOT burned (module holds them)
        assertEq(positions.manager.balanceOf(alice, positionId0), 0);
        assertEq(positions.manager.balanceOf(alice, positionId1), 0);
        assertEq(positions.manager.balanceOf(address(_module()), positionId0), amount);
        assertEq(positions.manager.balanceOf(address(_module()), positionId1), amount);
    }

    /*--------------------------------------------------------------
                              hasResult
    --------------------------------------------------------------*/

    function _assert_hasResult_false() internal {
        // Prepare condition via normal flow (sets oracle properly)
        bytes32 conditionId = _prepareCondition();

        // Result not yet reported
        assertFalse(_module().hasResult(ConditionIdLib.from(conditionId)));
    }

    function _assert_hasResult_true() internal {
        // Prepare condition via normal flow
        bytes32 conditionId = _prepareCondition();

        // Report result
        _reportResult(conditionId);

        // Result should now exist
        assertTrue(_module().hasResult(ConditionIdLib.from(conditionId)));
    }

    /*--------------------------------------------------------------
                              getPayout
    --------------------------------------------------------------*/

    function _assert_revert_getPayout_conditionNotResolved() internal {
        // Prepare condition but don't report result
        bytes32 conditionId = _prepareCondition();
        PositionId positionId = ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0);

        // getPayout should revert for unresolved question
        vm.expectRevert(ModuleErrors.ConditionNotResolved.selector);
        _module().getPayout(positionId, 1_000_000);
    }

    function _assert_revert_getPayout_invalidOutcomeIndex() internal {
        // Prepare condition and report result
        bytes32 conditionId = _prepareCondition();
        _reportResult(conditionId);

        // getPayout with outcomeIndex >= 2 should revert
        PositionId positionId = ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 2);
        vm.expectRevert(ModuleErrors.InvalidOutcomeIndex.selector);
        _module().getPayout(positionId, 1_000_000);
    }

    function _assert_getPayout_fullPayout() internal {
        // Prepare condition and report YES wins (100% to outcome 0)
        bytes32 conditionId = _prepareCondition();
        _reportResult(conditionId);

        uint256 amount = 1_000_000;

        // Outcome 0 (YES) should get full payout
        PositionId positionId0 = ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0);
        uint256 payout0 = _module().getPayout(positionId0, amount);
        assertEq(payout0, amount, "YES should get full payout");

        // Outcome 1 (NO) should get nothing
        PositionId positionId1 = ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 1);
        uint256 payout1 = _module().getPayout(positionId1, amount);
        assertEq(payout1, 0, "NO should get nothing");
    }

    function _assert_getPayout_partialPayout() internal {
        // Prepare condition and report 50/50 split
        bytes32 conditionId = _prepareCondition();
        _reportPartialResult(conditionId);

        uint256 amount = 1_000_000;

        // Both outcomes should get half
        PositionId positionId0 = ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0);
        PositionId positionId1 = ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 1);
        uint256 payout0 = _module().getPayout(positionId0, amount);
        uint256 payout1 = _module().getPayout(positionId1, amount);

        assertEq(payout0, amount / 2, "Outcome 0 should get half");
        assertEq(payout1, amount / 2, "Outcome 1 should get half");
    }
}

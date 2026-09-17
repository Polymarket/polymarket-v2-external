// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId, EventId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { Positions, PositionManagerSetup } from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { Router, RouterEvents } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

contract RouterNegRiskModule_Test is TestHelper, RouterEvents {
    error Unauthorized();

    Positions positions;
    Collateral collateral;
    Router router;

    EventId eventId;
    uint256 conditionCount = 256;

    function _horizontalLegCount() internal view returns (uint256) {
        return conditionCount + 1;
    }

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);

        router = RouterSetup.deployRouter(address(positions.manager), owner);

        vm.prank(creator);
        eventId = positions.negRiskModule.getEventId(conditionCount, "neg risk event");

        vm.prank(admin);
        positions.negRiskModule.addResolver(oracle);
    }

    function _split(uint256 _outcomeIndex) internal returns (ConditionId) {
        uint256 outcomeIndex = _outcomeIndex % conditionCount;

        ConditionId conditionId_ = EventIdLib.computeConditionId(eventId, outcomeIndex);

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId_, 1_000_000_000);
        vm.stopPrank();

        uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 0));
        uint256 positionId1 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 1));

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(positions.manager.balanceOf(alice, positionId0), 1_000_000_000);
        assertEq(positions.manager.balanceOf(alice, positionId1), 1_000_000_000);

        return conditionId_;
    }

    function _horizontalSplit() internal {
        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.horizontalSplit(eventId, 1_000_000_000);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                            SPLIT
--------------------------------------------------------------*/

contract RouterNegRiskModule_Test_split is RouterNegRiskModule_Test {
    function test_split(uint256 _outcomeIndex) public {
        _split(_outcomeIndex);
    }
}

/*--------------------------------------------------------------
                            MERGE
--------------------------------------------------------------*/

contract RouterNegRiskModule_Test_merge is RouterNegRiskModule_Test {
    function test_merge(uint256 _outcomeIndex) public {
        uint256 outcomeIndex = _outcomeIndex % conditionCount;

        ConditionId conditionId_ = _split(outcomeIndex);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        router.merge(conditionId_, 1_000_000_000);
        vm.stopPrank();

        uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 1));
        uint256 positionId1 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 2));

        assertEq(collateral.token.balanceOf(alice), 1_000_000_000);

        assertEq(positions.manager.balanceOf(alice, positionId0), 0);
        assertEq(positions.manager.balanceOf(alice, positionId1), 0);
    }
}

/*--------------------------------------------------------------
                         HORIZONTAL
--------------------------------------------------------------*/

contract RouterNegRiskModule_Test_horizontal is RouterNegRiskModule_Test {
    function test_horizontalSplit() public {
        _horizontalSplit();

        for (uint256 i = 0; i < _horizontalLegCount(); i++) {
            ConditionId conditionId_ = EventIdLib.computeConditionId(eventId, i);
            uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 0));
            assertEq(positions.manager.balanceOf(alice, positionId0), 1_000_000_000);
            assertEq(
                positions.manager
                .balanceOf(alice, PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 1))),
                0
            );
        }

        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_horizontalMerge() public {
        _horizontalSplit();

        vm.startPrank(alice);
        for (uint256 i = 0; i < _horizontalLegCount(); i++) {
            ConditionId conditionId_ = EventIdLib.computeConditionId(eventId, i);
            uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 0));
            positions.manager.safeTransferFrom(alice, brian, positionId0, 1_000_000_000, "");
        }

        vm.startPrank(brian);
        positions.manager.setApprovalForAll(address(router), true);
        router.horizontalMerge(eventId, 1_000_000_000);
        vm.stopPrank();

        for (uint256 i = 0; i < _horizontalLegCount(); i++) {
            ConditionId conditionId_ = EventIdLib.computeConditionId(eventId, i);
            uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 0));
            assertEq(positions.manager.balanceOf(brian, positionId0), 0);
        }

        assertEq(collateral.token.balanceOf(brian), 1_000_000_000);
    }
}

/*--------------------------------------------------------------
                            CONVERT
--------------------------------------------------------------*/

contract RouterNegRiskModule_Test_convert is RouterNegRiskModule_Test {
    function test_convert(uint256 _conditionIndex) public {
        uint16 conditionIndex = uint16(_conditionIndex % conditionCount);
        uint256 amount = 100_000_000;

        // Split one condition to get a NO position for brian
        ConditionId conditionId_ = EventIdLib.computeConditionId(eventId, conditionIndex);

        collateral.usdc.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), alice, amount);
        collateral.token.approve(address(router), amount);
        router.split(conditionId_, amount);
        // Give brian the NO position
        positions.manager
            .safeTransferFrom(
                alice, brian, PositionId.unwrap(ConditionIdLib.computePositionId(conditionId_, 1)), amount, ""
            );
        vm.stopPrank();

        // Brian converts the NO into YES positions for all other conditions
        vm.startPrank(brian);
        positions.manager.setApprovalForAll(address(router), true);
        router.convert(eventId, conditionIndex, amount);
        vm.stopPrank();

        // Brian should have YES positions for all conditions except the source
        for (uint256 i = 0; i < conditionCount; i++) {
            ConditionId cid = EventIdLib.computeConditionId(eventId, i);
            uint256 yesPositionId = PositionId.unwrap(ConditionIdLib.computePositionId(cid, 0));
            if (i == conditionIndex) assertEq(positions.manager.balanceOf(brian, yesPositionId), 0);
            else assertEq(positions.manager.balanceOf(brian, yesPositionId), amount);
        }

        // No collateral changes for brian
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    /// @dev uint16 values >= conditionCount are rejected by NegRiskModule.convert. Prior to the
    /// cantina #9 fix, Router accepted a uint256 here and PositionIdLib silently masked it to 16
    /// bits; now the uint16 parameter type documents the valid range at the ABI boundary while
    /// still relying on the module for the conditionCount bounds check.
    function test_revert_conditionIndexOutOfRange() public {
        _fundBrianNoForOutOfRangeIndex(uint16(conditionCount + 1));

        vm.startPrank(brian);
        positions.manager.setApprovalForAll(address(router), true);
        vm.expectRevert(ModuleErrors.InvalidConditionIndex.selector);
        router.convert(eventId, uint16(conditionCount + 1), 1);
        vm.stopPrank();
    }

    /// @dev Sanity check that the maximum uint16 value is rejected by the module's bounds check
    /// (the event here has 256 conditions so 65535 is out of range).
    function test_revert_conditionIndexMaxUint16() public {
        _fundBrianNoForOutOfRangeIndex(type(uint16).max);

        vm.startPrank(brian);
        positions.manager.setApprovalForAll(address(router), true);
        vm.expectRevert(ModuleErrors.InvalidConditionIndex.selector);
        router.convert(eventId, type(uint16).max, 1);
        vm.stopPrank();
    }

    /// @dev Gives brian a NO position at `_conditionIndex` via unsafe mint. Used by the revert
    /// tests above: the Router transfers the NO position to the module before calling `convert`,
    /// so brian must hold a balance for the conditionIndex check to be the first revert reached.
    function _fundBrianNoForOutOfRangeIndex(uint16 _conditionIndex) internal {
        ConditionId cid = EventIdLib.computeConditionId(eventId, _conditionIndex);
        uint256 noPositionId = PositionId.unwrap(ConditionIdLib.computePositionId(cid, 1));
        vm.prank(address(positions.negRiskModule));
        positions.manager.mint(brian, PositionId.wrap(noPositionId), 1);
    }
}

/*--------------------------------------------------------------
                            EVENTS
--------------------------------------------------------------*/

contract RouterNegRiskModule_Test_events is RouterNegRiskModule_Test {
    function test_horizontalSplit_emitsHorizontalSplit() public {
        uint256 amount = 1_000_000_000;
        collateral.usdc.mint(alice, amount);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), alice, amount);
        collateral.token.approve(address(router), amount);

        vm.expectEmit(true, true, true, true, address(router));
        emit RouterHorizontalSplit(alice, eventId, amount);
        router.horizontalSplit(eventId, amount);
        vm.stopPrank();
    }

    function test_horizontalMerge_emitsHorizontalMerge() public {
        _horizontalSplit();
        uint256 amount = 1_000_000_000;

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);

        vm.expectEmit(true, true, true, true, address(router));
        emit RouterHorizontalMerge(alice, eventId, amount);
        router.horizontalMerge(eventId, amount);
        vm.stopPrank();
    }

    function test_convert_emitsPositionConverted() public {
        _horizontalSplit(); // gives alice 1 YES per condition; she has no NO yet
        uint16 conditionIndex = 7;
        uint256 amount = 1_000_000_000;

        // Mint alice a NO at the target index so convert has something to burn.
        ConditionId cid = EventIdLib.computeConditionId(eventId, conditionIndex);
        uint256 noId = PositionId.unwrap(ConditionIdLib.computePositionId(cid, 1));
        vm.prank(address(positions.negRiskModule));
        positions.manager.mint(alice, PositionId.wrap(noId), amount);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);

        vm.expectEmit(true, true, true, true, address(router));
        emit RouterPositionConverted(alice, eventId, conditionIndex, amount);
        router.convert(eventId, conditionIndex, amount);
        vm.stopPrank();
    }
}

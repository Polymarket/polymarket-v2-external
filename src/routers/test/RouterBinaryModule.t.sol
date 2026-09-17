// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { Positions, PositionManagerSetup } from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { Router, RouterErrors, RouterEvents } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

contract RouterBinaryModuleTest is TestHelper, RouterErrors, RouterEvents {
    Positions positions;
    Collateral collateral;
    Router router;
    address bridge;

    ConditionId conditionId;

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);

        router = RouterSetup.deployRouter(address(positions.manager), owner);
        bridge = vm.createWallet("bridge").addr;

        vm.startPrank(admin);
        positions.binaryModule.addBridge(bridge);
        positions.binaryModule.addResolver(oracle);
        vm.stopPrank();
    }

    function _split() internal returns (ConditionId, uint256, uint256) {
        conditionId = positions.binaryModule.getConditionId("condition");

        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        positionIds[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(positions.manager.balanceOf(alice, positionIds[0]), 1_000_000_000);
        assertEq(positions.manager.balanceOf(alice, positionIds[1]), 1_000_000_000);

        return (conditionId, positionIds[0], positionIds[1]);
    }

    function _mintUnpreparedConditionPositions(ConditionId _conditionId, uint256 _amount)
        internal
        returns (uint256, uint256)
    {
        uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(_conditionId, 0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.computePositionId(_conditionId, 1));

        vm.startPrank(bridge);
        positions.binaryModule.mintFromBridge(alice, PositionId.wrap(yesId), _amount);
        positions.binaryModule.mintFromBridge(alice, PositionId.wrap(noId), _amount);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), _amount);
        assertEq(positions.manager.balanceOf(alice, noId), _amount);

        return (yesId, noId);
    }
}

/*--------------------------------------------------------------
                            SPLIT
--------------------------------------------------------------*/

contract RouterBinaryModuleTest_split is RouterBinaryModuleTest {
    function test_split() public {
        _split();
    }

    function test_split_anyCondition() public {
        ConditionId anyConditionId =
            positions.binaryModule.getConditionId(abi.encodePacked("any-condition", block.timestamp));

        uint256 amount = 1_000_000_000;

        collateral.usdc.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), alice, amount);
        collateral.token.approve(address(router), amount);

        // Split succeeds without prior condition preparation
        router.split(anyConditionId, amount);
        vm.stopPrank();

        uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(anyConditionId, 0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.computePositionId(anyConditionId, 1));
        assertEq(positions.manager.balanceOf(alice, yesId), amount);
        assertEq(positions.manager.balanceOf(alice, noId), amount);
    }
}

/*--------------------------------------------------------------
                            MERGE
--------------------------------------------------------------*/

contract RouterBinaryModuleTest_merge is RouterBinaryModuleTest {
    function test_merge() public {
        (ConditionId conditionId_, uint256 positionId0, uint256 positionId1) = _split();

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        router.merge(conditionId_, 1_000_000_000);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 1_000_000_000);
        assertEq(positions.manager.balanceOf(alice, positionId0), 0);
        assertEq(positions.manager.balanceOf(alice, positionId1), 0);
    }

    function test_merge_anyCondition() public {
        ConditionId anyConditionId =
            positions.binaryModule.getConditionId(abi.encodePacked("any-merge", block.timestamp));
        uint256 amount = 1_000_000_000;

        _mintUnpreparedConditionPositions(anyConditionId, amount);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);

        // Merge succeeds without prior condition preparation
        router.merge(anyConditionId, amount);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), amount);
    }
}

/*--------------------------------------------------------------
                           REDEEM
--------------------------------------------------------------*/

contract RouterBinaryModuleTest_redeem is RouterBinaryModuleTest {
    function test_redeem(bool _outcome) public {
        (ConditionId conditionId_, uint256 positionId0, uint256 positionId1) = _split();

        uint256[] memory result = new uint256[](2);
        result[_outcome ? 0 : 1] = 1_000_000;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        vm.startPrank(alice);
        positions.manager.safeTransferFrom(alice, brian, positionId1, 1_000_000_000, "");
        positions.manager.setApprovalForAll(address(router), true);
        router.redeem(conditionId_, 0, 1_000_000_000);
        vm.stopPrank();

        vm.startPrank(brian);
        positions.manager.setApprovalForAll(address(router), true);
        router.redeem(conditionId_, 1, 1_000_000_000);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, positionId1), 0);
        assertEq(positions.manager.balanceOf(brian, positionId0), 0);

        assertEq(collateral.token.balanceOf(alice), _outcome ? 1_000_000_000 : 0);
        assertEq(collateral.token.balanceOf(brian), _outcome ? 0 : 1_000_000_000);
    }

    function test_revert_invalidOutcomeIndex_two() public {
        ConditionId conditionId_ = positions.binaryModule.getConditionId("condition");

        vm.prank(alice);
        vm.expectRevert(InvalidOutcomeIndex.selector);
        router.redeem(conditionId_, 2, 1_000_000_000);
    }

    function test_revert_invalidOutcomeIndex_aliased() public {
        ConditionId conditionId_ = positions.binaryModule.getConditionId("condition");

        // 256 would alias to outcome 0 after OUTCOME_MASK; 257 would alias to 1.
        vm.prank(alice);
        vm.expectRevert(InvalidOutcomeIndex.selector);
        router.redeem(conditionId_, 256, 1_000_000_000);

        vm.prank(alice);
        vm.expectRevert(InvalidOutcomeIndex.selector);
        router.redeem(conditionId_, 257, 1_000_000_000);
    }

    function test_revert_invalidOutcomeIndex_max(uint256 _outcomeIndex) public {
        _outcomeIndex = bound(_outcomeIndex, 2, type(uint256).max);
        ConditionId conditionId_ = positions.binaryModule.getConditionId("condition");

        vm.prank(alice);
        vm.expectRevert(InvalidOutcomeIndex.selector);
        router.redeem(conditionId_, _outcomeIndex, 1_000_000_000);
    }
}

/*--------------------------------------------------------------
                            EVENTS
--------------------------------------------------------------*/

contract RouterBinaryModuleTest_events is RouterBinaryModuleTest {
    function test_split_emitsPositionSplit() public {
        uint256 amount = 1_000_000_000;
        ConditionId cid = positions.binaryModule.getConditionId("event-test-split");

        collateral.usdc.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), alice, amount);
        collateral.token.approve(address(router), amount);

        vm.expectEmit(true, true, true, true, address(router));
        emit RouterPositionSplit(alice, cid, amount);
        router.split(cid, amount);
        vm.stopPrank();
    }

    function test_merge_emitsPositionsMerged() public {
        (ConditionId cid,,) = _split();
        uint256 amount = 1_000_000_000;

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);

        vm.expectEmit(true, true, true, true, address(router));
        emit RouterPositionsMerged(alice, cid, amount);
        router.merge(cid, amount);
        vm.stopPrank();
    }

    function test_redeem_emitsPositionRedeemed() public {
        (ConditionId cid, uint256 yesId,) = _split();
        uint256 amount = 1_000_000_000;

        // Resolve YES so redeem pays out.
        vm.prank(oracle);
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;
        positions.binaryModule.reportResult(cid, result);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);

        vm.expectEmit(true, true, true, true, address(router));
        emit RouterPositionRedeemed(alice, PositionId.wrap(yesId), amount);
        router.redeem(cid, 0, amount);
        vm.stopPrank();
    }
}

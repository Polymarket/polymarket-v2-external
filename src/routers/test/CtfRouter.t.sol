// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";
import { Ownable } from "@solady/src/auth/Ownable.sol";
import { CallContextChecker } from "@solady/src/utils/CallContextChecker.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { CtfRouter, CtfRouterEvents, CtfRouterErrors } from "@polymarket-v2/src/routers/CtfRouter.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import {
    Collateral,
    Positions,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";

contract CtfRouterTest is TestHelper, CtfRouterEvents, CtfRouterErrors, ModuleErrors {
    Positions positions;
    Collateral collateral;
    CtfRouter ctfRouter;

    uint256 AMOUNT = 1_000_000_000;
    bytes32 conditionId;

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);

        ctfRouter = RouterSetup.deployCtfRouter(address(positions.manager), address(collateral.token), owner);

        vm.prank(admin);
        positions.binaryModule.addResolver(oracle);
    }

    function _splitPositions() internal returns (bytes32 conditionId_, uint256[] memory positionIds) {
        conditionId_ = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("condition")));
        conditionId = conditionId_;
        positionIds = new uint256[](2);
        positionIds[0] = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId_)), 0));
        positionIds[1] = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId_)), 1));

        collateral.usdc.mint(alice, AMOUNT); // 1000 USDC

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), AMOUNT);
        collateral.onramp.wrap(address(collateral.usdc), alice, AMOUNT);
        collateral.token.approve(address(ctfRouter), AMOUNT);
        uint256[] memory partition = new uint256[](2);
        ctfRouter.splitPosition(address(0), bytes32(0), conditionId_, partition, AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(positions.manager.balanceOf(alice, positionIds[0]), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, positionIds[1]), AMOUNT);
    }
}

/*--------------------------------------------------------------
                      SPLIT POSITION
--------------------------------------------------------------*/

contract CtfRouterTest_splitPosition is CtfRouterTest {
    function test_split() public {
        _splitPositions();
    }
}

/*--------------------------------------------------------------
                     MERGE POSITIONS
--------------------------------------------------------------*/

contract CtfRouterTest_mergePositions is CtfRouterTest {
    function test_merge() public {
        (bytes32 conditionId_, uint256[] memory positionIds) = _splitPositions();

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(ctfRouter), true);
        uint256[] memory partition = new uint256[](2);
        ctfRouter.mergePositions(address(0), bytes32(0), conditionId_, partition, AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);

        assertEq(positions.manager.balanceOf(alice, positionIds[0]), 0);
        assertEq(positions.manager.balanceOf(alice, positionIds[1]), 0);
    }
}

/*--------------------------------------------------------------
                    REDEEM POSITIONS
--------------------------------------------------------------*/

contract CtfRouterTest_redeemPositions is CtfRouterTest {
    function test_redeem(bool _outcome, uint256 _brianIndex) public {
        uint256 brianIndex = _brianIndex % 2;

        (bytes32 conditionId_, uint256[] memory positionIds) = _splitPositions();

        uint256[] memory result = new uint256[](2);
        result[_outcome ? 0 : 1] = 1_000_000;

        vm.prank(oracle);
        positions.binaryModule.reportResult(ConditionIdLib.from(conditionId), result);

        vm.startPrank(alice);
        positions.manager.safeTransferFrom(alice, brian, positionIds[brianIndex], AMOUNT, "");
        vm.stopPrank();

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = brianIndex + 1;

        vm.startPrank(brian);
        positions.manager.setApprovalForAll(address(ctfRouter), true);
        ctfRouter.redeemPositions(address(0), bytes32(0), conditionId_, indexSets);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(brian, positionIds[brianIndex]), 0);

        assertEq(
            collateral.token.balanceOf(brian),
            (brianIndex == 1 && !_outcome) || (brianIndex == 0 && _outcome) ? AMOUNT : 0
        );
    }
}

/*--------------------------------------------------------------
        REDEEM POSITIONS - INVALID INDEX SET SKIP
--------------------------------------------------------------*/

/// @notice Tests for CtfRouter.redeemPositions revert-on-invalid-index-set behavior.
/// @dev Previously invalid entries were silently skipped; the router now reverts with
///      ModuleErrors.InvalidIndexSet so mis-encoded calls surface as failures.
contract CtfRouterTest_redeemInvalidIndexSet is CtfRouterTest {
    function test_revert_redeemPositions_indexSetZero() public {
        bytes32 conditionId_ = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("ctf_router_zero")));

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 0; // 0 is not a valid outcome index set for binary conditions

        vm.expectRevert(ModuleErrors.InvalidIndexSet.selector);
        vm.prank(alice);
        ctfRouter.redeemPositions(address(0), bytes32(0), conditionId_, indexSets);
    }

    function test_revert_redeemPositions_indexSetThree() public {
        bytes32 conditionId_ = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("ctf_router_three")));

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 3; // 3 is the "both outcomes" legacy CTF mask, not valid in V2

        vm.expectRevert(ModuleErrors.InvalidIndexSet.selector);
        vm.prank(alice);
        ctfRouter.redeemPositions(address(0), bytes32(0), conditionId_, indexSets);
    }

    function test_revert_redeemPositions_indexSetInvalidAmongValid() public {
        // Reverts even when the invalid entry sits after valid entries. Verifies the
        // loop does not partially redeem before the bad entry.
        bytes32 conditionId_ = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("ctf_router_mixed")));

        collateral.usdc.mint(alice, AMOUNT);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), AMOUNT);
        collateral.onramp.wrap(address(collateral.usdc), alice, AMOUNT);
        collateral.token.approve(address(ctfRouter), AMOUNT);
        uint256[] memory partition = new uint256[](2);
        ctfRouter.splitPosition(address(0), bytes32(0), conditionId_, partition, AMOUNT);
        vm.stopPrank();

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        vm.prank(oracle);
        positions.binaryModule.reportResult(ConditionIdLib.from(conditionId_), result);

        uint256[] memory indexSets = new uint256[](3);
        indexSets[0] = 1;
        indexSets[1] = 3; // invalid
        indexSets[2] = 2;

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(ctfRouter), true);
        vm.expectRevert(ModuleErrors.InvalidIndexSet.selector);
        ctfRouter.redeemPositions(address(0), bytes32(0), conditionId_, indexSets);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                            EVENTS
--------------------------------------------------------------*/

contract CtfRouterTest_events is CtfRouterTest {
    function test_splitPosition_emitsPositionSplit() public {
        bytes32 cidRaw = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("events-condition")));
        ConditionId cid = ConditionId.wrap(bytes31(cidRaw));

        collateral.usdc.mint(alice, AMOUNT);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), AMOUNT);
        collateral.onramp.wrap(address(collateral.usdc), alice, AMOUNT);
        collateral.token.approve(address(ctfRouter), AMOUNT);

        uint256[] memory partition = new uint256[](2);
        vm.expectEmit(true, true, true, true, address(ctfRouter));
        emit CtfRouterPositionSplit(alice, cid, AMOUNT);
        ctfRouter.splitPosition(address(0), bytes32(0), cidRaw, partition, AMOUNT);
        vm.stopPrank();
    }

    function test_mergePositions_emitsPositionsMerged() public {
        (bytes32 cidRaw,) = _splitPositions();
        ConditionId cid = ConditionId.wrap(bytes31(cidRaw));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(ctfRouter), true);

        uint256[] memory partition = new uint256[](2);
        vm.expectEmit(true, true, true, true, address(ctfRouter));
        emit CtfRouterPositionsMerged(alice, cid, AMOUNT);
        ctfRouter.mergePositions(address(0), bytes32(0), cidRaw, partition, AMOUNT);
        vm.stopPrank();
    }

    function test_redeemPositions_emitsPositionRedeemedPerIndex() public {
        (bytes32 cidRaw, uint256[] memory positionIds) = _splitPositions();
        ConditionId cid = ConditionId.wrap(bytes31(cidRaw));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        vm.prank(oracle);
        positions.binaryModule.reportResult(cid, result);

        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = 1; // YES
        indexSets[1] = 2; // NO

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(ctfRouter), true);

        vm.expectEmit(true, true, true, true, address(ctfRouter));
        emit CtfRouterPositionRedeemed(alice, PositionId.wrap(positionIds[0]), AMOUNT);
        vm.expectEmit(true, true, true, true, address(ctfRouter));
        emit CtfRouterPositionRedeemed(alice, PositionId.wrap(positionIds[1]), AMOUNT);
        ctfRouter.redeemPositions(address(0), bytes32(0), cidRaw, indexSets);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                          INITIALIZE
--------------------------------------------------------------*/

contract CtfRouterTest_initialize is CtfRouterTest {
    function test_initialize_setsOwner() public view {
        assertEq(ctfRouter.owner(), owner);
    }

    function test_revert_initialize_zeroOwner() public {
        address impl = address(new CtfRouter(address(positions.manager), address(collateral.token)));
        address proxy = LibClone.deployERC1967(impl);

        vm.expectRevert(InvalidOwner.selector);
        CtfRouter(proxy).initialize(address(0));
    }

    function test_revert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ctfRouter.initialize(alice);
    }

    function test_revert_initialize_onImplementation() public {
        address impl = address(new CtfRouter(address(positions.manager), address(collateral.token)));
        // `onlyProxy` reverts before `initializer` runs.
        vm.expectRevert(CallContextChecker.UnauthorizedCallContext.selector);
        CtfRouter(impl).initialize(alice);
    }
}

/*--------------------------------------------------------------
                       AUTHORIZE UPGRADE
--------------------------------------------------------------*/

contract CtfRouterTest_authorizeUpgrade is CtfRouterTest {
    function test_upgrade_ownerSucceeds() public {
        // Owner can upgrade to any impl, including one pinning different immutables.
        (Positions memory otherPositions, Collateral memory otherCollateral,) =
            PositionManagerSetup._deploy(owner, admin, creator);
        address newImpl = address(new CtfRouter(address(otherPositions.manager), address(otherCollateral.token)));
        vm.prank(owner);
        ctfRouter.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(new CtfRouter(address(positions.manager), address(collateral.token)));
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ctfRouter.upgradeToAndCall(newImpl, "");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { CcipBridge } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { MockCcipRouter } from "@polymarket-v2/src/bridge/test/mocks/MockCcipRouter.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId, EventId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { Positions, PositionManagerSetup } from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { BridgeRouter } from "@polymarket-v2/src/routers/BridgeRouter.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

contract RouterSnapshots_Test is TestHelper {
    uint256 constant DST_EID = 30110;
    uint256 constant SRC_EID = 30109;

    Collateral collateral;
    Positions positions;
    BridgeRouter router;
    CcipBridge bridge;
    MockCcipRouter ccipRouter;

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);

        ccipRouter = new MockCcipRouter(uint64(SRC_EID));
        address bridgeImpl = address(
            new CcipBridge(
                address(ccipRouter), address(positions.manager), address(collateral.token), block.chainid, SRC_EID
            )
        );
        address bridgeProxy = LibClone.deployERC1967(bridgeImpl);
        bridge = CcipBridge(bridgeProxy);
        bridge.initialize(owner, admin);

        vm.prank(owner);
        collateral.token.addMinter(address(bridge));

        vm.startPrank(admin);
        positions.binaryModule.addBridge(address(bridge));
        positions.negRiskModule.addBridge(address(bridge));
        vm.stopPrank();

        vm.startPrank(owner);
        bridge.setPeer(DST_EID, bytes32(uint256(uint160(address(bridge)))));
        bridge.setModuleSupported(address(positions.binaryModule), DST_EID, true);
        bridge.setModuleSupported(address(positions.negRiskModule), DST_EID, true);
        vm.stopPrank();

        vm.startPrank(admin);
        positions.binaryModule.addResolver(oracle);
        positions.negRiskModule.addResolver(oracle);
        vm.stopPrank();

        router = RouterSetup.deployBridgeRouter(address(positions.manager), address(bridge), owner);
    }
}

/*--------------------------------------------------------------
                       BINARY SNAPSHOTS
--------------------------------------------------------------*/

contract RouterSnapshots_Test_binary is RouterSnapshots_Test {
    function test_splitBinary() public {
        vm.prank(creator);
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);

        vm.startSnapshotGas("router_splitBinary");
        router.split(conditionId, 1_000_000_000);
        vm.stopSnapshotGas();

        vm.stopPrank();
    }

    function test_merge() public {
        vm.prank(creator);
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);

        positions.manager.setApprovalForAll(address(router), true);
        vm.startSnapshotGas("router_mergeBinary");
        router.merge(conditionId, 1_000_000_000);
        vm.stopSnapshotGas();

        vm.stopPrank();
    }

    function test_redeem() public {
        vm.prank(creator);
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);
        vm.stopPrank();

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);
        // conditionId already typed ConditionId; pass through

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        vm.startSnapshotGas("router_redeemBinary");
        router.redeem(conditionId, 0, 1_000_000_000);
        vm.stopSnapshotGas();
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 1_000_000_000);
    }
}

/*--------------------------------------------------------------
                     NEGRISK SNAPSHOTS
--------------------------------------------------------------*/

contract RouterSnapshots_Test_negRisk is RouterSnapshots_Test {
    function test_horizontalSplit_256() public {
        vm.prank(creator);
        EventId eventId = positions.negRiskModule.getEventId(256, "neg risk event");

        collateral.usdc.mint(alice, 1_000_000_000); // 1000 USDC

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);

        vm.startSnapshotGas("router_horizontalSplit_256");
        router.horizontalSplit(eventId, 1_000_000_000);
        vm.stopSnapshotGas();

        vm.stopPrank();
    }

    function test_horizontalMerge_256() public {
        vm.prank(creator);
        EventId eventId = positions.negRiskModule.getEventId(256, "neg risk event");

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);

        router.horizontalSplit(eventId, 1_000_000_000);

        positions.manager.setApprovalForAll(address(router), true);
        vm.startSnapshotGas("router_horizontalMerge_256");
        router.horizontalMerge(eventId, 1_000_000_000);
        vm.stopSnapshotGas();

        vm.stopPrank();
    }

    function test_convert() public {
        vm.prank(creator);
        EventId eventId = positions.negRiskModule.getEventId(256, "neg risk event");

        ConditionId conditionId = EventIdLib.computeConditionId(eventId, 0);

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);

        positions.manager.setApprovalForAll(address(router), true);

        vm.startSnapshotGas("router_convert_256");
        router.convert(eventId, 0, 1_000_000_000);
        vm.stopSnapshotGas();
    }
}

/*--------------------------------------------------------------
                      BRIDGE SNAPSHOTS
--------------------------------------------------------------*/

contract RouterSnapshots_Test_bridge is RouterSnapshots_Test {
    function test_bridgePositions() public {
        vm.prank(creator);
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        collateral.usdc.mint(alice, 1_000_000_000);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = ConditionIdLib.computePositionId(conditionId, 0);
        positionIds[1] = ConditionIdLib.computePositionId(conditionId, 1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000_000;
        amounts[1] = 1_000_000_000;

        positions.manager.setApprovalForAll(address(router), true);

        vm.startSnapshotGas("router_bridgePositions");
        router.bridgePositions{ value: 0.01 ether }(DST_EID, positionIds, amounts, "");
        vm.stopSnapshotGas();

        vm.stopPrank();
    }

    function test_bridgeCollateral() public {
        collateral.usdc.mint(alice, 1_000_000_000);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);

        vm.startSnapshotGas("router_bridgeCollateral");
        router.bridgeCollateral{ value: 0.01 ether }(DST_EID, 1_000_000_000, "");
        vm.stopSnapshotGas();

        vm.stopPrank();
    }

    function test_bridgePositionsTo() public {
        vm.prank(creator);
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        collateral.usdc.mint(alice, 1_000_000_000);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = ConditionIdLib.computePositionId(conditionId, 0);
        positionIds[1] = ConditionIdLib.computePositionId(conditionId, 1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000_000;
        amounts[1] = 1_000_000_000;

        positions.manager.setApprovalForAll(address(router), true);

        bytes32 recipient = bytes32(uint256(uint160(brian)));
        vm.startSnapshotGas("router_bridgePositionsTo");
        router.bridgePositionsTo{ value: 0.01 ether }(DST_EID, positionIds, amounts, recipient, "");
        vm.stopSnapshotGas();

        vm.stopPrank();
    }

    function test_bridgeCollateralTo() public {
        collateral.usdc.mint(alice, 1_000_000_000);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);

        bytes32 recipient = bytes32(uint256(uint160(brian)));
        vm.startSnapshotGas("router_bridgeCollateralTo");
        router.bridgeCollateralTo{ value: 0.01 ether }(DST_EID, 1_000_000_000, recipient, "");
        vm.stopSnapshotGas();

        vm.stopPrank();
    }
}

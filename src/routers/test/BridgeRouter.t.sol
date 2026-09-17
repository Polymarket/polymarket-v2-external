// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { CcipBridge } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { MockCcipRouter } from "@polymarket-v2/src/bridge/test/mocks/MockCcipRouter.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId, ConditionIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { Positions, PositionManagerSetup } from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { BridgeRouter } from "@polymarket-v2/src/routers/BridgeRouter.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

contract BridgeRouterTest is TestHelper {
    uint256 constant DST_EID = 30110;
    uint256 constant SRC_EID = 30109;
    uint256 constant AMOUNT = 1_000_000_000;

    event BridgePositionsInitiated(
        address indexed initiator,
        uint256 indexed dstChain,
        bytes32 indexed recipient,
        PositionId[] positionIds,
        uint256[] amounts
    );
    event BridgeCollateralInitiated(
        address indexed initiator, uint256 indexed dstChain, bytes32 indexed recipient, uint256 amount
    );

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

        router = RouterSetup.deployBridgeRouter(address(positions.manager), address(bridge), owner);
    }

    function _seedAlicePositions() internal returns (PositionId[] memory positionIds, uint256[] memory amounts) {
        vm.prank(creator);
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        collateral.usdc.mint(alice, AMOUNT);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), AMOUNT);
        collateral.onramp.wrap(address(collateral.usdc), alice, AMOUNT);
        collateral.token.approve(address(router), AMOUNT);
        router.split(conditionId, AMOUNT);

        positionIds = new PositionId[](2);
        positionIds[0] = ConditionIdLib.computePositionId(conditionId, 0);
        positionIds[1] = ConditionIdLib.computePositionId(conditionId, 1);
        amounts = new uint256[](2);
        amounts[0] = AMOUNT;
        amounts[1] = AMOUNT;

        positions.manager.setApprovalForAll(address(router), true);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                  BRIDGE POSITIONS INITIATED EVENT
--------------------------------------------------------------*/

contract BridgeRouterTest_bridgePositions is BridgeRouterTest {
    function test_emits_initiator_event() public {
        (PositionId[] memory positionIds, uint256[] memory amounts) = _seedAlicePositions();

        vm.expectEmit(true, true, true, true, address(router));
        emit BridgePositionsInitiated(alice, DST_EID, bytes32(uint256(uint160(alice))), positionIds, amounts);

        vm.prank(alice);
        router.bridgePositions{ value: 0.01 ether }(DST_EID, positionIds, amounts, "");
    }

    function test_bridgePositionsTo_emits_explicit_recipient() public {
        (PositionId[] memory positionIds, uint256[] memory amounts) = _seedAlicePositions();

        bytes32 recipient = bytes32(uint256(uint160(brian)));

        vm.expectEmit(true, true, true, true, address(router));
        emit BridgePositionsInitiated(alice, DST_EID, recipient, positionIds, amounts);

        vm.prank(alice);
        router.bridgePositionsTo{ value: 0.01 ether }(DST_EID, positionIds, amounts, recipient, "");
    }
}

/*--------------------------------------------------------------
                  BRIDGE COLLATERAL INITIATED EVENT
--------------------------------------------------------------*/

contract BridgeRouterTest_bridgeCollateral is BridgeRouterTest {
    function _seedAliceCollateral() internal {
        collateral.usdc.mint(alice, AMOUNT);
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), AMOUNT);
        collateral.onramp.wrap(address(collateral.usdc), alice, AMOUNT);
        collateral.token.approve(address(router), AMOUNT);
        vm.stopPrank();
    }

    function test_emits_initiator_event() public {
        _seedAliceCollateral();

        vm.expectEmit(true, true, true, true, address(router));
        emit BridgeCollateralInitiated(alice, DST_EID, bytes32(uint256(uint160(alice))), AMOUNT);

        vm.prank(alice);
        router.bridgeCollateral{ value: 0.01 ether }(DST_EID, AMOUNT, "");
    }

    function test_bridgeCollateralTo_emits_explicit_recipient() public {
        _seedAliceCollateral();

        bytes32 recipient = bytes32(uint256(uint160(brian)));

        vm.expectEmit(true, true, true, true, address(router));
        emit BridgeCollateralInitiated(alice, DST_EID, recipient, AMOUNT);

        vm.prank(alice);
        router.bridgeCollateralTo{ value: 0.01 ether }(DST_EID, AMOUNT, recipient, "");
    }
}

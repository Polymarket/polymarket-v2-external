// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BridgeBase } from "@polymarket-v2/src/bridge/abstract/BridgeBase.sol";
import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";
import { BridgeTestBase } from "./BridgeTestBase.sol";

// Standard modules
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";

// Infrastructure
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { BridgeRouter } from "@polymarket-v2/src/routers/BridgeRouter.sol";

import { ConditionId, EventId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title BridgeStandardTestBase
/// @notice Abstract base containing all shared standard bridging test logic.
/// @dev Concrete implementations deploy transport infrastructure, populate state,
///      and override _deliverFromHub/_deliverFromSpokeA/_deliverFromSpokeB.
abstract contract BridgeStandardTestBase is BridgeTestBase {
    /*--------------------------------------------------------------
                         SHARED STATE
    --------------------------------------------------------------*/

    IBridge public hubBridge;
    IBridge public spokeABridge;
    IBridge public spokeBBridge;

    PositionManager public hubPositionManager;
    PositionManager public spokeAPositionManager;
    PositionManager public spokeBPositionManager;

    BinaryModule public hubBinaryModule;
    NegRiskModule public hubNegRiskModule;
    BinaryModule public spokeABinaryModule;
    NegRiskModule public spokeANegRiskModule;
    BinaryModule public spokeBBinaryModule;
    NegRiskModule public spokeBNegRiskModule;

    Collateral public hubCollateral;

    BridgeRouter public hubBridgeRouter;

    uint256 public HUB_DST;
    uint256 public SPOKE_A_DST;
    uint256 public SPOKE_B_DST;

    /*--------------------------------------------------------------
                       VIRTUAL FUNCTIONS
    --------------------------------------------------------------*/

    function _deliverFromHub() internal virtual;
    function _deliverFromSpokeA() internal virtual;
    function _deliverFromSpokeB() internal virtual;

    /*--------------------------------------------------------------
                     BINARY POSITION BRIDGING TESTS
    --------------------------------------------------------------*/

    function test_bridge_binary_positions_hubToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup condition and positions on hub
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition(bytes("test-binary-positions-hub-spoke"), amount);

        // Bridge both YES and NO positions
        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(positionId0);
        positionIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");

        // Verify burned on hub
        assertEq(hubPositionManager.balanceOf(user, positionId0), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionId1), 0, "NO not burned on hub");

        _deliverFromHub();

        // Verify minted on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount, "YES not minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), amount, "NO not minted on spoke");
    }

    function test_bridge_binary_positions_spokeToHub() public {
        uint256 amount = 100_000_000;

        // Setup and bridge to spoke first
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition(bytes("test-binary-positions-spoke-hub"), amount);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(positionId0);
        positionIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");

        assertEq(hubPositionManager.balanceOf(user, positionId0), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionId1), 0, "NO not burned on hub");

        _deliverFromHub();

        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount, "YES not minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), amount, "NO not minted on spoke");

        // Now bridge back to hub
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), positionIds, amounts);

        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(HUB_DST, positionIds, amounts, _toBytes32(recipient), "");

        // Verify burned on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), 0, "YES not burned on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), 0, "NO not burned on spoke");

        _deliverFromSpokeA();

        // Verify minted on hub (to recipient)
        assertEq(hubPositionManager.balanceOf(recipient, positionId0), amount, "YES not minted on hub");
        assertEq(hubPositionManager.balanceOf(recipient, positionId1), amount, "NO not minted on hub");
    }

    function test_bridge_binary_positions_spokeToSpoke() public {
        uint256 amount = 100_000_000;

        // First: hub -> spoke A
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition(bytes("test-binary-positions-spoke-spoke"), amount);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(positionId0);
        positionIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");

        assertEq(hubPositionManager.balanceOf(user, positionId0), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionId1), 0, "NO not burned on hub");

        _deliverFromHub();

        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount, "YES not minted on spoke A");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), amount, "NO not minted on spoke A");

        // Second: spoke A -> spoke B
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), positionIds, amounts);

        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(SPOKE_B_DST, positionIds, amounts, _toBytes32(recipient), "");

        // Verify burned on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), 0, "YES not burned on spoke A");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), 0, "NO not burned on spoke A");

        _deliverFromSpokeA();

        // Verify minted on spoke B (to recipient)
        assertEq(spokeBPositionManager.balanceOf(recipient, positionId0), amount, "YES not minted on spoke B");
        assertEq(spokeBPositionManager.balanceOf(recipient, positionId1), amount, "NO not minted on spoke B");
    }

    function test_bridge_binary_roundTrip() public {
        uint256 amount = 100_000_000;

        // Setup condition and positions on hub
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition(bytes("test-binary-roundtrip"), amount);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // Hub -> Spoke A
        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");
        assertEq(hubPositionManager.balanceOf(user, positionId0), 0, "Not burned on hub");
        _deliverFromHub();
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount, "Not minted on spoke A");

        // Spoke A -> Spoke B
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), positionIds, amounts);
        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(SPOKE_B_DST, positionIds, amounts, _toBytes32(user), "");
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), 0, "Not burned on spoke A");
        _deliverFromSpokeA();
        assertEq(spokeBPositionManager.balanceOf(user, positionId0), amount, "Not minted on spoke B");

        // Spoke B -> Hub
        vm.prank(user);
        spokeBPositionManager.unsafeBatchTransferFrom(user, address(spokeBBridge), positionIds, amounts);
        vm.prank(user);
        spokeBBridge.bridgePositions{ value: 0.01 ether }(HUB_DST, positionIds, amounts, _toBytes32(user), "");
        assertEq(spokeBPositionManager.balanceOf(user, positionId0), 0, "Not burned on spoke B");
        _deliverFromSpokeB();

        // Verify back on hub
        assertEq(hubPositionManager.balanceOf(user, positionId0), amount, "Round trip failed - wrong balance");
    }

    function test_bridge_binary_positions_partialAmount() public {
        uint256 totalAmount = 100_000_000;
        uint256 bridgeAmount = 40_000_000;
        uint256 remainingAmount = totalAmount - bridgeAmount;

        // Setup condition and positions on hub
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition(bytes("test-binary-positions-partial"), totalAmount);

        // Verify initial balances
        assertEq(hubPositionManager.balanceOf(user, positionId0), totalAmount);
        assertEq(hubPositionManager.balanceOf(user, positionId1), totalAmount);

        // Bridge only partial amount
        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(positionId0);
        positionIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = bridgeAmount;
        amounts[1] = bridgeAmount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");

        // Verify partial burn on hub - remaining balance stays
        assertEq(hubPositionManager.balanceOf(user, positionId0), remainingAmount, "Wrong YES remaining on hub");
        assertEq(hubPositionManager.balanceOf(user, positionId1), remainingAmount, "Wrong NO remaining on hub");

        _deliverFromHub();

        // Verify partial mint on spoke
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), bridgeAmount, "Wrong YES minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), bridgeAmount, "Wrong NO minted on spoke");
    }

    function test_bridge_binary_positions_idempotentConditionPrep() public {
        uint256 amount = 100_000_000;

        // Setup condition and positions on hub
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition(bytes("test-binary-idempotent"), amount);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(positionId0);
        positionIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount / 2;
        amounts[1] = amount / 2;

        // First bridge - prepares condition on spoke
        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount / 2);

        // Second bridge - should still work
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(recipient), "");
        _deliverFromHub();

        // Verify both bridges succeeded
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount / 2);
        assertEq(spokeAPositionManager.balanceOf(recipient, positionId0), amount / 2);
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), amount / 2);
        assertEq(spokeAPositionManager.balanceOf(recipient, positionId1), amount / 2);
    }

    /*--------------------------------------------------------------
                    NEGRISK POSITION BRIDGING TESTS
    --------------------------------------------------------------*/

    function test_bridge_negRisk_positions_hubToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-positions-hub-spoke"), 2, amount);

        // Bridge positions (YES and NO for first condition)
        vm.chainId(HUB_CHAIN_ID);

        PositionId[] memory bridgePositionIds = new PositionId[](2);
        bridgePositionIds[0] = PositionId.wrap(positionIds[0]); // YES
        bridgePositionIds[1] = PositionId.wrap(positionIds[1]); // NO
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(user), "");

        // Verify burned on hub
        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), 0, "NO not burned on hub");

        _deliverFromHub();

        // Verify minted on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), amount, "YES not minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), amount, "NO not minted on spoke");
    }

    function test_bridge_negRisk_positions_spokeToHub() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-positions-spoke-hub"), 2, amount);

        // Bridge positions to spoke
        vm.chainId(HUB_CHAIN_ID);

        PositionId[] memory bridgePositionIds = new PositionId[](2);
        bridgePositionIds[0] = PositionId.wrap(positionIds[0]);
        bridgePositionIds[1] = PositionId.wrap(positionIds[1]);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(user), "");

        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), 0, "NO not burned on hub");

        _deliverFromHub();

        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), amount, "YES not minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), amount, "NO not minted on spoke");

        // Now bridge back to hub
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), bridgePositionIds, amounts);

        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(
            HUB_DST, bridgePositionIds, amounts, _toBytes32(recipient), ""
        );

        // Verify burned on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), 0, "YES not burned on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), 0, "NO not burned on spoke");

        _deliverFromSpokeA();

        // Verify minted on hub (to recipient)
        assertEq(hubPositionManager.balanceOf(recipient, positionIds[0]), amount, "YES not minted on hub");
        assertEq(hubPositionManager.balanceOf(recipient, positionIds[1]), amount, "NO not minted on hub");
    }

    function test_bridge_negRisk_positions_spokeToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-positions-spoke-spoke"), 2, amount);

        // Bridge positions HUB -> SPOKE_A
        vm.chainId(HUB_CHAIN_ID);

        PositionId[] memory bridgePositionIds = new PositionId[](2);
        bridgePositionIds[0] = PositionId.wrap(positionIds[0]); // YES
        bridgePositionIds[1] = PositionId.wrap(positionIds[1]); // NO
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(user), "");

        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), 0, "NO not burned on hub");

        _deliverFromHub();

        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), amount, "YES not minted on spoke A");
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), amount, "NO not minted on spoke A");

        // Now bridge SPOKE_A -> SPOKE_B
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), bridgePositionIds, amounts);

        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(
            SPOKE_B_DST, bridgePositionIds, amounts, _toBytes32(recipient), ""
        );

        // Verify burned on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), 0, "YES not burned on spoke A");
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), 0, "NO not burned on spoke A");

        _deliverFromSpokeA();

        // Verify minted on spoke B (to recipient)
        assertEq(spokeBPositionManager.balanceOf(recipient, positionIds[0]), amount, "YES not minted on spoke B");
        assertEq(spokeBPositionManager.balanceOf(recipient, positionIds[1]), amount, "NO not minted on spoke B");
    }

    function test_bridge_negRisk_roundTrip() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory allPositionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-roundtrip"), 2, amount);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(allPositionIds[0]); // YES for first condition
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // Hub -> Spoke A
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");
        assertEq(hubPositionManager.balanceOf(user, PositionId.unwrap(positionIds[0])), 0, "Not burned on hub");
        _deliverFromHub();
        assertEq(
            spokeAPositionManager.balanceOf(user, PositionId.unwrap(positionIds[0])), amount, "Not minted on spoke A"
        );

        // Spoke A -> Spoke B
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), positionIds, amounts);
        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(SPOKE_B_DST, positionIds, amounts, _toBytes32(user), "");
        assertEq(spokeAPositionManager.balanceOf(user, PositionId.unwrap(positionIds[0])), 0, "Not burned on spoke A");
        _deliverFromSpokeA();
        assertEq(
            spokeBPositionManager.balanceOf(user, PositionId.unwrap(positionIds[0])), amount, "Not minted on spoke B"
        );

        // Spoke B -> Hub
        vm.chainId(SPOKE_B_CHAIN_ID);
        vm.prank(user);
        spokeBPositionManager.unsafeBatchTransferFrom(user, address(spokeBBridge), positionIds, amounts);
        vm.prank(user);
        spokeBBridge.bridgePositions{ value: 0.01 ether }(HUB_DST, positionIds, amounts, _toBytes32(user), "");
        assertEq(spokeBPositionManager.balanceOf(user, PositionId.unwrap(positionIds[0])), 0, "Not burned on spoke B");
        _deliverFromSpokeB();

        // Verify back on hub
        assertEq(
            hubPositionManager.balanceOf(user, PositionId.unwrap(positionIds[0])),
            amount,
            "Round trip failed - wrong balance"
        );
    }

    function test_bridge_negRisk_positions_partialAmount() public {
        uint256 totalAmount = 100_000_000;
        uint256 bridgeAmount = 40_000_000;
        uint256 remainingAmount = totalAmount - bridgeAmount;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-positions-partial"), 2, totalAmount);

        // Verify initial balances
        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), totalAmount);
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), totalAmount);

        // Bridge partial amount of positions
        vm.chainId(HUB_CHAIN_ID);

        PositionId[] memory bridgePositionIds = new PositionId[](2);
        bridgePositionIds[0] = PositionId.wrap(positionIds[0]);
        bridgePositionIds[1] = PositionId.wrap(positionIds[1]);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = bridgeAmount;
        amounts[1] = bridgeAmount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(user), "");

        // Verify partial burn on hub - remaining balance stays
        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), remainingAmount, "Wrong YES remaining on hub");
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), remainingAmount, "Wrong NO remaining on hub");

        _deliverFromHub();

        // Verify partial mint on spoke
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), bridgeAmount, "Wrong YES minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), bridgeAmount, "Wrong NO minted on spoke");
    }

    function test_bridge_negRisk_positions_idempotentConditionPrep() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (, bytes32[] memory conditionIds, uint256[] memory positionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-idempotent"), 2, amount);

        PositionId[] memory bridgePositionIds = new PositionId[](2);
        bridgePositionIds[0] = PositionId.wrap(positionIds[0]); // YES
        bridgePositionIds[1] = PositionId.wrap(positionIds[1]); // NO
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount / 2;
        amounts[1] = amount / 2;

        // First bridge - prepares condition on spoke (without event)
        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), amount / 2);

        // Second bridge - should still work
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(
            SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(recipient), ""
        );
        _deliverFromHub();

        // Verify both bridges succeeded
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), amount / 2);
        assertEq(spokeAPositionManager.balanceOf(recipient, positionIds[0]), amount / 2);
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), amount / 2);
        assertEq(spokeAPositionManager.balanceOf(recipient, positionIds[1]), amount / 2);
    }

    /*--------------------------------------------------------------
                         RESULT BRIDGING TESTS
    --------------------------------------------------------------*/

    function test_bridge_binary_resultBridge_hubToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup binary condition on hub
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition(bytes("test-binary-hub-spoke"), amount);

        // Bridge positions HUB -> SPOKE_A
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        // Resolve on hub
        vm.chainId(HUB_CHAIN_ID);
        _resolveBinaryOnHub(conditionId);

        // Bridge result to spoke
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionId), "");
        _deliverFromHub();

        // Verify result on spoke
        assertTrue(spokeABinaryModule.hasResult(ConditionIdLib.from(conditionId)), "Result not bridged");

        uint256[] memory spokeResult = spokeABinaryModule.getResult(ConditionIdLib.from(conditionId));
        assertEq(spokeResult[0], 1_000_000, "Wrong YES payout");
        assertEq(spokeResult[1], 0, "Wrong NO payout");
    }

    /// @dev A spoke holding an imported result may not re-export it: results leave their
    ///      resolution chain and stop there, so spoke B must import from the hub instead.
    function test_revert_bridge_binary_resultBridge_spokeToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup binary condition on hub
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition(bytes("test-binary-spoke-spoke"), amount);

        // Bridge positions HUB -> SPOKE_A
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        // Bridge positions SPOKE_A -> SPOKE_B (so condition exists on spoke B)
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), positionIds, amounts);

        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(SPOKE_B_DST, positionIds, amounts, _toBytes32(user), "");
        _deliverFromSpokeA();

        // Resolve on hub
        vm.chainId(HUB_CHAIN_ID);
        _resolveBinaryOnHub(conditionId);

        // Bridge result HUB -> SPOKE_A
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionId), "");
        _deliverFromHub();

        // Verify result on spoke A
        assertTrue(spokeABinaryModule.hasResult(ConditionIdLib.from(conditionId)), "Result not on spoke A");

        // Re-exporting SPOKE_A -> SPOKE_B is refused at the source
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.expectRevert(BridgeBase.InvalidResolutionChainId.selector);
        spokeABridge.bridgeResult{ value: 0.01 ether }(SPOKE_B_DST, ConditionIdLib.from(conditionId), "");

        assertFalse(spokeBBinaryModule.hasResult(ConditionIdLib.from(conditionId)), "Result reached spoke B");
    }

    function test_bridge_negRisk_resultBridge_hubToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup NegRisk event on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-hub-spoke"), 2, amount);

        bytes32 conditionId = conditionIds[0];
        uint256 positionId0 = positionIds[0];

        // Bridge positions HUB -> SPOKE_A
        vm.chainId(HUB_CHAIN_ID);

        PositionId[] memory bridgePositionIds = new PositionId[](1);
        bridgePositionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        // Resolve on hub
        vm.chainId(HUB_CHAIN_ID);
        _resolveNegRiskOnHub(conditionId);

        // Bridge result to spoke
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionId), "");
        _deliverFromHub();

        // Verify result on spoke
        assertTrue(spokeANegRiskModule.hasResult(ConditionIdLib.from(conditionId)), "Result not bridged");

        uint256[] memory spokeResult = spokeANegRiskModule.getResult(ConditionIdLib.from(conditionId));
        assertEq(spokeResult[0], 1_000_000, "Wrong YES payout");
        assertEq(spokeResult[1], 0, "Wrong NO payout");
    }

    /// @dev See `test_revert_bridge_binary_resultBridge_spokeToSpoke`.
    function test_revert_bridge_negRisk_resultBridge_spokeToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup NegRisk event on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds) =
            _setupNegRiskEvent(bytes("test-negrisk-spoke-spoke"), 2, amount);

        bytes32 conditionId = conditionIds[0];
        uint256 positionId0 = positionIds[0];

        // Bridge positions HUB -> SPOKE_A
        vm.chainId(HUB_CHAIN_ID);

        PositionId[] memory bridgePositionIds = new PositionId[](1);
        bridgePositionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), bridgePositionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        // Bridge positions SPOKE_A -> SPOKE_B
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), bridgePositionIds, amounts);

        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(SPOKE_B_DST, bridgePositionIds, amounts, _toBytes32(user), "");
        _deliverFromSpokeA();

        // Resolve on hub
        vm.chainId(HUB_CHAIN_ID);
        _resolveNegRiskOnHub(conditionId);

        // Bridge result HUB -> SPOKE_A
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionId), "");
        _deliverFromHub();

        // Verify result on spoke A
        assertTrue(spokeANegRiskModule.hasResult(ConditionIdLib.from(conditionId)), "Result not on spoke A");

        // Re-exporting SPOKE_A -> SPOKE_B is refused at the source
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.expectRevert(BridgeBase.InvalidResolutionChainId.selector);
        spokeABridge.bridgeResult{ value: 0.01 ether }(SPOKE_B_DST, ConditionIdLib.from(conditionId), "");

        assertFalse(spokeBNegRiskModule.hasResult(ConditionIdLib.from(conditionId)), "Result reached spoke B");
    }

    /*--------------------------------------------------------------
                      DERIVATION CONSISTENCY TESTS
    --------------------------------------------------------------*/

    function test_bridge_binaryPositionId_matchesAcrossChains(bytes32 conditionId, uint256 outcomeIndex) public {
        outcomeIndex = bound(outcomeIndex, 0, 1);
        // Sanitize fuzz input to a canonical condition ID (outcome byte zero).
        conditionId = bytes32(uint256(conditionId) & ~uint256(0xFF));

        vm.chainId(HUB_CHAIN_ID);
        uint256 hubId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), outcomeIndex));

        vm.chainId(SPOKE_A_CHAIN_ID);
        uint256 spokeAId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), outcomeIndex));

        vm.chainId(SPOKE_B_CHAIN_ID);
        uint256 spokeBId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), outcomeIndex));

        assertEq(hubId, spokeAId, "Hub != Spoke A");
        assertEq(hubId, spokeBId, "Hub != Spoke B");
    }

    function test_bridge_negRiskDerivation_matchesAcrossChains(
        bytes32 eventId,
        uint8 conditionIndex,
        uint256 outcomeIndex
    ) public {
        outcomeIndex = bound(outcomeIndex, 0, 1);

        vm.chainId(HUB_CHAIN_ID);
        bytes32 hubConditionId =
            ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), conditionIndex));
        uint256 hubPositionId = PositionId.unwrap(
            ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(hubConditionId)), outcomeIndex)
        );

        vm.chainId(SPOKE_A_CHAIN_ID);
        bytes32 spokeAConditionId =
            ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), conditionIndex));
        uint256 spokeAPositionId = PositionId.unwrap(
            ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(spokeAConditionId)), outcomeIndex)
        );

        vm.chainId(SPOKE_B_CHAIN_ID);
        bytes32 spokeBConditionId =
            ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), conditionIndex));
        uint256 spokeBPositionId = PositionId.unwrap(
            ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(spokeBConditionId)), outcomeIndex)
        );

        assertEq(hubConditionId, spokeAConditionId, "ConditionId: Hub != Spoke A");
        assertEq(hubConditionId, spokeBConditionId, "ConditionId: Hub != Spoke B");
        assertEq(hubPositionId, spokeAPositionId, "PositionId: Hub != Spoke A");
        assertEq(hubPositionId, spokeBPositionId, "PositionId: Hub != Spoke B");
    }

    function test_bridge_moduleId_matches() public view {
        assertEq(hubBinaryModule.moduleId(), spokeABinaryModule.moduleId(), "Binary moduleId mismatch");
        assertEq(hubNegRiskModule.moduleId(), spokeANegRiskModule.moduleId(), "NegRisk moduleId mismatch");
        assertEq(hubBinaryModule.moduleId(), ModuleIds.BINARY, "Wrong binary moduleId");
        assertEq(hubNegRiskModule.moduleId(), ModuleIds.NEGRISK, "Wrong negRisk moduleId");
    }

    /*--------------------------------------------------------------
                          ROUTER BRIDGE TESTS
    --------------------------------------------------------------*/

    function test_bridge_router_bridgePositions_binary() public {
        uint256 amount = 100_000_000;

        // Setup condition and positions on hub
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition(bytes("test-router-bridge-positions-binary"), amount);

        // Approve bridge router
        vm.prank(user);
        hubPositionManager.setApprovalForAll(address(hubBridgeRouter), true);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(positionId0);
        positionIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        // Bridge via bridge router
        vm.prank(user);
        hubBridgeRouter.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, "");

        // Verify burned on hub
        assertEq(hubPositionManager.balanceOf(user, positionId0), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionId1), 0, "NO not burned on hub");

        _deliverFromHub();

        // Verify minted on spoke
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount, "YES not minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), amount, "NO not minted on spoke");
    }

    function test_bridge_router_bridgePositions_negRisk() public {
        uint256 amount = 100_000_000;

        // Setup NegRisk event and positions on hub
        (,, uint256[] memory positionIds) = _setupNegRiskEvent(bytes("test-router-bridge-positions-negrisk"), 2, amount);

        // Approve bridge router
        vm.prank(user);
        hubPositionManager.setApprovalForAll(address(hubBridgeRouter), true);

        // Bridge YES+NO of first condition
        PositionId[] memory bridgePositionIds = new PositionId[](2);
        bridgePositionIds[0] = PositionId.wrap(positionIds[0]);
        bridgePositionIds[1] = PositionId.wrap(positionIds[1]);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubBridgeRouter.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, bridgePositionIds, amounts, "");

        // Verify burned on hub
        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), 0, "YES not burned on hub");
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), 0, "NO not burned on hub");

        _deliverFromHub();

        // Verify minted on spoke
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), amount, "YES not minted on spoke");
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[1]), amount, "NO not minted on spoke");
    }

    function test_bridge_router_bridgeCollateral() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);

        // Mint collateral to user
        hubCollateral.usdc.mint(user, amount);
        vm.startPrank(user);
        hubCollateral.usdc.approve(address(hubCollateral.onramp), amount);
        hubCollateral.onramp.wrap(address(hubCollateral.usdc), user, amount);

        // Approve bridge router and bridge
        hubCollateral.token.approve(address(hubBridgeRouter), amount);
        hubBridgeRouter.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, "");
        vm.stopPrank();

        // Verify burned on hub
        assertEq(hubCollateral.token.balanceOf(user), 0, "Collateral not burned on hub");

        _deliverFromHub();

        // Verify minted on spoke
        assertEq(_spokeACollateralBalance(user), amount, "Collateral not minted on spoke");
    }

    /*--------------------------------------------------------------
                            VIRTUAL HELPERS
    --------------------------------------------------------------*/

    /// @dev Returns spoke A collateral token balance. Override if needed.
    function _spokeACollateralBalance(address _account) internal view virtual returns (uint256);

    /*--------------------------------------------------------------
                            HELPER FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Derive a binary condition ID and mint positions to user via Router.split()
    function _setupBinaryCondition(bytes memory conditionData, uint256 amount)
        internal
        returns (bytes32 conditionId, uint256 positionId0, uint256 positionId1)
    {
        vm.chainId(HUB_CHAIN_ID);

        // Derive condition ID (no preparation step needed)
        ConditionId typedConditionId = hubBinaryModule.getConditionId(conditionData);
        conditionId = bytes32(ConditionId.unwrap(typedConditionId));

        // Get position IDs
        positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(typedConditionId, 0));
        positionId1 = PositionId.unwrap(ConditionIdLib.computePositionId(typedConditionId, 1));

        // Mint USDC to user and wrap to collateral
        hubCollateral.usdc.mint(user, amount);

        vm.startPrank(user);
        hubCollateral.usdc.approve(address(hubCollateral.onramp), amount);
        hubCollateral.onramp.wrap(address(hubCollateral.usdc), user, amount);

        // Split collateral into YES/NO positions
        hubCollateral.token.approve(address(hubBridgeRouter), amount);
        hubBridgeRouter.split(typedConditionId, amount);
        vm.stopPrank();

        // Verify
        assertEq(hubPositionManager.balanceOf(user, positionId0), amount, "YES mint failed");
        assertEq(hubPositionManager.balanceOf(user, positionId1), amount, "NO mint failed");
    }

    /// @notice Prepare a NegRisk event on hub and mint positions to user via Router.split()
    /// @dev Always uses at least 2 conditions to avoid <2 question errors on spoke modules
    function _setupNegRiskEvent(bytes memory eventData, uint256 conditionCount, uint256 amount)
        internal
        returns (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds)
    {
        vm.chainId(HUB_CHAIN_ID);

        // Ensure at least 2 conditions for spoke module compatibility
        require(conditionCount >= 2, "NegRisk events require at least 2 conditions");

        EventId typedEventId = hubNegRiskModule.getEventId(conditionCount, eventData);
        eventId = bytes32(EventId.unwrap(typedEventId));

        // Get condition and position IDs
        conditionIds = new bytes32[](conditionCount);
        positionIds = new uint256[](conditionCount * 2);
        for (uint256 i = 0; i < conditionCount; i++) {
            ConditionId typedConditionId = EventIdLib.computeConditionId(typedEventId, i);
            conditionIds[i] = bytes32(ConditionId.unwrap(typedConditionId));
            positionIds[i * 2] = PositionId.unwrap(ConditionIdLib.computePositionId(typedConditionId, 0)); // YES
            positionIds[i * 2 + 1] = PositionId.unwrap(ConditionIdLib.computePositionId(typedConditionId, 1)); // NO
        }

        // Mint USDC to user and wrap to collateral
        hubCollateral.usdc.mint(user, amount);

        vm.startPrank(user);
        hubCollateral.usdc.approve(address(hubCollateral.onramp), amount);
        hubCollateral.onramp.wrap(address(hubCollateral.usdc), user, amount);

        // Split collateral into YES/NO positions for first condition
        hubCollateral.token.approve(address(hubBridgeRouter), amount);
        hubBridgeRouter.split(ConditionIdLib.from(conditionIds[0]), amount);
        vm.stopPrank();

        // Verify
        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), amount, "NegRisk YES mint failed");
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), amount, "NegRisk NO mint failed");
    }

    /// @notice Resolve binary condition on hub (YES wins)
    function _resolveBinaryOnHub(bytes32 conditionId) internal {
        vm.chainId(HUB_CHAIN_ID);

        // Grant resolver role to oracle
        vm.prank(admin);
        hubBinaryModule.addResolver(oracle);

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000; // YES wins
        result[1] = 0;

        vm.prank(oracle);
        hubBinaryModule.reportResult(ConditionIdLib.from(conditionId), result);
    }

    /// @notice Resolve NegRisk condition on hub (YES wins)
    function _resolveNegRiskOnHub(bytes32 conditionId) internal {
        vm.chainId(HUB_CHAIN_ID);

        // Grant resolver role to oracle
        vm.prank(admin);
        hubNegRiskModule.addResolver(oracle);

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000; // YES wins
        result[1] = 0;

        vm.prank(oracle);
        hubNegRiskModule.reportResult(ConditionIdLib.from(conditionId), result);
    }
}

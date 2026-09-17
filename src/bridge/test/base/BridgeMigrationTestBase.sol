// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BridgeBase } from "@polymarket-v2/src/bridge/abstract/BridgeBase.sol";
import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";
import { BridgeTestBase } from "./BridgeTestBase.sol";

// Modules & infrastructure
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { NegRiskMigrationErrors } from "@polymarket-v2/src/modules/migration/NegRiskMigrationMixin.sol";
import { ConditionId, EventId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";

// Legacy infrastructure
import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { INegRiskAdapter } from "@polymarket-v2/src/legacy/interfaces/INegRiskAdapter.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";

/// @title BridgeMigrationTestBase
/// @notice Abstract base containing all shared migration bridging test logic.
/// @dev Concrete implementations deploy transport infrastructure, populate state,
///      and override _deliverFromHub/_deliverFromSpokeA/_deliverFromSpokeB.
abstract contract BridgeMigrationTestBase is BridgeTestBase {
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
    BinaryModule public spokeABinaryModule;
    BinaryModule public spokeBBinaryModule;

    NegRiskModule public hubNegRiskModule;
    NegRiskModule public spokeANegRiskModule;
    NegRiskModule public spokeBNegRiskModule;

    uint256 public HUB_DST;
    uint256 public SPOKE_A_DST;
    uint256 public SPOKE_B_DST;

    // Hub legacy infrastructure
    IConditionalTokens public hubCT;
    INegRiskAdapter public hubNRA;
    address public hubUsdce;
    address public hubWrappedCollateral;
    Collateral public hubCollateral;

    /*--------------------------------------------------------------
                       VIRTUAL FUNCTIONS
    --------------------------------------------------------------*/

    function _deliverFromHub() internal virtual;
    function _deliverFromSpokeA() internal virtual;
    function _deliverFromSpokeB() internal virtual;

    /*--------------------------------------------------------------
                BINARY MIGRATION POSITION BRIDGING TESTS
    --------------------------------------------------------------*/

    function test_bridge_migration_binaryPositions_hubToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup and migrate on hub
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition("test-question", amount);

        // Bridge to spoke A
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(recipient), "");

        // Verify positions burned on hub
        assertEq(hubPositionManager.balanceOf(user, positionId0), 0, "Positions not burned on hub");

        // Deliver to spoke A
        _deliverFromHub();

        // Verify positions minted on spoke
        assertEq(spokeAPositionManager.balanceOf(recipient, positionId0), amount, "Positions not minted on spoke");

        // Verify condition prepared on spoke
        assertEq(spokeAPositionManager.balanceOf(recipient, positionId0), amount, "Positions not minted on spoke");
    }

    function test_bridge_migration_binaryPositions_spokeToHub() public {
        uint256 amount = 100_000_000;

        // First: hub -> spoke A
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition("test-question", amount);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");

        // Verify burned on hub
        assertEq(hubPositionManager.balanceOf(user, positionId0), 0, "Positions not burned on hub");

        _deliverFromHub();

        // Verify minted on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount, "Positions not minted on spoke A");

        // Now bridge back to hub
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeAPositionManager.unsafeBatchTransferFrom(user, address(spokeABridge), positionIds, amounts);

        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(HUB_DST, positionIds, amounts, _toBytes32(recipient), "");

        // Verify burned on spoke A
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), 0, "Positions not burned on spoke A");

        // Deliver back to hub
        _deliverFromSpokeA();

        // Verify minted on hub (condition already exists, no prepare needed)
        assertEq(hubPositionManager.balanceOf(recipient, positionId0), amount, "Positions not minted back on hub");

        // Condition should still be registered to the same module
    }

    function test_bridge_migration_binaryPositions_spokeToSpoke() public {
        uint256 amount = 100_000_000;

        // First: hub -> spoke A
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) = _setupBinaryCondition("test-question", amount);

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
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), 0, "Positions not burned on spoke A");
        assertEq(spokeAPositionManager.balanceOf(user, positionId1), 0, "NO not burned on spoke A");

        // Deliver to spoke B
        _deliverFromSpokeA();

        // Verify minted on spoke B
        assertEq(spokeBPositionManager.balanceOf(recipient, positionId0), amount, "Positions not minted on spoke B");
        assertEq(spokeBPositionManager.balanceOf(recipient, positionId1), amount, "NO not minted on spoke B");

        // Conditions no longer need preparation — positions are minted directly
    }

    function test_bridge_migration_binaryPositions_roundTrip() public {
        uint256 amount = 100_000_000;

        // Setup
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition("test-question", amount);

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
        // Conditions no longer need preparation
    }

    function test_bridge_migration_binaryPositions_partialAmount() public {
        uint256 totalAmount = 100_000_000;
        uint256 bridgeAmount = 40_000_000;
        uint256 remainingAmount = totalAmount - bridgeAmount;

        // Setup and migrate both positions on hub
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition("test-partial-binary", totalAmount);

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

        // Verify condition registered on spoke
        // Conditions no longer need preparation
    }

    function test_bridge_migration_binaryPositions_idempotentConditionPrep() public {
        uint256 amount = 100_000_000;

        // Setup condition and positions on hub
        (bytes32 conditionId, uint256 positionId0, uint256 positionId1) =
            _setupBinaryCondition(bytes32("test-binary-idempotent"), amount);

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

        // Verify condition prepared on spoke
        // Conditions no longer need preparation
        assertEq(spokeAPositionManager.balanceOf(user, positionId0), amount / 2);

        // Second bridge - condition already exists, should still work
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

    function test_bridge_migration_binaryPositions_unpreparedMigrationCondition_noRevert() public {
        // Conditions no longer need preparation for bridging — this should not revert
        vm.chainId(HUB_CHAIN_ID);

        bytes32 questionId = keccak256("test-binary-migration-bridge-block");
        bytes32 legacyConditionId = CTHelpers.getConditionId(oracle, questionId, 2);
        hubCT.prepareCondition(oracle, questionId, 2);

        bytes32 migrationConditionId = hubBinaryModule.getMigrationConditionId(legacyConditionId);
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(migrationConditionId)), 0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0; // zero amount — bridge should process without revert

        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeABridge.bridgePositions{ value: 0.01 ether }(HUB_DST, positionIds, amounts, _toBytes32(user), "");
    }

    /*--------------------------------------------------------------
               NEGRISK MIGRATION POSITION BRIDGING TESTS
    --------------------------------------------------------------*/

    function test_bridge_migration_negRiskPositions_hubToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds,) = _setupNegRiskEvent(amount);

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

        // Verify event registered on spoke
        // Conditions no longer need preparation
    }

    function test_bridge_migration_negRiskPositions_spokeToHub() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds,) = _setupNegRiskEvent(amount);

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

        // Verify condition still registered on hub
        // Conditions no longer need preparation
    }

    function test_bridge_migration_negRiskPositions_spokeToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds,) = _setupNegRiskEvent(amount);

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

        // Verify condition registered on spoke B
        // Conditions no longer need preparation
    }

    function test_bridge_migration_negRiskPositions_roundTrip() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory allPositionIds,) = _setupNegRiskEvent(amount);

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
        // Conditions no longer need preparation
    }

    function test_bridge_migration_negRiskPositions_partialAmount() public {
        uint256 totalAmount = 100_000_000;
        uint256 bridgeAmount = 40_000_000;
        uint256 remainingAmount = totalAmount - bridgeAmount;

        // Setup event and positions on hub
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds,) =
            _setupNegRiskEvent(totalAmount);

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

        // Verify condition registered on spoke
        // Conditions no longer need preparation
    }

    function test_bridge_migration_negRiskPositions_idempotentConditionPrep() public {
        uint256 amount = 100_000_000;

        // Setup event and positions on hub
        (, bytes32[] memory conditionIds, uint256[] memory positionIds,) = _setupNegRiskEvent(amount);

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

        // Verify condition prepared on spoke
        // Conditions no longer need preparation
        assertEq(spokeAPositionManager.balanceOf(user, positionIds[0]), amount / 2);

        // Second bridge - condition already exists, should still work
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

    function test_bridge_migration_binaryResult_hubToSpoke() public {
        uint256 amount = 100_000_000;
        bytes32 questionId = "test-result-binary";

        // Setup and bridge positions to spoke
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition(questionId, amount);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        // Resolve on hub via legacy CTF
        vm.chainId(HUB_CHAIN_ID);
        _resolveBinaryOnHub(questionId, conditionId);

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
    function test_revert_bridge_migration_binaryResult_spokeToSpoke() public {
        uint256 amount = 100_000_000;
        bytes32 questionId = "test-result-spoke-binary";

        // Setup and bridge positions HUB -> SPOKE_A
        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition(questionId, amount);

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

        // Resolve on hub via legacy CTF
        vm.chainId(HUB_CHAIN_ID);
        _resolveBinaryOnHub(questionId, conditionId);

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

    function test_bridge_migration_negRiskResult_hubToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup and bridge event + positions to spoke
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds, bytes32[] memory questionIds) =
            _setupNegRiskEvent(amount);
        bytes32 conditionId = conditionIds[0];
        uint256 positionId0 = positionIds[0];

        // Bridge positions
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

        // Resolve only the winner on the hub. Bridging it now would let the spoke lazily
        // derive the unresolved migration sibling as NO.
        vm.chainId(HUB_CHAIN_ID);
        _resolveNegRiskOnHub(questionIds[0], conditionIds[0], true);

        vm.expectRevert(NegRiskMigrationErrors.MigrationEventNotFullyResolved.selector);
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionId), "");

        // Once every real sibling has been explicitly resolved on the hub, the winner can
        // safely activate lazy sibling derivation on the spoke.
        _resolveNegRiskOnHub(questionIds[1], conditionIds[1], false);
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionId), "");
        _deliverFromHub();

        // Verify result on spoke
        assertTrue(spokeANegRiskModule.hasResult(ConditionIdLib.from(conditionId)), "Result not bridged");

        uint256[] memory spokeResult = spokeANegRiskModule.getResult(ConditionIdLib.from(conditionId));
        assertEq(spokeResult[0], 1_000_000, "Wrong YES payout");
        assertEq(spokeResult[1], 0, "Wrong NO payout");

        uint256[] memory siblingResult = spokeANegRiskModule.getResult(ConditionIdLib.from(conditionIds[1]));
        assertEq(siblingResult[0], 0, "Wrong sibling YES payout");
        assertEq(siblingResult[1], 1_000_000, "Wrong sibling NO payout");
    }

    function test_bridge_migration_negRiskNoResult_hubToSpoke_beforeEventFullyResolved() public {
        uint256 amount = 100_000_000;

        (, bytes32[] memory conditionIds,, bytes32[] memory questionIds) = _setupNegRiskEvent(amount);

        vm.chainId(HUB_CHAIN_ID);
        _resolveNegRiskOnHub(questionIds[0], conditionIds[0], false);

        // A losing result is safe to bridge independently because it does not activate lazy
        // sibling result derivation on the spoke.
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionIds[0]), "");
        _deliverFromHub();

        uint256[] memory spokeResult = spokeANegRiskModule.getResult(ConditionIdLib.from(conditionIds[0]));
        assertEq(spokeResult[0], 0, "Wrong YES payout");
        assertEq(spokeResult[1], 1_000_000, "Wrong NO payout");
        assertFalse(
            spokeANegRiskModule.hasResult(ConditionIdLib.from(conditionIds[1])),
            "Unresolved sibling should not be derived"
        );
    }

    function test_bridge_migration_negRiskOtherResult_hubToSpoke_afterEventFullyResolved() public {
        uint256 amount = 100_000_000;

        (bytes32 eventId, bytes32[] memory conditionIds,, bytes32[] memory questionIds) = _setupNegRiskEvent(amount);

        vm.chainId(HUB_CHAIN_ID);
        _resolveNegRiskOnHub(questionIds[0], conditionIds[0], false);
        _resolveNegRiskOnHub(questionIds[1], conditionIds[1], false);

        ConditionId otherConditionId =
            EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), conditionIds.length);
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, otherConditionId, "");
        _deliverFromHub();

        uint256[] memory spokeResult = spokeANegRiskModule.getResult(otherConditionId);
        assertEq(spokeResult[0], 1_000_000, "Wrong Other YES payout");
        assertEq(spokeResult[1], 0, "Wrong Other NO payout");
        assertEq(
            spokeANegRiskModule.conditionsResolved(EventId.wrap(bytes29(eventId))),
            0,
            "Other must not increment real result count"
        );

        // CCIP permits out-of-order execution. Delivering Other before the real NO results
        // must still leave the counter equal to the number of real conditions.
        for (uint256 i = 0; i < conditionIds.length; ++i) {
            vm.chainId(HUB_CHAIN_ID);
            hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionIds[i]), "");
            _deliverFromHub();
            assertEq(
                spokeANegRiskModule.conditionsResolved(EventId.wrap(bytes29(eventId))), i + 1, "Wrong real result count"
            );
        }
    }

    /// @dev See `test_revert_bridge_migration_binaryResult_spokeToSpoke`.
    function test_revert_bridge_migration_negRiskResult_spokeToSpoke() public {
        uint256 amount = 100_000_000;

        // Setup and bridge event + positions HUB -> SPOKE_A
        (bytes32 eventId, bytes32[] memory conditionIds, uint256[] memory positionIds, bytes32[] memory questionIds) =
            _setupNegRiskEvent(amount);
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

        // Resolve every real condition on the hub before exporting the winning result.
        vm.chainId(HUB_CHAIN_ID);
        _resolveNegRiskOnHub(questionIds[0], conditionIds[0], true);
        _resolveNegRiskOnHub(questionIds[1], conditionIds[1], false);

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

    function test_bridge_migration_binaryPositionId_matchesAcrossChains(bytes32 conditionId, uint256 outcomeIndex)
        public
    {
        outcomeIndex = bound(outcomeIndex, 0, 1);
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

    function test_bridge_migration_negRiskDerivation_matchesAcrossChains(
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

    function test_bridge_migration_moduleId_matches() public view {
        assertEq(hubBinaryModule.moduleId(), spokeABinaryModule.moduleId(), "Binary moduleId mismatch");
        assertEq(hubNegRiskModule.moduleId(), spokeANegRiskModule.moduleId(), "NegRisk moduleId mismatch");
        assertEq(hubBinaryModule.moduleId(), ModuleIds.BINARY, "Wrong binary moduleId");
        assertEq(hubNegRiskModule.moduleId(), ModuleIds.NEGRISK, "Wrong negRisk moduleId");
    }

    /*--------------------------------------------------------------
                            HELPER FUNCTIONS
    --------------------------------------------------------------*/

    /// @notice Setup legacy binary condition and migrate positions
    /// @return conditionId The STRUCTURED conditionId (for use with migration flow)
    /// @return positionId0 The STRUCTURED position ID for YES outcome
    /// @return positionId1 The STRUCTURED position ID for NO outcome
    function _setupBinaryCondition(bytes32 questionId, uint256 amount)
        internal
        returns (bytes32 conditionId, uint256 positionId0, uint256 positionId1)
    {
        vm.chainId(HUB_CHAIN_ID);

        // Prepare condition in legacy CT
        bytes32 legacyConditionId = CTHelpers.getConditionId(oracle, questionId, 2);
        hubCT.prepareCondition(oracle, questionId, 2);

        // Prepare migration condition (creates structured IDs internally)
        vm.prank(creator);
        hubBinaryModule.prepareMigrationCondition(legacyConditionId);

        // Get STRUCTURED IDs for the new position manager
        conditionId = hubBinaryModule.getMigrationConditionId(legacyConditionId);
        positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));
        positionId1 = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 1));

        // Mint USDCe and split into positions via legacy CT
        hubCollateral.usdce.mint(user, amount);
        vm.startPrank(user);
        hubCollateral.usdce.approve(address(hubCT), amount);
        hubCT.splitPosition(hubUsdce, bytes32(0), legacyConditionId, CTFHelpers.partition(), amount);
        vm.stopPrank();

        // Migrate BOTH positions via new API (legacyConditionIds, outcomeIndices, amounts)
        bytes32[] memory legacyConditionIds = new bytes32[](2);
        legacyConditionIds[0] = legacyConditionId;
        legacyConditionIds[1] = legacyConditionId;
        uint256[] memory outcomeIndices = new uint256[](2);
        outcomeIndices[0] = 0; // YES
        outcomeIndices[1] = 1; // NO
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.startPrank(user);
        hubCT.setApprovalForAll(address(hubBinaryModule), true);
        hubBinaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
        vm.stopPrank();

        // Verify migration (using STRUCTURED position IDs)
        assertEq(hubPositionManager.balanceOf(user, positionId0), amount, "YES migration failed");
        assertEq(hubPositionManager.balanceOf(user, positionId1), amount, "NO migration failed");
    }

    /// @notice Setup legacy NegRisk event and migrate positions
    /// @return eventId The structured eventId per PositionIdLib with condition/outcome suffix zeroed
    /// @return conditionIds STRUCTURED conditionIds for the new position manager
    /// @return positionIds STRUCTURED position IDs [Q0 YES, Q0 NO, Q1 YES, Q1 NO]
    /// @return questionIds Legacy questionIds (for resolving on legacy adapter)
    function _setupNegRiskEvent(uint256 amount)
        internal
        returns (
            bytes32 eventId,
            bytes32[] memory conditionIds,
            uint256[] memory positionIds,
            bytes32[] memory questionIds
        )
    {
        vm.chainId(HUB_CHAIN_ID);

        // Prepare market and questions in legacy adapter (need 2 for spoke compatibility)
        vm.startPrank(oracle);
        bytes32 legacyEventId = hubNRA.prepareMarket(0, "");
        questionIds = new bytes32[](2);
        questionIds[0] = hubNRA.prepareQuestion(legacyEventId, "");
        questionIds[1] = hubNRA.prepareQuestion(legacyEventId, "second question");
        vm.stopPrank();

        // Get legacy condition IDs (for splitPosition via legacy adapter)
        bytes32[] memory legacyConditionIds = new bytes32[](2);
        legacyConditionIds[0] = hubNRA.getConditionId(questionIds[0]);
        legacyConditionIds[1] = hubNRA.getConditionId(questionIds[1]);

        // Prepare migration event (creates structured IDs internally)
        vm.prank(creator);
        hubNegRiskModule.prepareMigrationEvent(legacyEventId);

        // Return the canonical arity-bearing eventId used by the migrated module.
        eventId = EventId.unwrap(EventIdLib.encode(ModuleIds.NEGRISK, legacyEventId, questionIds.length));

        // Get STRUCTURED condition IDs for the new position manager
        conditionIds = new bytes32[](2);
        conditionIds[0] = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 0));
        conditionIds[1] = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 1));

        // Get STRUCTURED position IDs (YES and NO for each condition)
        positionIds = new uint256[](4);
        positionIds[0] =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionIds[0])), 0)); // Q0
        // YES
        positionIds[1] =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionIds[0])), 1)); // Q0
        // NO
        positionIds[2] =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionIds[1])), 0)); // Q1
        // YES
        positionIds[3] =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionIds[1])), 1)); // Q1
        // NO

        // Mint USDCe and split into positions via NegRisk adapter (first condition only)
        hubCollateral.usdce.mint(user, amount);
        vm.startPrank(user);
        hubCollateral.usdce.approve(address(hubNRA), amount);
        hubNRA.splitPosition(legacyConditionIds[0], amount);
        vm.stopPrank();

        // Migrate BOTH YES and NO positions for first condition
        bytes32[] memory migrateLegacyConditionIds = new bytes32[](2);
        migrateLegacyConditionIds[0] = legacyConditionIds[0];
        migrateLegacyConditionIds[1] = legacyConditionIds[0];
        uint256[] memory outcomeIndices = new uint256[](2);
        outcomeIndices[0] = 0; // YES
        outcomeIndices[1] = 1; // NO
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.startPrank(user);
        hubCT.setApprovalForAll(address(hubNegRiskModule), true);
        hubNegRiskModule.migratePositions(migrateLegacyConditionIds, outcomeIndices, amounts);
        vm.stopPrank();

        // Verify migration (using STRUCTURED position IDs)
        assertEq(hubPositionManager.balanceOf(user, positionIds[0]), amount, "YES migration failed");
        assertEq(hubPositionManager.balanceOf(user, positionIds[1]), amount, "NO migration failed");
    }

    /// @notice Resolve binary condition on hub legacy CTF (YES wins)
    function _resolveBinaryOnHub(bytes32 questionId, bytes32 conditionId) internal {
        vm.chainId(HUB_CHAIN_ID);

        // Report payouts: YES=1, NO=0
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(oracle);
        hubCT.reportPayouts(questionId, payouts);

        // Resolve condition (pulls from legacy CT)
        hubBinaryModule.resolveMigrationCondition(conditionId);
    }

    /// @notice Resolve a NegRisk condition on the hub legacy adapter.
    function _resolveNegRiskOnHub(bytes32 questionId, bytes32 conditionId, bool outcome) internal {
        vm.chainId(HUB_CHAIN_ID);

        vm.prank(oracle);
        hubNRA.reportOutcome(questionId, outcome);

        // Resolve migration condition (pulls from legacy CT)
        hubNegRiskModule.resolveMigrationCondition(conditionId);
    }
}

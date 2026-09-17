// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";
import { NegRiskIdLib } from "@polymarket-v2/src/legacy/libraries/NegRiskIdLib.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import {
    Collateral,
    Positions,
    PositionManagerSetup,
    Legacy
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";

/// @notice Gas snapshot tests for binary and NegRisk module migrations
/// @dev Run with: forge snapshot --match-contract MigrationSnapshots_Test
/// @dev Snapshots are written to snapshots/MigrationSnapshots_Test.json
contract MigrationSnapshots_Test is TestHelper {
    Positions positions;
    Collateral collateral;
    Legacy legacy;

    bytes32 binaryQuestionId;
    bytes32 binaryConditionId;

    function setUp() public {
        (positions, collateral, legacy) = PositionManagerSetup._deploy(owner, admin, creator);

        vm.startPrank(admin);
        positions.binaryModule.addOperator(operator);
        positions.negRiskModule.addOperator(operator);
        vm.stopPrank();

        binaryQuestionId = "questionId";
        binaryConditionId = CTHelpers.getConditionId(oracle, binaryQuestionId, 2);
    }

    /*--------------------------------------------------------------
                          BINARY SNAPSHOTS
    --------------------------------------------------------------*/

    function test_MigrationSnapshots_binary_migrate_batch2() public {
        _snapshotBinaryMigrateBatch("binary_migrate_batch2", 2);
    }

    function test_MigrationSnapshots_binary_migrate_batch4() public {
        _snapshotBinaryMigrateBatch("binary_migrate_batch4", 4);
    }

    function test_MigrationSnapshots_binary_migrate_batch8() public {
        _snapshotBinaryMigrateBatch("binary_migrate_batch8", 8);
    }

    function test_MigrationSnapshots_binary_migrate_batch16() public {
        _snapshotBinaryMigrateBatch("binary_migrate_batch16", 16);
    }

    function test_MigrationSnapshots_binary_migrate_operator_batch4() public {
        uint256 amount = _prepareBinaryLegacyPositions();
        (bytes32[] memory legacyConditionIds, uint256[] memory outcomeIndexes, uint256[] memory amounts) =
            _buildBinaryBatch(4, amount);

        vm.startSnapshotGas("binary_migrate_operator_batch4");
        vm.prank(operator);
        positions.binaryModule.migratePositions(address(alice), legacyConditionIds, outcomeIndexes, amounts);
        vm.stopSnapshotGas();
    }

    /*--------------------------------------------------------------
                         NEGRISK SNAPSHOTS
    --------------------------------------------------------------*/

    function test_MigrationSnapshots_negRisk_migrate_batch2() public {
        _snapshotNegRiskMigrateBatch("negRisk_migrate_batch2", 2);
    }

    function test_MigrationSnapshots_negRisk_migrate_batch4() public {
        _snapshotNegRiskMigrateBatch("negRisk_migrate_batch4", 4);
    }

    function test_MigrationSnapshots_negRisk_migrate_batch8() public {
        _snapshotNegRiskMigrateBatch("negRisk_migrate_batch8", 8);
    }

    function test_MigrationSnapshots_negRisk_migrate_batch16() public {
        _snapshotNegRiskMigrateBatch("negRisk_migrate_batch16", 16);
    }

    function test_MigrationSnapshots_negRisk_migrate_operator_batch4() public {
        bytes32 eventId = _prepareNegRiskLegacyPositions(4);
        (bytes32[] memory legacyConditionIds, uint256[] memory outcomeIndexes, uint256[] memory amounts) =
            _buildNegRiskBatch(eventId, 4);

        vm.startSnapshotGas("negRisk_migrate_operator_batch4");
        vm.prank(operator);
        positions.negRiskModule.migratePositions(address(alice), legacyConditionIds, outcomeIndexes, amounts);
        vm.stopSnapshotGas();
    }

    /*--------------------------------------------------------------
                        BINARY HELPERS
    --------------------------------------------------------------*/

    function _snapshotBinaryMigrateBatch(string memory label, uint256 batchSize) internal {
        uint256 amount = _prepareBinaryLegacyPositions();
        (bytes32[] memory legacyConditionIds, uint256[] memory outcomeIndexes, uint256[] memory amounts) =
            _buildBinaryBatch(batchSize, amount);

        vm.startSnapshotGas(label);
        vm.prank(alice);
        positions.binaryModule.migratePositions(legacyConditionIds, outcomeIndexes, amounts);
        vm.stopSnapshotGas();
    }

    function _prepareBinaryLegacyPositions() internal returns (uint256 amount) {
        amount = 100_000_000;
        legacy.conditionalTokens.prepareCondition(oracle, binaryQuestionId, 2);

        vm.prank(creator);
        positions.binaryModule.prepareMigrationCondition(binaryConditionId);

        vm.startPrank(alice);
        collateral.usdce.mint(alice, amount);
        collateral.usdce.approve(address(legacy.conditionalTokens), amount);
        legacy.conditionalTokens
            .splitPosition(address(collateral.usdce), bytes32(0), binaryConditionId, CTFHelpers.partition(), amount);
        legacy.conditionalTokens.setApprovalForAll(address(positions.binaryModule), true);
        vm.stopPrank();
    }

    function _buildBinaryBatch(uint256 batchSize, uint256 amount)
        internal
        view
        returns (bytes32[] memory legacyConditionIds, uint256[] memory outcomeIndexes, uint256[] memory amounts)
    {
        uint256 perOutcomeAmount = amount / (batchSize / 2);
        legacyConditionIds = new bytes32[](batchSize);
        outcomeIndexes = new uint256[](batchSize);
        amounts = new uint256[](batchSize);

        for (uint256 i = 0; i < batchSize;) {
            legacyConditionIds[i] = binaryConditionId;
            outcomeIndexes[i] = i & 1;
            amounts[i] = perOutcomeAmount;
            unchecked {
                ++i;
            }
        }
    }

    /*--------------------------------------------------------------
                        NEGRISK HELPERS
    --------------------------------------------------------------*/

    function _snapshotNegRiskMigrateBatch(string memory label, uint256 batchSize) internal {
        bytes32 eventId = _prepareNegRiskLegacyPositions(batchSize);
        (bytes32[] memory legacyConditionIds, uint256[] memory outcomeIndexes, uint256[] memory amounts) =
            _buildNegRiskBatch(eventId, batchSize);

        vm.startSnapshotGas(label);
        vm.prank(alice);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndexes, amounts);
        vm.stopSnapshotGas();
    }

    function _prepareNegRiskLegacyPositions(uint256 questionCount) internal returns (bytes32 eventId) {
        bytes memory data = new bytes(0);
        vm.prank(oracle);
        eventId = legacy.negRiskAdapter.prepareMarket(0, data);

        for (uint8 i = 0; i < uint8(questionCount);) {
            vm.prank(oracle);
            bytes32 questionId = legacy.negRiskAdapter.prepareQuestion(eventId, data);
            bytes32 conditionId = legacy.negRiskAdapter.getConditionId(questionId);

            vm.startPrank(alice);
            collateral.usdce.mint(alice, 100_000_000);
            collateral.usdce.approve(address(legacy.negRiskAdapter), 100_000_000);
            legacy.negRiskAdapter.splitPosition(conditionId, 100_000_000);
            vm.stopPrank();

            unchecked {
                ++i;
            }
        }

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(eventId);

        vm.prank(alice);
        legacy.conditionalTokens.setApprovalForAll(address(positions.negRiskModule), true);
    }

    function _buildNegRiskBatch(bytes32 eventId, uint256 batchSize)
        internal
        view
        returns (bytes32[] memory legacyConditionIds, uint256[] memory outcomeIndexes, uint256[] memory amounts)
    {
        legacyConditionIds = new bytes32[](batchSize);
        outcomeIndexes = new uint256[](batchSize);
        amounts = new uint256[](batchSize);

        for (uint8 i = 0; i < uint8(batchSize);) {
            bytes32 questionId = NegRiskIdLib.getQuestionId(eventId, i);
            legacyConditionIds[i] = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId, 2);
            outcomeIndexes[i] = 0;
            amounts[i] = 100_000_000;
            unchecked {
                ++i;
            }
        }

        _sortBatch(legacyConditionIds, outcomeIndexes, amounts);
    }

    function _sortBatch(bytes32[] memory legacyConditionIds, uint256[] memory outcomeIndexes, uint256[] memory amounts)
        internal
        pure
    {
        for (uint256 i = 1; i < legacyConditionIds.length; ++i) {
            bytes32 legacyConditionId = legacyConditionIds[i];
            uint256 outcomeIndex = outcomeIndexes[i];
            uint256 amount = amounts[i];
            uint256 j = i;

            while (j > 0 && uint256(legacyConditionIds[j - 1]) > uint256(legacyConditionId)) {
                legacyConditionIds[j] = legacyConditionIds[j - 1];
                outcomeIndexes[j] = outcomeIndexes[j - 1];
                amounts[j] = amounts[j - 1];
                --j;
            }

            legacyConditionIds[j] = legacyConditionId;
            outcomeIndexes[j] = outcomeIndex;
            amounts[j] = amount;
        }
    }
}

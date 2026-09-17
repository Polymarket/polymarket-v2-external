// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral, CollateralSetup } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { DeployLib } from "@polymarket-v2/src/dev/DeployLib.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";
import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { ModuleProxyLib } from "@polymarket-v2/src/modules/dev/ModuleProxyLib.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { OracleModuleErrors } from "@polymarket-v2/src/modules/abstract/OracleModule.sol";
import { MigrationErrors, MigrationEvents } from "@polymarket-v2/src/modules/migration/BaseMigrationMixin.sol";
import { ConditionId, ConditionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

contract BinaryMigrationTest is TestHelper, MigrationErrors, MigrationEvents {
    error Unauthorized();

    Collateral collateral;

    IConditionalTokens conditionalTokens;

    PositionManager positionManager;

    BinaryModule binaryModule;

    address wrappedCollateralToken;
    bytes32 questionId;
    bytes32 conditionId;

    function setUp() public virtual {
        collateral = CollateralSetup._deploy(owner);

        conditionalTokens = IConditionalTokens(DeployLib.deployConditionalTokens());

        address positionManagerImplementation = address(new PositionManager(address(collateral.token)));
        address positionManagerProxy = LibClone.deployERC1967(positionManagerImplementation);

        vm.label(positionManagerImplementation, "PositionManagerImplementation");
        vm.label(positionManagerProxy, "PositionManager");

        positionManager = PositionManager(positionManagerProxy);
        positionManager.initialize(owner, admin);

        binaryModule = ModuleProxyLib.deployBinaryModule(
            address(positionManager), owner, admin, address(conditionalTokens), address(collateral.usdce)
        );

        vm.prank(owner);
        collateral.token.addWrapper(address(binaryModule));

        vm.startPrank(admin);
        positionManager.addModule(address(binaryModule));
        binaryModule.addCreator(creator);
        binaryModule.addOperator(operator);
        vm.stopPrank();

        vm.prank(alice);
        conditionalTokens.setApprovalForAll(address(binaryModule), true);

        vm.prank(brian);
        conditionalTokens.setApprovalForAll(address(binaryModule), true);

        questionId = "questionId";
        conditionId = CTHelpers.getConditionId(oracle, questionId, 2);
    }
}

/*--------------------------------------------------------------
                      MIGRATE POSITIONS
--------------------------------------------------------------*/

contract BinaryMigrationTest_migrate is BinaryMigrationTest {
    function test_migrate() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        // Get LEGACY position IDs for CT operations
        uint256[] memory legacyPositionIds = new uint256[](2);
        legacyPositionIds[0] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
        legacyPositionIds[1] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 2));

        // Prepare condition in migration flow (creates structured IDs internally)
        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get STRUCTURED conditionId for migration flow operations
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[0]), amount);
        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[1]), amount);

        // transfer no token to brian
        vm.prank(alice);
        conditionalTokens.safeTransferFrom(alice, address(brian), legacyPositionIds[1], amount, "");

        // Use legacy condition IDs for migratePositions
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        // alice migrate yes position
        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[0]), 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyPositionIds[0]), amount);
        // Use STRUCTURED conditionId for balance check
        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), amount);

        vm.prank(brian);
        outcomeIndices[0] = 1;
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(conditionalTokens.balanceOf(brian, legacyPositionIds[1]), 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyPositionIds[1]), 0);
        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), amount);

        // usdce is now in the collateral vault deposit location
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }

    function test_migrate_asymmetricComplementaryBalances_sameCall() public {
        uint256 yesAmount = 200_000_000;
        uint256 noAmount = 100_000_000;

        conditionalTokens.prepareCondition(oracle, questionId, 2);

        uint256 legacyYesPositionId =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
        uint256 legacyNoPositionId =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 2));

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, yesAmount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), yesAmount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), yesAmount
        );
        conditionalTokens.safeTransferFrom(alice, brian, legacyNoPositionId, noAmount, "");
        vm.stopPrank();

        bytes32[] memory legacyConditionIds = new bytes32[](2);
        legacyConditionIds[0] = conditionId;
        legacyConditionIds[1] = conditionId;

        uint256[] memory outcomeIndices = new uint256[](2);
        outcomeIndices[0] = 0;
        outcomeIndices[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmount;
        amounts[1] = noAmount;

        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(conditionalTokens.balanceOf(alice, legacyYesPositionId), 0);
        assertEq(conditionalTokens.balanceOf(alice, legacyNoPositionId), 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyYesPositionId), yesAmount - noAmount);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyNoPositionId), 0);

        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), yesAmount);
        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 1), noAmount);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), noAmount);
    }

    function test_migrate_repeatedConditionEntries_clampsToCurrentBalance() public {
        uint256 splitAmount = 300_000_000;

        conditionalTokens.prepareCondition(oracle, questionId, 2);

        uint256 legacyYesPositionId =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
        uint256 legacyNoPositionId =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 2));

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, splitAmount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), splitAmount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), splitAmount
        );
        conditionalTokens.safeTransferFrom(alice, brian, legacyNoPositionId, 100_000_000, "");
        vm.stopPrank();

        bytes32[] memory legacyConditionIds = new bytes32[](4);
        uint256[] memory outcomeIndices = new uint256[](4);
        uint256[] memory amounts = new uint256[](4);

        legacyConditionIds[0] = conditionId;
        legacyConditionIds[1] = conditionId;
        legacyConditionIds[2] = conditionId;
        legacyConditionIds[3] = conditionId;

        outcomeIndices[0] = 0;
        outcomeIndices[1] = 1;
        outcomeIndices[2] = 0;
        outcomeIndices[3] = 1;

        amounts[0] = 100_000_000;
        amounts[1] = 150_000_000;
        amounts[2] = 200_000_000;
        amounts[3] = 50_000_000;

        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(conditionalTokens.balanceOf(alice, legacyYesPositionId), 0);
        assertEq(conditionalTokens.balanceOf(alice, legacyNoPositionId), 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyYesPositionId), 100_000_000);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyNoPositionId), 0);

        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), 300_000_000);
        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 1), 200_000_000);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 200_000_000);
    }

    function test_migrate_fromOperator() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        // Get LEGACY position IDs for CT operations
        uint256[] memory legacyPositionIds = new uint256[](2);
        legacyPositionIds[0] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
        legacyPositionIds[1] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 2));

        // Prepare condition in migration flow
        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get STRUCTURED conditionId
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[0]), amount);
        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[1]), amount);

        // transfer no token to brian
        vm.prank(alice);
        conditionalTokens.safeTransferFrom(alice, address(brian), legacyPositionIds[1], amount, "");

        // Use legacy condition IDs for migratePositions
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        // migrate alice yes position
        vm.prank(alice);
        conditionalTokens.setApprovalForAll(address(binaryModule), true);

        vm.prank(operator);
        binaryModule.migratePositions(address(alice), legacyConditionIds, outcomeIndices, amounts);

        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[0]), 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyPositionIds[0]), amount);
        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), amount);

        // migrate brian yes position
        outcomeIndices[0] = 1;

        vm.prank(brian);
        conditionalTokens.setApprovalForAll(address(binaryModule), true);

        vm.prank(operator);
        binaryModule.migratePositions(address(brian), legacyConditionIds, outcomeIndices, amounts);

        assertEq(conditionalTokens.balanceOf(brian, legacyPositionIds[1]), 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyPositionIds[1]), 0);
        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), amount);

        // usdce is now in the collateral vault deposit location
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }

    function test_revert_InvalidFromAddress() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        uint256[] memory legacyPositionIds = new uint256[](2);
        legacyPositionIds[0] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
        legacyPositionIds[1] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 2));

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get structured conditionId
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[0]), amount);
        assertEq(conditionalTokens.balanceOf(alice, legacyPositionIds[1]), amount);

        // transfer no token to brian
        vm.prank(alice);
        conditionalTokens.safeTransferFrom(alice, address(brian), legacyPositionIds[1], amount, "");

        // Use legacy condition IDs
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        // alice migrate yes position
        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        vm.prank(operator);
        vm.expectRevert(ModuleErrors.InvalidFromAddress.selector);
        binaryModule.migratePositions(address(binaryModule), legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_invalidArrayLength() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get structured conditionId
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        // Mismatched array lengths
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](2); // Wrong length
        amounts[0] = 100_000_000;
        amounts[1] = 100_000_000;

        vm.prank(alice);
        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_migrationNotRegistered() public {
        // Don't prepare condition in migration flow

        conditionalTokens.prepareCondition(oracle, questionId, 2);

        collateral.usdce.mint(alice, 100_000_000);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), 100_000_000);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), 100_000_000
        );
        vm.stopPrank();

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(alice);
        vm.expectRevert(MigrationErrors.MigrationNotRegistered.selector);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_migrationConditionIdAlias() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 aliasedConditionId = bytes32(uint256(conditionId) ^ (uint256(1) << 255));
        assertEq(
            binaryModule.getMigrationConditionId(aliasedConditionId), binaryModule.getMigrationConditionId(conditionId)
        );

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = aliasedConditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        vm.prank(alice);
        vm.expectRevert(MigrationErrors.MigrationNotRegistered.selector);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_unsortedMigrationConditions() public {
        uint256 amount = 100_000_000;
        bytes32 questionId2 = "questionId2";
        bytes32 conditionId2 = CTHelpers.getConditionId(oracle, questionId2, 2);

        conditionalTokens.prepareCondition(oracle, questionId, 2);
        conditionalTokens.prepareCondition(oracle, questionId2, 2);

        vm.startPrank(creator);
        binaryModule.prepareMigrationCondition(conditionId);
        binaryModule.prepareMigrationCondition(conditionId2);
        vm.stopPrank();

        bytes32 first = uint256(conditionId) < uint256(conditionId2) ? conditionId2 : conditionId;
        bytes32 second = uint256(conditionId) < uint256(conditionId2) ? conditionId : conditionId2;

        collateral.usdce.mint(alice, amount * 2);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount * 2);
        conditionalTokens.splitPosition(address(collateral.usdce), bytes32(0), first, CTFHelpers.partition(), amount);
        conditionalTokens.splitPosition(address(collateral.usdce), bytes32(0), second, CTFHelpers.partition(), amount);
        vm.stopPrank();

        bytes32[] memory legacyConditionIds = new bytes32[](2);
        legacyConditionIds[0] = first;
        legacyConditionIds[1] = second;
        uint256[] memory outcomeIndices = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(alice);
        vm.expectRevert(MigrationErrors.UnsortedMigrationConditions.selector);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }

    function test_prepareMigrationCondition_emitsMigrationConditionRegistered() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        vm.expectEmit(true, true, true, true, address(binaryModule));
        emit MigrationConditionRegistered(ConditionIdLib.from(structuredConditionId), conditionId);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);
    }

    function test_migrate_alreadyResolved_redeemsToVault() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get structured conditionId
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        // Resolve the condition in CTF
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        // Resolve in migration flow using structured conditionId
        binaryModule.resolveMigrationCondition(structuredConditionId);

        // Migrate after resolution using legacy conditionId
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), amount);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }

    function test_revert_amountsLengthMismatch() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        // legacyConditionIds.length != amounts.length
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](2); // Wrong length
        amounts[0] = 100_000_000;
        amounts[1] = 100_000_000;

        vm.prank(alice);
        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }
}

/*--------------------------------------------------------------
                    PREPARE CONDITION
--------------------------------------------------------------*/

contract BinaryMigrationTest_prepareCondition is BinaryMigrationTest {
    function test_revert_wrongOutcomeCount() public {
        // Prepare condition with 3 outcomes instead of 2
        conditionalTokens.prepareCondition(oracle, questionId, 3);

        vm.expectRevert(ModuleErrors.MigrationNotSupported.selector);
        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);
    }

    function test_revert_alreadyPrepared() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Try to prepare same condition again
        vm.expectRevert(MigrationErrors.MigrationAlreadyRegistered.selector);
        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);
    }

    function test_revert_questionNotPrepared() public {
        // Don't prepare condition in ConditionalTokens

        vm.expectRevert(ModuleErrors.MigrationNotSupported.selector);
        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);
    }

    function test_revert_getLegacyPositionId_invalidOutcomeIndex() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        vm.expectRevert(ModuleErrors.InvalidOutcomeIndex.selector);
        binaryModule.getLegacyPositionId(structuredConditionId, 2);
    }
}

/*--------------------------------------------------------------
                 RESOLVE MIGRATION CONDITION
--------------------------------------------------------------*/

contract BinaryMigrationTest_resolveMigrationCondition is BinaryMigrationTest {
    function test_resolveMigrationCondition() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get structured conditionId
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        // Migrate alice's yes position using legacy conditionId
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        // Resolve the condition in CTF
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES wins
        payouts[1] = 0;

        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        // Now resolve in migration flow using structured conditionId
        binaryModule.resolveMigrationCondition(structuredConditionId);

        // Check that USDCe was redeemed and deposited to collateral token vault
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }

    function test_reportResult_migrationConditionSettlesCollateralToVault() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 0);
        uint256 legacyYesPositionId =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyYesPositionId), amount);

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;

        vm.prank(admin);
        binaryModule.addResolver(oracle);
        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.MigrationNotSupported.selector);
        binaryModule.reportResult(ConditionIdLib.from(structuredConditionId), result);

        vm.prank(admin);
        binaryModule.addBridge(devin);
        vm.prank(devin);
        vm.expectRevert(ModuleErrors.ConditionNotResolved.selector);
        binaryModule.reportResult(ConditionIdLib.from(structuredConditionId), result);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        uint256[] memory mismatch = new uint256[](2);
        mismatch[1] = 1_000_000;
        vm.prank(devin);
        vm.expectRevert(ModuleErrors.ExistingPayoutMismatch.selector);
        binaryModule.reportResult(ConditionIdLib.from(structuredConditionId), mismatch);

        assertEq(binaryModule.getResult(ConditionIdLib.from(structuredConditionId)).length, 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyYesPositionId), amount);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 0);

        vm.prank(devin);
        binaryModule.reportResult(ConditionIdLib.from(structuredConditionId), result);

        uint256[] memory storedResult = binaryModule.getResult(ConditionIdLib.from(structuredConditionId));
        assertEq(storedResult[0], 1_000_000);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyYesPositionId), 0);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }

    function test_revert_notResolvedOnLegacy() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get structured conditionId
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        // Don't resolve on legacy conditionalTokens - try to resolve directly
        vm.expectRevert(ModuleErrors.ConditionNotResolved.selector);
        binaryModule.resolveMigrationCondition(structuredConditionId);
    }

    function test_revert_resolutionPaused() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        // Admin pauses resolution for this condition
        vm.prank(admin);
        binaryModule.pauseResolution(ConditionIdLib.from(structuredConditionId).eventId());

        // The admin kill switch must block the migration path
        vm.expectRevert(OracleModuleErrors.ResolutionIsPaused.selector);
        binaryModule.resolveMigrationCondition(structuredConditionId);
    }

    function test_unpauseAllowsResolution() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        // Migrate alice's YES position into the module so there are legacy tokens to redeem.
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(alice);
        binaryModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(oracle);
        conditionalTokens.reportPayouts(questionId, payouts);

        vm.prank(admin);
        binaryModule.pauseResolution(ConditionIdLib.from(structuredConditionId).eventId());

        vm.expectRevert(OracleModuleErrors.ResolutionIsPaused.selector);
        binaryModule.resolveMigrationCondition(structuredConditionId);

        vm.prank(admin);
        binaryModule.unpauseResolution(ConditionIdLib.from(structuredConditionId).eventId());

        binaryModule.resolveMigrationCondition(structuredConditionId);

        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }
}

/*--------------------------------------------------------------
                    OPERATOR BATCH MIGRATE
--------------------------------------------------------------*/

contract BinaryMigrationTest_operatorBatchMigrate is BinaryMigrationTest {
    function test_batchMigratePositions() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Get structured conditionId
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        // Setup positions for alice and brian
        collateral.usdce.mint(alice, amount);
        collateral.usdce.mint(brian, amount);

        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        vm.startPrank(brian);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        vm.stopPrank();

        // Operator migrates for both users using legacy conditionIds
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        outcomeIndices[0] = 0;
        vm.prank(operator);
        binaryModule.migratePositions(alice, legacyConditionIds, outcomeIndices, amounts);

        outcomeIndices[0] = 1;
        vm.prank(operator);
        binaryModule.migratePositions(brian, legacyConditionIds, outcomeIndices, amounts);

        // Verify migrations using structured conditionId
        assertEq(positionManager.balanceOf(alice, ConditionIdLib.from(structuredConditionId), 0), amount);
        assertEq(positionManager.balanceOf(brian, ConditionIdLib.from(structuredConditionId), 1), amount);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }

    function test_revert_unauthorized() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        vm.prank(alice); // alice is not an operator
        binaryModule.migratePositions(alice, legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_invalidArrayLength() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // Mismatched array lengths
        bytes32[] memory legacyConditionIds = new bytes32[](2);
        legacyConditionIds[0] = conditionId;
        legacyConditionIds[1] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        vm.prank(operator);
        binaryModule.migratePositions(alice, legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_positionIdsLengthMismatch() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // legacyConditionIds.length != outcomeIndices.length
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](2); // Wrong length
        outcomeIndices[0] = 0;
        outcomeIndices[1] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        vm.prank(operator);
        binaryModule.migratePositions(alice, legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_amountsLengthMismatch() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        // legacyConditionIds.length == outcomeIndices.length, but != amounts.length
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](2); // Wrong length
        amounts[0] = 100_000_000;
        amounts[1] = 100_000_000;

        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        vm.prank(operator);
        binaryModule.migratePositions(alice, legacyConditionIds, outcomeIndices, amounts);
    }
}

/*--------------------------------------------------------------
              RECEIVER HOOK REGRESSION (CANTINA #10)
--------------------------------------------------------------*/

import { MigrationReentrancyMock } from "./mocks/MigrationReentrancyMock.sol";

/// @notice Cantina #10 regression. The migration mint path must not invoke
///         the ERC-1155 receiver hook on `_from`, so a contract recipient
///         cannot reenter via `onERC1155BatchReceived`.
contract BinaryMigrationTest_cantina10 is BinaryMigrationTest {
    MigrationReentrancyMock public mock;

    function setUp() public override {
        super.setUp();
        mock = new MigrationReentrancyMock();
        vm.label(address(mock), "MigrationReentrancyMock");
    }

    function test_migratePositions_doesNotInvokeReceiverHook() public {
        uint256 amount = 100_000_000;
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        uint256[] memory legacyPositionIds = new uint256[](2);
        legacyPositionIds[0] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 1));
        legacyPositionIds[1] =
            CTHelpers.getPositionId(address(collateral.usdce), CTHelpers.getCollectionId(bytes32(0), conditionId, 2));

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);
        bytes32 structuredConditionId = binaryModule.getMigrationConditionId(conditionId);

        // Alice splits legacy positions then transfers the YES leg to the mock.
        collateral.usdce.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdce.approve(address(conditionalTokens), amount);
        conditionalTokens.splitPosition(
            address(collateral.usdce), bytes32(0), conditionId, CTFHelpers.partition(), amount
        );
        conditionalTokens.safeTransferFrom(alice, address(mock), legacyPositionIds[0], amount, "");
        vm.stopPrank();

        mock.approveLegacyCt(conditionalTokens, address(binaryModule));

        // Arm the mock: any ERC-1155 receiver callback from this point on reverts.
        mock.setFailOnReceive(true);

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = conditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        // If migratePositions invoked `onERC1155BatchReceived` on `_from`, this call
        // would revert because the mock is armed. Success proves the receiver hook
        // is not dispatched — no reentrancy surface.
        vm.prank(operator);
        binaryModule.migratePositions(address(mock), legacyConditionIds, outcomeIndices, amounts);

        assertEq(conditionalTokens.balanceOf(address(mock), legacyPositionIds[0]), 0);
        assertEq(conditionalTokens.balanceOf(address(binaryModule), legacyPositionIds[0]), amount);
        assertEq(positionManager.balanceOf(address(mock), ConditionIdLib.from(structuredConditionId), 0), amount);
    }
}

/*--------------------------------------------------------------
        ALIAS-KEY REGRESSION (audit finding #6)
--------------------------------------------------------------*/

/// @notice Mirrors the neg-risk alias-key regression on the binary migration path. Any
///         attempt to resolve a migration condition with a non-canonical key (outcome byte
///         set) must revert at the wrap-at-top entry guard before any state is touched.
contract BinaryMigrationTest_softViewAliasReverts is BinaryMigrationTest {
    /// @dev External helpers so `vm.expectRevert` sees the wrap revert at a lower call depth.
    ///      Without these, `ConditionIdLib.from` runs inline in the test frame and reverts
    ///      before the `getResult`/`hasResult` call is dispatched, foiling the cheatcode.
    function _callGetResult(bytes32 _aliasKey) external view {
        binaryModule.getResult(ConditionIdLib.from(_aliasKey));
    }

    function _callHasResult(bytes32 _aliasKey) external view {
        binaryModule.hasResult(ConditionIdLib.from(_aliasKey));
    }

    /// @notice getResult and hasResult revert on non-canonical inputs rather than returning a
    ///         soft empty/false. Distinguishes "malformed input" (revert) from "unknown but
    ///         well-formed" (empty/false via the mapping default).
    function test_revert_getResult_nonCanonical() public {
        bytes32 aliasKey = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, aliasKey));
        this._callGetResult(aliasKey);
    }

    function test_revert_hasResult_nonCanonical() public {
        bytes32 aliasKey = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, aliasKey));
        this._callHasResult(aliasKey);
    }

    function test_getResult_unknownCanonicalReturnsEmpty() public view {
        bytes32 unknown = bytes32(uint256(0xdeadbeef) << 8);
        uint256[] memory r = binaryModule.getResult(ConditionIdLib.from(unknown));
        assertEq(r.length, 0);
    }

    function test_hasResult_unknownCanonicalReturnsFalse() public view {
        bytes32 unknown = bytes32(uint256(0xdeadbeef) << 8);
        assertFalse(binaryModule.hasResult(ConditionIdLib.from(unknown)));
    }
}

contract BinaryMigrationTest_aliasKeyRegression is BinaryMigrationTest {
    function test_revert_resolveMigrationCondition_aliasOutcomeByte() public {
        conditionalTokens.prepareCondition(oracle, questionId, 2);

        vm.prank(creator);
        binaryModule.prepareMigrationCondition(conditionId);

        bytes32 structured = binaryModule.getMigrationConditionId(conditionId);
        bytes32 aliasKey = bytes32(uint256(structured) | 1);

        vm.expectRevert(abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, aliasKey));
        // resolveMigrationCondition still takes bytes32 and validates via ConditionIdLib.from internally
        binaryModule.resolveMigrationCondition(aliasKey);
    }
}

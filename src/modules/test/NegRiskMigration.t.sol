// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { INegRiskAdapter } from "@polymarket-v2/src/legacy/interfaces/INegRiskAdapter.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { NegRiskIdLib } from "@polymarket-v2/src/legacy/libraries/NegRiskIdLib.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { OracleModuleErrors } from "@polymarket-v2/src/modules/abstract/OracleModule.sol";
import { MigrationErrors } from "@polymarket-v2/src/modules/migration/BaseMigrationMixin.sol";
import { NegRiskMigrationErrors } from "@polymarket-v2/src/modules/migration/NegRiskMigrationMixin.sol";
import { NegRiskModule, NegRiskModuleEvents } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ModuleProxyLib } from "@polymarket-v2/src/modules/dev/ModuleProxyLib.sol";
import { ConditionId, ConditionIdLib, EventId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import {
    Collateral,
    Positions,
    PositionManagerSetup,
    Legacy
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { Router } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

contract NegRiskMigrationTest is TestHelper, NegRiskModuleEvents {
    event EventPrepared(EventId indexed eventId, uint256 conditionCount, bytes32 legacyEventId);

    Positions positions;
    Collateral collateral;
    Legacy legacy;

    bytes32 negRiskMarketId;

    Router router;

    function setUp() public virtual {
        (positions, collateral, legacy) = PositionManagerSetup._deploy(owner, admin, creator);

        router = RouterSetup.deployRouter(address(positions.manager), owner);

        vm.prank(alice);
        legacy.conditionalTokens.setApprovalForAll(address(positions.negRiskModule), true);

        vm.prank(brian);
        legacy.conditionalTokens.setApprovalForAll(address(positions.negRiskModule), true);
    }

    function _before(uint256 _questionCount, uint256 _amount) internal {
        bytes memory data = new bytes(0);

        // prepare market
        vm.prank(oracle);
        negRiskMarketId = legacy.negRiskAdapter.prepareMarket(0, data);

        uint8 i = 0;

        // prepare questions and split initial liquidity to alice
        while (i < _questionCount) {
            vm.prank(oracle);
            bytes32 questionId = legacy.negRiskAdapter.prepareQuestion(negRiskMarketId, data);
            bytes32 conditionId = legacy.negRiskAdapter.getConditionId(questionId);

            // // split position to alice
            vm.startPrank(alice);
            collateral.usdce.mint(alice, _amount);
            collateral.usdce.approve(address(legacy.negRiskAdapter), _amount);
            legacy.negRiskAdapter.splitPosition(conditionId, _amount);
            vm.stopPrank();

            ++i;
        }

        assertEq(legacy.negRiskAdapter.getQuestionCount(negRiskMarketId), _questionCount);

        // send no positions to brian
        {
            i = 0;

            while (i < _questionCount) {
                uint256 positionId =
                    legacy.negRiskAdapter.getPositionId(NegRiskIdLib.getQuestionId(negRiskMarketId, i), false);
                legacy.conditionalTokens.balanceOf(alice, positionId);
                vm.prank(alice);
                legacy.conditionalTokens.safeTransferFrom(alice, brian, positionId, _amount, "");
                assertEq(legacy.conditionalTokens.balanceOf(brian, positionId), _amount);

                ++i;
            }
        }
    }

    function _structuredEventId(uint256 _questionCount) internal view returns (bytes32) {
        return EventId.unwrap(EventIdLib.encode(ModuleIds.NEGRISK, negRiskMarketId, _questionCount));
    }

    function _structuredConditionId(uint256 _questionCount, uint256 _conditionIndex) internal view returns (bytes32) {
        return ConditionId.unwrap(
            EventIdLib.computeConditionId(EventId.wrap(bytes29(_structuredEventId(_questionCount))), _conditionIndex)
        );
    }

    function _event(bytes32 _eventId) internal pure returns (EventId) {
        return EventId.wrap(bytes29(_eventId));
    }

    function _conditionsResolved(bytes32 _eventId) internal view returns (uint256) {
        return positions.negRiskModule.conditionsResolved(_event(_eventId));
    }

    function _resultsSum(bytes32 _eventId) internal view returns (uint256) {
        return positions.negRiskModule.resultsSum(_event(_eventId));
    }

    function _wrapAndHorizontalRoundTrip(address _user, EventId _eventId, uint256 _amount) internal {
        vm.startPrank(_user);
        collateral.usdce.mint(_user, _amount);
        collateral.usdce.approve(address(collateral.onramp), _amount);
        collateral.onramp.wrap(address(collateral.usdce), _user, _amount);
        collateral.token.approve(address(router), _amount);
        router.horizontalSplit(_eventId, _amount);
        positions.manager.setApprovalForAll(address(router), true);
        router.horizontalMerge(_eventId, _amount);
        vm.stopPrank();
        assertEq(collateral.token.balanceOf(_user), _amount);
    }
}

/*--------------------------------------------------------------
                            VIEW
--------------------------------------------------------------*/

contract NegRiskMigrationTest_view is NegRiskMigrationTest {
    function test_positionIds(bytes32 _eventId, uint8 _conditionIndex, bool _outcome) public view {
        // Get structured conditionId and positionId
        ConditionId structuredConditionId = ConditionIdLib.encode(ModuleIds.NEGRISK, _eventId, 0, _conditionIndex);
        uint256 structuredPositionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(structuredConditionId, _outcome ? 0 : 1));

        // Verify position ID has correct moduleId (migration uses NEGRISK)
        uint256 extractedModuleId = PositionId.wrap(structuredPositionId).moduleId();
        assertEq(extractedModuleId, ModuleIds.NEGRISK);

        // Verify positionId is correctly derived from conditionId
        uint256 expectedPositionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(structuredConditionId, _outcome ? 0 : 1));
        assertEq(structuredPositionId, expectedPositionId);
    }

    function test_getConditionId(bytes32 _eventId, uint8 _conditionIndex) public view {
        // Get structured conditionId from migration flow
        bytes32 structuredConditionId =
            ConditionId.unwrap(ConditionIdLib.encode(ModuleIds.NEGRISK, _eventId, 0, _conditionIndex));

        // Verify moduleId is NEGRISK
        uint256 extractedModuleId = PositionId.wrap(uint256(structuredConditionId)).moduleId();
        assertEq(extractedModuleId, ModuleIds.NEGRISK);

        // Verify legacy conditionId can be derived from event + index
        bytes32 negRiskAdapterQuestionId = NegRiskIdLib.getQuestionId(_eventId, _conditionIndex);
        bytes32 expectedLegacyConditionId =
            CTHelpers.getConditionId(address(legacy.negRiskAdapter), negRiskAdapterQuestionId, 2);
        assertTrue(expectedLegacyConditionId != bytes32(0));
    }
}

/*--------------------------------------------------------------
                      MIGRATE POSITIONS
--------------------------------------------------------------*/

contract NegRiskMigrationTest_migrate is NegRiskMigrationTest {
    function test_migrate() public {
        _before(64, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        // Get structured conditionId from migration flow
        bytes32 structuredConditionId = _structuredConditionId(64, 0);

        // Get legacy position IDs for balance checks
        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 legacyConditionId = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId, 2);
        uint256 legacyPositionId0 = CTHelpers.getPositionId(
            address(legacy.wrappedCollateral), CTHelpers.getCollectionId(bytes32(0), legacyConditionId, 1)
        );
        uint256 legacyPositionId1 = CTHelpers.getPositionId(
            address(legacy.wrappedCollateral), CTHelpers.getCollectionId(bytes32(0), legacyConditionId, 2)
        );
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionId0), 100_000_000);
        assertEq(legacy.conditionalTokens.balanceOf(brian, legacyPositionId1), 100_000_000);

        // Use legacy condition IDs for migration
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;
        vm.prank(alice);

        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionId0), 0);
        assertEq(legacy.conditionalTokens.balanceOf(address(positions.negRiskModule), legacyPositionId0), 100_000_000);

        vm.prank(brian);
        outcomeIndices[0] = 1;
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(legacy.conditionalTokens.balanceOf(brian, legacyPositionId1), 0);
        assertEq(legacy.conditionalTokens.balanceOf(address(positions.negRiskModule), legacyPositionId1), 0);

        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 100_000_000);
    }

    function test_revert_invalidArrayLength() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        // Mismatched array lengths
        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 legacyConditionId = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId, 2);
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](2); // Wrong length
        amounts[0] = 100_000_000;
        amounts[1] = 100_000_000;

        vm.prank(alice);
        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_conditionNotPrepared() public {
        _before(4, 100_000_000);
        // Don't call prepareMigrationEvent

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 legacyConditionId = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId, 2);

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(alice);
        vm.expectRevert(MigrationErrors.MigrationNotRegistered.selector);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }

    function test_revert_amountsLengthMismatch() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 legacyConditionId = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId, 2);

        // legacyConditionIds.length != amounts.length
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](2); // Wrong length
        amounts[0] = 100_000_000;
        amounts[1] = 100_000_000;

        vm.prank(alice);
        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
    }
}

/*--------------------------------------------------------------
                    PREPARE EVENT
--------------------------------------------------------------*/

contract NegRiskMigrationTest_prepareEvent is NegRiskMigrationTest {
    function test_prepareMigrationEvent_emitsLegacyEventIdInEventPrepared() public {
        _before(4, 100_000_000);

        bytes32 structuredEventId = _structuredEventId(4);

        vm.expectEmit(true, true, true, true, address(positions.negRiskModule));
        emit EventPrepared(EventIdLib.from(structuredEventId), 4, negRiskMarketId);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);
    }

    function test_revert_eventNotPrepared() public {
        bytes32 fakeEventId = "fakeEvent";

        vm.expectRevert(ModuleErrors.EventNotPrepared.selector);
        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(fakeEventId);
    }

    function test_revert_migrationNotSupported() public {
        NegRiskModule noLegacyModule = ModuleProxyLib.deployNegRiskModule(
            address(positions.manager), owner, admin, address(0), address(0), address(0)
        );

        vm.prank(admin);
        noLegacyModule.addCreator(creator);

        vm.expectRevert(ModuleErrors.MigrationNotSupported.selector);
        vm.prank(creator);
        noLegacyModule.prepareMigrationEvent("someEvent");
    }

    function test_revert_alreadyPrepared() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        vm.expectRevert(ModuleErrors.EventAlreadyPrepared.selector);
        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);
    }

    function test_maxLegacyConditionCount() public {
        bytes32 fakeEventId = bytes32(uint256(0xAA));

        // Mock getQuestionCount to return the maximum safe legacy count (256).
        // Indices 0..255 all fit in the uint8 cast inside getLegacyConditionIdFromEvent.
        vm.mockCall(
            address(legacy.negRiskAdapter),
            abi.encodeWithSelector(INegRiskAdapter.getQuestionCount.selector, fakeEventId),
            abi.encode(uint256(256))
        );

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(fakeEventId);

        EventId expectedEventId = EventIdLib.encode(ModuleIds.NEGRISK, fakeEventId, 256);
        assertEq(positions.negRiskModule.legacyEventId(expectedEventId), fakeEventId);
    }

    function test_revert_legacyConditionCountTooLarge() public {
        bytes32 fakeEventId = bytes32(uint256(0xBB));

        // Mock getQuestionCount to return 257 (one above the safe uint8 boundary).
        vm.mockCall(
            address(legacy.negRiskAdapter),
            abi.encodeWithSelector(INegRiskAdapter.getQuestionCount.selector, fakeEventId),
            abi.encode(uint256(257))
        );

        vm.expectRevert(NegRiskMigrationErrors.LegacyConditionCountTooLarge.selector);
        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(fakeEventId);
    }

    function test_revert_insufficientConditionCount() public {
        bytes32 fakeEventId = bytes32(uint256(0xCC));

        // Mock getQuestionCount to return 1 (single-question legacy market).
        // V2 neg-risk events require at least 2 conditions to avoid unbacked
        // PMCT issuance via horizontal merge.
        vm.mockCall(
            address(legacy.negRiskAdapter),
            abi.encodeWithSelector(INegRiskAdapter.getQuestionCount.selector, fakeEventId),
            abi.encode(uint256(1))
        );

        vm.expectRevert(NegRiskMigrationErrors.InsufficientConditionCount.selector);
        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(fakeEventId);
    }

    function test_minLegacyConditionCount() public {
        bytes32 fakeEventId = bytes32(uint256(0xDD));

        // Mock getQuestionCount to return 2 (the minimum valid count).
        vm.mockCall(
            address(legacy.negRiskAdapter),
            abi.encodeWithSelector(INegRiskAdapter.getQuestionCount.selector, fakeEventId),
            abi.encode(uint256(2))
        );

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(fakeEventId);

        EventId expectedEventId = EventIdLib.encode(ModuleIds.NEGRISK, fakeEventId, 2);
        assertEq(positions.negRiskModule.legacyEventId(expectedEventId), fakeEventId);
    }
}

/*--------------------------------------------------------------
                RESOLVE MIGRATION CONDITION
--------------------------------------------------------------*/

contract NegRiskMigrationTest_resolveMigrationCondition is NegRiskMigrationTest {
    function test_resolveMigrationCondition() public {
        _before(64, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 conditionId = _structuredConditionId(64, 0);
        bytes32 legacyConditionId = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId, 2);

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(alice);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        assertEq(positions.manager.balanceOf(alice, ConditionIdLib.from(conditionId), 0), 100_000_000);

        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(questionId, true);
        positions.negRiskModule.resolveMigrationCondition(conditionId);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        router.redeem(ConditionIdLib.from(conditionId), 0, 100_000_000);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 100_000_000);
        assertEq(collateral.token.balanceOf(address(positions.negRiskModule)), 0);
    }

    function test_resolveMigrationCondition_alreadyResolvedNoop() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 conditionId = _structuredConditionId(4, 0);
        bytes32 legacyConditionId = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId, 2);

        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000_000;

        vm.prank(alice);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        // Resolve the condition
        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(questionId, true);
        positions.negRiskModule.resolveMigrationCondition(conditionId);

        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 100_000_000);

        // Try to resolve again. The result is unchanged, and any residual sweep is a no-op.
        positions.negRiskModule.resolveMigrationCondition(conditionId);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 100_000_000);
    }

    function test_revert_nonMigratedCondition() public {
        // Prepare a normal (non-migration) event, then try to resolve via migration path
        _before(4, 100_000_000);
        EventId eventId = positions.negRiskModule.getEventId(4, "abc");

        bytes32 conditionId = ConditionId.unwrap(EventIdLib.computeConditionId(eventId, 0));

        // getLegacyConditionId returns bytes32(0) for non-migrated events,
        // causing payoutNumerators on an invalid conditionId to revert
        vm.expectRevert();
        positions.negRiskModule.resolveMigrationCondition(conditionId);
    }

    function test_revert_notResolvedOnLegacy() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 conditionId = _structuredConditionId(4, 0);

        // Don't resolve on legacy - try to resolve directly
        vm.expectRevert(ModuleErrors.ConditionNotResolved.selector);
        positions.negRiskModule.resolveMigrationCondition(conditionId);
    }

    function test_revert_resolutionPaused() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 conditionId = _structuredConditionId(4, 0);

        // Resolve on the legacy adapter so payoutDenominator > 0
        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(questionId, true);

        // Admin pauses resolution for this structured event
        vm.prank(admin);
        positions.negRiskModule.pauseResolution(ConditionIdLib.from(conditionId).eventId());

        vm.expectRevert(OracleModuleErrors.ResolutionIsPaused.selector);
        positions.negRiskModule.resolveMigrationCondition(conditionId);
    }

    function test_unpauseAllowsResolution() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 conditionId = _structuredConditionId(4, 0);

        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(questionId, true);

        vm.prank(admin);
        positions.negRiskModule.pauseResolution(ConditionIdLib.from(conditionId).eventId());

        vm.expectRevert(OracleModuleErrors.ResolutionIsPaused.selector);
        positions.negRiskModule.resolveMigrationCondition(conditionId);

        vm.prank(admin);
        positions.negRiskModule.unpauseResolution(ConditionIdLib.from(conditionId).eventId());

        positions.negRiskModule.resolveMigrationCondition(conditionId);

        bytes32 eventId = _structuredEventId(4);
        assertEq(_conditionsResolved(eventId), 1);
        assertEq(_resultsSum(eventId), 1_000_000);
    }
}

/*--------------------------------------------------------------
            RESOLVE MIGRATION CONDITION AGGREGATES
--------------------------------------------------------------*/

contract NegRiskMigrationTest_resolveMigrationCounters is NegRiskMigrationTest {
    function test_countersUpdateOnYes() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 conditionId = _structuredConditionId(4, 0);
        bytes32 eventId = _structuredEventId(4);

        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(questionId, true);

        assertEq(_conditionsResolved(eventId), 0);
        assertEq(_resultsSum(eventId), 0);

        positions.negRiskModule.resolveMigrationCondition(conditionId);

        assertEq(_conditionsResolved(eventId), 1);
        assertEq(_resultsSum(eventId), 1_000_000);
    }

    function test_countersUpdateOnNo() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 questionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 conditionId = _structuredConditionId(4, 0);
        bytes32 eventId = _structuredEventId(4);

        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(questionId, false);

        positions.negRiskModule.resolveMigrationCondition(conditionId);

        assertEq(_conditionsResolved(eventId), 1);
        assertEq(_resultsSum(eventId), 0);
    }

    /// @notice Circuit breaker: if legacy ever reports two YES outcomes within a single
    ///         event (e.g. a buggy adapter redeploy), the second migration resolve must
    ///         revert instead of letting the vault drain. We force the scenario with
    ///         vm.mockCall because the honest legacy flow is guarded by MarketAlreadyDetermined.
    function test_revert_twoYesLegacyResolves() public {
        _before(4, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        // First YES resolution proceeds honestly
        bytes32 questionId0 = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 conditionId0 = _structuredConditionId(4, 0);
        bytes32 eventId = _structuredEventId(4);

        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(questionId0, true);
        positions.negRiskModule.resolveMigrationCondition(conditionId0);
        assertEq(_resultsSum(eventId), 1_000_000);

        // Simulate a second YES on a different condition of the same event by mocking
        // payoutNumerators on the legacy CTF. Honest legacy prevents this via the
        // MarketAlreadyDetermined guard inside reportOutcome.
        bytes32 questionId1 = NegRiskIdLib.getQuestionId(negRiskMarketId, 1);
        bytes32 legacyConditionId1 = CTHelpers.getConditionId(address(legacy.negRiskAdapter), questionId1, 2);
        bytes32 conditionId1 = _structuredConditionId(4, 1);

        vm.mockCall(
            address(legacy.conditionalTokens),
            abi.encodeWithSelector(IConditionalTokens.payoutNumerators.selector, legacyConditionId1, uint256(0)),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(legacy.conditionalTokens),
            abi.encodeWithSelector(IConditionalTokens.payoutNumerators.selector, legacyConditionId1, uint256(1)),
            abi.encode(uint256(0))
        );

        vm.expectRevert(ModuleErrors.InvalidResults.selector);
        positions.negRiskModule.resolveMigrationCondition(conditionId1);
    }

    /// @notice A second YES is rejected on migration resolve. Resolve 2 of 3 conditions as
    ///         YES+NO, then try to resolve the third as YES via migration.
    function test_revert_lastConditionMustBeNo() public {
        _before(3, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 q0 = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(negRiskMarketId, 1);
        bytes32 q2 = NegRiskIdLib.getQuestionId(negRiskMarketId, 2);

        bytes32 c0 = _structuredConditionId(3, 0);
        bytes32 c1 = _structuredConditionId(3, 1);
        bytes32 c2 = _structuredConditionId(3, 2);

        // YES then NO on legacy
        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(q0, true);
        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(q1, false);

        positions.negRiskModule.resolveMigrationCondition(c0);
        positions.negRiskModule.resolveMigrationCondition(c1);

        bytes32 eventId = _structuredEventId(3);
        assertEq(_resultsSum(eventId), 1_000_000);
        assertEq(_conditionsResolved(eventId), 2);

        // Mock the third condition to report YES — adding another 1e6 of YES on top of the
        // existing 1e6 is invalid.
        bytes32 legacyConditionId2 = CTHelpers.getConditionId(address(legacy.negRiskAdapter), q2, 2);
        vm.mockCall(
            address(legacy.conditionalTokens),
            abi.encodeWithSelector(IConditionalTokens.payoutNumerators.selector, legacyConditionId2, uint256(0)),
            abi.encode(uint256(1))
        );
        vm.mockCall(
            address(legacy.conditionalTokens),
            abi.encodeWithSelector(IConditionalTokens.payoutNumerators.selector, legacyConditionId2, uint256(1)),
            abi.encode(uint256(0))
        );

        vm.expectRevert(ModuleErrors.InvalidResults.selector);
        positions.negRiskModule.resolveMigrationCondition(c2);
    }

    /// @notice Once migration resolves a YES outcome, migrated loser conditions still resolve
    ///         through the legacy CTF so redemption is not skipped.
    function test_migrationThenResolveLosers() public {
        _before(3, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 q0 = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(negRiskMarketId, 1);
        bytes32 q2 = NegRiskIdLib.getQuestionId(negRiskMarketId, 2);
        bytes32 c0 = _structuredConditionId(3, 0);
        bytes32 c1 = _structuredConditionId(3, 1);
        bytes32 c2 = _structuredConditionId(3, 2);

        vm.startPrank(oracle);
        legacy.negRiskAdapter.reportOutcome(q0, true);
        legacy.negRiskAdapter.reportOutcome(q1, false);
        legacy.negRiskAdapter.reportOutcome(q2, false);
        vm.stopPrank();

        positions.negRiskModule.resolveMigrationCondition(c0);

        bytes32 eventId = _structuredEventId(3);
        assertEq(_resultsSum(eventId), 1_000_000);

        positions.negRiskModule.resolveMigrationCondition(c1);
        positions.negRiskModule.resolveMigrationCondition(c2);

        assertEq(_conditionsResolved(eventId), 3);
    }

    function test_revert_resolveMigrationCondition_syntheticOther() public {
        _before(3, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 conditionId = _structuredConditionId(3, 3);

        vm.expectRevert(MigrationErrors.MigrationNotRegistered.selector);
        positions.negRiskModule.resolveMigrationCondition(conditionId);
    }

    /// @notice Every real condition resolves to NO on legacy. The last resolve auto-derives
    ///         the synthetic Other condition.
    function test_finalizeMigration_allNo() public {
        _before(3, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 q0 = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(negRiskMarketId, 1);
        bytes32 q2 = NegRiskIdLib.getQuestionId(negRiskMarketId, 2);
        bytes32 c0 = _structuredConditionId(3, 0);
        bytes32 c1 = _structuredConditionId(3, 1);
        bytes32 c2 = _structuredConditionId(3, 2);

        vm.startPrank(oracle);
        legacy.negRiskAdapter.reportOutcome(q0, false);
        legacy.negRiskAdapter.reportOutcome(q1, false);
        legacy.negRiskAdapter.reportOutcome(q2, false);
        vm.stopPrank();

        positions.negRiskModule.resolveMigrationCondition(c0);
        positions.negRiskModule.resolveMigrationCondition(c1);

        bytes32 eventId = _structuredEventId(3);
        ConditionId otherId = ConditionIdLib.from(_structuredConditionId(3, 3));
        vm.expectEmit(true, true, false, false, address(positions.negRiskModule));
        emit SyntheticConditionDerivableAsYes(_event(eventId), otherId);
        positions.negRiskModule.resolveMigrationCondition(c2);

        uint256[] memory otherResult = positions.negRiskModule.getResult(otherId);
        assertEq(otherResult[0], 1_000_000);
        assertEq(otherResult[1], 0);
        assertEq(_conditionsResolved(eventId), 3);
        assertEq(_resultsSum(eventId), 0);
    }
}

/*--------------------------------------------------------------
            RESOLVE MIGRATION CONDITION SIDE EFFECTS
    --------------------------------------------------------------*/

/// @notice Migrated NegRisk losers must resolve through legacy CTF payouts so the module's
///         legacy positions are redeemed and the vault is settled. Without this, asymmetric
///         migrations (a user migrates a loser-side NO without anyone migrating the matching
///         YES) leave wcol locked in the legacy CTF and the vault undercollateralized for v2
///         NO holders.
contract NegRiskMigrationTest_resolveMigrationCondition_sideEffects is NegRiskMigrationTest {
    function test_revert_resolveMigrationCondition_migratedLoser_legacyUnresolved() public {
        _before(3, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 q0 = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 c0 = _structuredConditionId(3, 0);
        bytes32 c1 = _structuredConditionId(3, 1);

        // Oracle reports only the winner — loser q1 stays unresolved on legacy CTF.
        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(q0, true);
        positions.negRiskModule.resolveMigrationCondition(c0);

        // Routing through _resolveMigrationCondition reads legacy payoutNumerators for c1
        // and reverts because the loser was never reported on legacy.
        vm.expectRevert(ModuleErrors.ConditionNotResolved.selector);
        positions.negRiskModule.resolveMigrationCondition(c1);
    }

    function test_resolveMigrationCondition_migratedLoser_redeemsLegacy() public {
        uint256 amount = 100_000_000;
        _before(3, amount);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 q0 = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 q1 = NegRiskIdLib.getQuestionId(negRiskMarketId, 1);
        bytes32 q2 = NegRiskIdLib.getQuestionId(negRiskMarketId, 2);
        bytes32 c0 = _structuredConditionId(3, 0);
        bytes32 c1 = _structuredConditionId(3, 1);
        bytes32 c2 = _structuredConditionId(3, 2);

        // Asymmetric migration: brian migrates only NO_1 (loser side). Alice's matching
        // YES_1 stays in legacy CTF, so no complementary merge happens — the module ends
        // up holding `amount` legacy NO_1 with the vault uncredited.
        bytes32 legacyConditionId1 = CTHelpers.getConditionId(address(legacy.negRiskAdapter), q1, 2);
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId1;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(brian);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);

        uint256 legacyNo1PositionId = CTHelpers.getPositionId(
            address(legacy.wrappedCollateral), CTHelpers.getCollectionId(bytes32(0), legacyConditionId1, 2)
        );
        assertEq(
            legacy.conditionalTokens.balanceOf(address(positions.negRiskModule), legacyNo1PositionId),
            amount,
            "module should hold unmatched legacy NO_1"
        );
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 0, "vault uncredited before resolution");

        // Oracle reports winner + both losers on legacy.
        vm.startPrank(oracle);
        legacy.negRiskAdapter.reportOutcome(q0, true);
        legacy.negRiskAdapter.reportOutcome(q1, false);
        legacy.negRiskAdapter.reportOutcome(q2, false);
        vm.stopPrank();

        // Winner first — bumps resultsSum to RESULT_DENOMINATOR.
        positions.negRiskModule.resolveMigrationCondition(c0);
        bytes32 eventId = _structuredEventId(3);
        assertEq(_resultsSum(eventId), 1_000_000);

        // Resolving the migrated loser redeems the module's legacy NO_1 holdings and credits the vault.
        positions.negRiskModule.resolveMigrationCondition(c1);

        assertEq(
            legacy.conditionalTokens.balanceOf(address(positions.negRiskModule), legacyNo1PositionId),
            0,
            "module legacy NO_1 redeemed"
        );
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount, "vault credited by redemption");

        uint256[] memory storedResult = positions.negRiskModule.getResult(ConditionIdLib.from(c1));
        assertEq(storedResult.length, 2);
        assertEq(storedResult[0], 0);
        assertEq(storedResult[1], 1_000_000);

        // c2 also routes through migration; module holds 0 for c2 so redemption is a no-op
        // but the v2 result is still stored, completing the event.
        positions.negRiskModule.resolveMigrationCondition(c2);
        assertEq(_conditionsResolved(eventId), 3);
        assertEq(
            collateral.usdce.balanceOf(address(collateral.vault)),
            amount,
            "vault unchanged when module holds no legacy positions for the condition"
        );
    }

    function test_reportResult_migrationConditionSettlesCollateralToVault() public {
        uint256 amount = 100_000_000;
        _before(3, amount);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 q1 = NegRiskIdLib.getQuestionId(negRiskMarketId, 1);
        bytes32 c1 = _structuredConditionId(3, 1);

        bytes32 legacyConditionId1 = CTHelpers.getConditionId(address(legacy.negRiskAdapter), q1, 2);
        bytes32[] memory legacyConditionIds = new bytes32[](1);
        legacyConditionIds[0] = legacyConditionId1;
        uint256[] memory outcomeIndices = new uint256[](1);
        outcomeIndices[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(brian);
        positions.negRiskModule.migratePositions(legacyConditionIds, outcomeIndices, amounts);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 0);

        uint256[] memory result = new uint256[](2);
        result[1] = 1_000_000;

        vm.prank(admin);
        positions.negRiskModule.addResolver(oracle);
        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.MigrationNotSupported.selector);
        positions.negRiskModule.reportResult(ConditionIdLib.from(c1), result);

        vm.prank(admin);
        positions.negRiskModule.addBridge(devin);
        vm.prank(devin);
        vm.expectRevert(ModuleErrors.ConditionNotResolved.selector);
        positions.negRiskModule.reportResult(ConditionIdLib.from(c1), result);

        uint256 legacyNo1PositionId = CTHelpers.getPositionId(
            address(legacy.wrappedCollateral), CTHelpers.getCollectionId(bytes32(0), legacyConditionId1, 2)
        );
        assertEq(legacy.conditionalTokens.balanceOf(address(positions.negRiskModule), legacyNo1PositionId), amount);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 0);

        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(q1, false);

        uint256[] memory mismatch = new uint256[](2);
        mismatch[0] = 1_000_000;
        vm.prank(devin);
        vm.expectRevert(ModuleErrors.ExistingPayoutMismatch.selector);
        positions.negRiskModule.reportResult(ConditionIdLib.from(c1), mismatch);

        bytes32 eventId = _structuredEventId(3);
        assertEq(positions.negRiskModule.getResult(ConditionIdLib.from(c1)).length, 0);
        assertEq(_conditionsResolved(eventId), 0);
        assertEq(_resultsSum(eventId), 0);
        assertEq(legacy.conditionalTokens.balanceOf(address(positions.negRiskModule), legacyNo1PositionId), amount);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), 0);

        vm.prank(devin);
        positions.negRiskModule.reportResult(ConditionIdLib.from(c1), result);

        uint256[] memory storedResult = positions.negRiskModule.getResult(ConditionIdLib.from(c1));
        assertEq(storedResult[1], 1_000_000);
        assertEq(_conditionsResolved(eventId), 1);
        assertEq(legacy.conditionalTokens.balanceOf(address(positions.negRiskModule), legacyNo1PositionId), 0);
        assertEq(collateral.usdce.balanceOf(address(collateral.vault)), amount);
    }
}

/*--------------------------------------------------------------
                     HORIZONTAL SPLIT
--------------------------------------------------------------*/

contract NegRiskMigrationTest_horizontalSplit is NegRiskMigrationTest {
    function test_horizontalSplit() public {
        _before(64, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        // Derive structured eventId from legacy hash for horizontalSplit
        bytes32 structuredEventId = _structuredEventId(64);

        vm.startPrank(carly);
        collateral.usdce.mint(carly, 100_000_000);
        collateral.usdce.approve(address(collateral.onramp), 100_000_000);
        collateral.onramp.wrap(address(collateral.usdce), carly, 100_000_000);
        collateral.token.approve(address(router), 100_000_000);
        router.horizontalSplit(EventIdLib.from(structuredEventId), 100_000_000);
        vm.stopPrank();

        for (uint256 i = 0; i < 64; i++) {
            bytes32 conditionId = _structuredConditionId(64, i);
            uint256 yesPositionId =
                PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));

            assertEq(positions.manager.balanceOf(carly, yesPositionId), 100_000_000);
        }

        assertEq(collateral.token.balanceOf(carly), 0);
    }
}

/*--------------------------------------------------------------
                     HORIZONTAL MERGE
--------------------------------------------------------------*/

contract NegRiskMigrationTest_horizontalMerge is NegRiskMigrationTest {
    function test_horizontalMerge() public {
        _before(64, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        // Derive structured eventId from legacy hash for horizontalSplit/Merge
        bytes32 structuredEventId = _structuredEventId(64);

        vm.startPrank(carly);
        collateral.usdce.mint(carly, 100_000_000);
        collateral.usdce.approve(address(collateral.onramp), 100_000_000);
        collateral.onramp.wrap(address(collateral.usdce), carly, 100_000_000);
        collateral.token.approve(address(router), 100_000_000);
        router.horizontalSplit(EventIdLib.from(structuredEventId), 100_000_000);
        vm.stopPrank();

        // Verify carly has yes positions
        for (uint256 i = 0; i < 64; i++) {
            bytes32 conditionId = _structuredConditionId(64, i);
            uint256 yesPositionId =
                PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));
            assertEq(positions.manager.balanceOf(carly, yesPositionId), 100_000_000);
        }

        // Resolve a YES on legacy and propagate to v2, then merge back.
        bytes32 winningQuestionId = NegRiskIdLib.getQuestionId(negRiskMarketId, 0);
        bytes32 winningConditionId = _structuredConditionId(64, 0);
        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(winningQuestionId, true);
        positions.negRiskModule.resolveMigrationCondition(winningConditionId);

        // Now merge back
        vm.startPrank(carly);
        positions.manager.setApprovalForAll(address(router), true);
        router.horizontalMerge(EventIdLib.from(structuredEventId), 100_000_000);
        vm.stopPrank();

        // Verify positions are gone and collateral returned
        for (uint256 i = 0; i < 64; i++) {
            bytes32 conditionId = _structuredConditionId(64, i);
            uint256 yesPositionId =
                PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));
            assertEq(positions.manager.balanceOf(carly, yesPositionId), 0);
        }

        assertEq(collateral.token.balanceOf(carly), 100_000_000);
    }

    function test_horizontalMerge_beforeResolution() public {
        _before(2, 100_000_000);
        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);
        _wrapAndHorizontalRoundTrip(carly, _event(_structuredEventId(2)), 100_000_000);
    }

    function test_horizontalMerge_nonMigratedEvent() public {
        _wrapAndHorizontalRoundTrip(carly, positions.negRiskModule.getEventId(2, "non-migrated"), 100_000_000);
    }
}

/*--------------------------------------------------------------
        ALIAS-KEY REGRESSION (audit finding #6)
--------------------------------------------------------------*/

/// @notice Reproduces the alias-key attack described in the resolveMigrationCondition audit
///         finding. The structured ConditionId UDVT now reverts on any input whose outcome
///         byte is non-zero, blocking the exploit at the entry point before any state is
///         observed.
contract NegRiskMigrationTest_aliasKeyRegression is NegRiskMigrationTest {
    function test_revert_resolveMigrationCondition_aliasOutcomeByte() public {
        _before(2, 100_000_000);

        vm.prank(creator);
        positions.negRiskModule.prepareMigrationEvent(negRiskMarketId);

        bytes32 conditionId = _structuredConditionId(2, 0);
        bytes32 aliasKey = bytes32(uint256(conditionId) | 1);

        vm.expectRevert(abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, aliasKey));
        positions.negRiskModule.resolveMigrationCondition(aliasKey);
    }
}

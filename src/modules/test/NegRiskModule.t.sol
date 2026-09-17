// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";
import { Ownable } from "@solady/src/auth/Ownable.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { Vm } from "lib/forge-std/src/Vm.sol";

import { ConditionId, EventId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { Router } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { OracleModuleErrors } from "@polymarket-v2/src/modules/abstract/OracleModule.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { NegRiskModule, NegRiskModuleEvents } from "@polymarket-v2/src/modules/NegRiskModule.sol";

import { BaseModuleTest } from "./BaseModule.t.sol";

contract NegRiskModuleTest is BaseModuleTest, NegRiskModuleEvents {
    bytes32 internal constant SYNTHETIC_CONDITION_DERIVABLE_AS_YES_TOPIC =
        keccak256("SyntheticConditionDerivableAsYes(bytes29,bytes31)");

    Router router;

    uint256 internal _eventCounter;
    bytes32 internal _lastUnpreparedEventId;

    function setUp() public virtual override {
        super.setUp();

        router = RouterSetup.deployRouter(address(positions.manager), owner);

        vm.startPrank(admin);
        positions.negRiskModule.addCreator(creator);
        positions.negRiskModule.addResolver(oracle);
        vm.stopPrank();
    }

    /*--------------------------------------------------------------
                        VIRTUAL IMPLEMENTATIONS
    --------------------------------------------------------------*/

    function _module() internal view override returns (BaseModule) {
        return BaseModule(address(positions.negRiskModule));
    }

    function _getEventId(uint256 _conditionCount, bytes memory _data) internal view returns (bytes32) {
        return EventId.unwrap(positions.negRiskModule.getEventId(_conditionCount, _data));
    }

    /// @dev Test helper: derive a raw bytes32 condition ID from a raw bytes32 event ID.
    function _conditionFromEvent(bytes32 _eventId, uint256 _conditionIndex) internal pure returns (bytes32) {
        return ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(_eventId)), _conditionIndex));
    }

    function _prepareCondition() internal override returns (bytes32 conditionId) {
        bytes32 eventId = _getEventId(2, abi.encodePacked("event_", block.timestamp, _eventCounter++));
        conditionId = _conditionFromEvent(eventId, 0);
    }

    function _getBridgeConditionId() internal override returns (bytes32) {
        _lastUnpreparedEventId = _getEventId(2, abi.encodePacked("bridge_event_", block.timestamp, _eventCounter++));
        return _conditionFromEvent(_lastUnpreparedEventId, 0);
    }

    function _reportResultFromBridge(bytes32 _conditionId, uint256[] memory _result) internal override {
        vm.prank(bridge);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionId), _result);
    }

    function _reportResult(bytes32 _conditionId) internal override {
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000; // YES wins
        result[1] = 0;

        vm.prank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionId), result);
    }

    function _reportPartialResult(bytes32 _conditionId) internal override {
        uint256[] memory result = new uint256[](2);
        result[0] = 500_000; // 50/50 split
        result[1] = 500_000;

        vm.prank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionId), result);
    }

    function _redeem(address _user, bytes32 _conditionId, uint256 _outcomeIndex, uint256 _amount) internal override {
        vm.startPrank(_user);
        positions.manager.setApprovalForAll(address(router), true);
        router.redeem(ConditionIdLib.from(_conditionId), _outcomeIndex, _amount);
        vm.stopPrank();
    }

    function _yesPositionId(bytes32 _eventId, uint256 _index) internal pure returns (uint256) {
        return PositionId.unwrap(
            ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(_conditionFromEvent(_eventId, _index))), 0)
        );
    }

    function _horizontalLegCount(bytes32 _eventId) internal view returns (uint256) {
        return positions.negRiskModule.conditionCount(EventIdLib.from(_eventId)) + 1;
    }

    function _fundAndHorizontalSplit(address _user, bytes32 _eventId, uint256 _amount) internal {
        collateral.usdc.mint(_user, _amount);
        vm.startPrank(_user);
        collateral.usdc.approve(address(collateral.onramp), _amount);
        collateral.onramp.wrap(address(collateral.usdc), _user, _amount);
        collateral.token.approve(address(router), _amount);
        router.horizontalSplit(EventIdLib.from(_eventId), _amount);
        vm.stopPrank();
    }

    function _syntheticYesDerivableLogCount(Vm.Log[] memory _logs) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < _logs.length; ++i) {
            if (_logs[i].topics.length > 0 && _logs[i].topics[0] == SYNTHETIC_CONDITION_DERIVABLE_AS_YES_TOPIC) {
                ++count;
            }
        }
    }
}

/*--------------------------------------------------------------
                            BRIDGE
--------------------------------------------------------------*/

contract NegRiskModuleTest_bridge is NegRiskModuleTest {
    function test_mintFromBridge() public {
        _assert_mintFromBridge();
    }

    function test_mintFromBridge_zeroAmount() public {
        _assert_mintFromBridge_zeroAmount();
    }

    function test_revert_mintFromBridge_unauthorized() public {
        _assert_revert_mintFromBridge_unauthorized();
    }

    function test_mintFromBridge_thenRedeem() public {
        _assert_mintFromBridge_thenRedeem();
    }

    function test_burnFromBridge() public {
        _assert_burnFromBridge();
    }

    function test_onERC1155Received_normalTransfer() public {
        _assert_onERC1155Received_normalTransfer();
    }

    function test_burnFromBridge_batch() public {
        _assert_burnFromBridge_batch();
    }

    function test_onERC1155BatchReceived_normalTransfer() public {
        _assert_onERC1155BatchReceived_normalTransfer();
    }

    function test_conditionCount() public {
        uint256 conditionCount_ = 4;
        bytes32 eventId = _getEventId(conditionCount_, "bridge_event");
        assertEq(positions.negRiskModule.conditionCount(EventIdLib.from(eventId)), conditionCount_);

        for (uint256 i = 0; i < conditionCount_; i++) {
            bytes32 conditionId_ = _conditionFromEvent(eventId, i);
            assertTrue(conditionId_ != bytes32(0));
        }
    }

    function test_conditionCount_invalidEventId() public {
        // An invalid event ID has arity = 0 (encoded via ConditionIdLib with arity 0).
        // EventIdLib.from would still accept it because conditionIndex/outcome bytes are zero.
        bytes32 invalidEventId =
            ConditionId.unwrap(ConditionIdLib.encode(ModuleIds.NEGRISK, keccak256("bridge_event"), 0, 0));
        assertEq(positions.negRiskModule.conditionCount(EventIdLib.from(invalidEventId)), 0);
    }

    function test_reportResult_bridgeIdempotent() public {
        uint256 conditionCount = 4;
        bytes32 eventId = _getEventId(conditionCount, "bridge_event");

        ConditionId conditionId = ConditionIdLib.from(_conditionFromEvent(eventId, 0));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        // First report
        vm.prank(bridge);
        positions.negRiskModule.reportResult(conditionId, result);

        // Verify result was stored
        assertTrue(positions.negRiskModule.hasResult(conditionId));

        // Second report is a silent no-op
        vm.prank(bridge);
        positions.negRiskModule.reportResult(conditionId, result);

        // Result unchanged
        uint256[] memory storedResult = positions.negRiskModule.getResult(conditionId);
        assertEq(storedResult[0], result[0]);
        assertEq(storedResult[1], result[1]);
    }

    function test_reportResult_bridgeDoesNotRequireEventBridge() public {
        uint256 conditionCount_ = 4;
        bytes32 eventId = _getEventId(conditionCount_, "bridge_event");

        ConditionId conditionId0 = ConditionIdLib.from(_conditionFromEvent(eventId, 0));
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(bridge);
        positions.negRiskModule.reportResult(conditionId0, result);

        assertTrue(positions.negRiskModule.hasResult(conditionId0));
        uint256[] memory storedResult = positions.negRiskModule.getResult(conditionId0);
        assertEq(storedResult[0], result[0]);
        assertEq(storedResult[1], result[1]);
    }

    function test_directSyntheticNoDoesNotEmitSyntheticYesDerivableEarly() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "bridge_synthetic_event");
        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;

        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), noResult);

        vm.prank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 0)), noResult);

        // Synthetic Other is excluded from conditionsResolved, so two real NO reports leave the
        // counter below arity and cannot announce that synthetic Other is derivable as YES.
        vm.recordLogs();
        vm.prank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 1)), noResult);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_syntheticYesDerivableLogCount(logs), 0);
        assertEq(positions.negRiskModule.conditionsResolved(EventIdLib.from(eventId)), conditionCount_ - 1);
        assertFalse(positions.negRiskModule.hasResult(ConditionIdLib.from(_conditionFromEvent(eventId, 2))));

        uint256[] memory yesResult = new uint256[](2);
        yesResult[0] = 1_000_000;
        vm.prank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 2)), yesResult);
        assertEq(positions.negRiskModule.conditionsResolved(EventIdLib.from(eventId)), conditionCount_);
    }

    function test_directSyntheticOtherFirst_countsOnlyRealConditions() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "bridge_synthetic_first");
        EventId typedEventId = EventIdLib.from(eventId);

        uint256[] memory yesResult = new uint256[](2);
        yesResult[0] = 1_000_000;
        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;

        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), yesResult);
        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), 0);

        for (uint256 i = 0; i < conditionCount_; ++i) {
            vm.prank(bridge);
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), noResult);
            assertEq(positions.negRiskModule.conditionsResolved(typedEventId), i + 1);
        }
    }

    function test_preUpgradeSyntheticCount_allowsRemainingRealResults() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "pre_upgrade_synthetic_count");
        EventId typedEventId = EventIdLib.from(eventId);

        uint256[] memory yesResult = new uint256[](2);
        yesResult[0] = 1_000_000;
        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;

        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), yesResult);

        // Slot 201 is pinned by the upgrade storage-layout checks. Simulate the legacy behavior,
        // where the stored synthetic result contributed one to conditionsResolved.
        bytes32 conditionsResolvedSlot = keccak256(abi.encode(EventId.unwrap(typedEventId), uint256(201)));
        vm.store(address(positions.negRiskModule), conditionsResolvedSlot, bytes32(uint256(1)));

        for (uint256 i = 0; i < conditionCount_; ++i) {
            vm.prank(bridge);
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), noResult);
        }

        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), conditionCount_);
    }

    function test_preUpgradeSyntheticNoCount_allowsRealYesToArriveLast() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "pre_upgrade_synthetic_no_count");
        EventId typedEventId = EventIdLib.from(eventId);

        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;
        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), noResult);

        bytes32 conditionsResolvedSlot = keccak256(abi.encode(EventId.unwrap(typedEventId), uint256(201)));
        vm.store(address(positions.negRiskModule), conditionsResolvedSlot, bytes32(uint256(1)));

        for (uint256 i = 0; i < conditionCount_ - 1; ++i) {
            vm.prank(bridge);
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), noResult);
        }

        uint256[] memory yesResult = new uint256[](2);
        yesResult[0] = 1_000_000;
        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_ - 1)), yesResult);

        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), conditionCount_);
    }

    function test_directSyntheticOtherLast_doesNotIncrementCounter() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "bridge_synthetic_last");
        EventId typedEventId = EventIdLib.from(eventId);

        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;
        for (uint256 i = 0; i < conditionCount_; ++i) {
            vm.prank(bridge);
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), noResult);
        }
        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), conditionCount_);

        uint256[] memory yesResult = new uint256[](2);
        yesResult[0] = 1_000_000;
        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), yesResult);

        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), conditionCount_);
    }

    function test_revert_directSyntheticNoThenAllRealNo() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "bridge_synthetic_no");
        EventId typedEventId = EventIdLib.from(eventId);

        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;

        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), noResult);
        for (uint256 i = 0; i < conditionCount_ - 1; ++i) {
            vm.prank(bridge);
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), noResult);
        }

        vm.expectRevert(ModuleErrors.InvalidResults.selector);
        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_ - 1)), noResult);

        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), conditionCount_ - 1);
    }

    function test_revert_directSyntheticNoAfterAllRealNo() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "bridge_synthetic_no_last");
        EventId typedEventId = EventIdLib.from(eventId);

        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;
        for (uint256 i = 0; i < conditionCount_; ++i) {
            vm.prank(bridge);
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), noResult);
        }

        vm.expectRevert(ModuleErrors.InvalidResults.selector);
        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), noResult);

        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), conditionCount_);
    }

    function test_syntheticNoLast_afterRealYesAndAllRealsStored() public {
        uint256 conditionCount_ = 3;
        bytes32 eventId = _getEventId(conditionCount_, "synthetic_no_after_yes");
        EventId typedEventId = EventIdLib.from(eventId);

        uint256[] memory yesResult = new uint256[](2);
        yesResult[0] = 1_000_000;
        uint256[] memory noResult = new uint256[](2);
        noResult[1] = 1_000_000;

        vm.prank(bridge);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 0)), yesResult);
        for (uint256 i = 1; i < conditionCount_; ++i) {
            vm.prank(bridge);
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), noResult);
        }

        // Synthetic Other NO arrives last; a real YES exists, so this must NOT revert.
        vm.prank(bridge);
        positions.negRiskModule
            .reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, conditionCount_)), noResult);

        assertEq(positions.negRiskModule.conditionsResolved(typedEventId), conditionCount_);
    }
}

/*--------------------------------------------------------------
                          HAS RESULT
--------------------------------------------------------------*/

contract NegRiskModuleTest_hasResult is NegRiskModuleTest {
    function test_hasResult_false() public {
        _assert_hasResult_false();
    }

    function test_hasResult_true() public {
        _assert_hasResult_true();
    }
}

/*--------------------------------------------------------------
                          GET PAYOUT
--------------------------------------------------------------*/

contract NegRiskModuleTest_getPayout is NegRiskModuleTest {
    function test_revert_conditionNotResolved() public {
        _assert_revert_getPayout_conditionNotResolved();
    }

    function test_revert_invalidOutcomeIndex() public {
        _assert_revert_getPayout_invalidOutcomeIndex();
    }

    function test_fullPayout() public {
        _assert_getPayout_fullPayout();
    }

    function test_revert_partialPayout() public {
        bytes32 conditionId = _prepareCondition();

        vm.expectRevert(ModuleErrors.InvalidResults.selector);
        _reportPartialResult(conditionId);
    }

    function test_virtualNoPayout_afterOneYes() public {
        bytes32 eventId = _getEventId(4, "virtual no payout");
        bytes32 winner = _conditionFromEvent(eventId, 0);
        bytes32 loser = _conditionFromEvent(eventId, 1);

        _reportResult(winner);

        PositionId noPositionId = ConditionIdLib.from(loser).computePositionId(1);
        PositionId yesPositionId = ConditionIdLib.from(loser).computePositionId(0);

        assertTrue(positions.negRiskModule.hasResult(ConditionIdLib.from(loser)));
        uint256[] memory result = positions.negRiskModule.getResult(ConditionIdLib.from(loser));
        assertEq(result[0], 0);
        assertEq(result[1], 1_000_000);
        assertEq(positions.negRiskModule.getPayout(noPositionId, 1_000_000), 1_000_000);
        assertEq(positions.negRiskModule.getPayout(yesPositionId, 1_000_000), 0);
    }
}

/*--------------------------------------------------------------
                       GET EVENT ID
--------------------------------------------------------------*/

contract NegRiskModuleTest_getEventId is NegRiskModuleTest {
    function test_getEventId() public {
        bytes32 eventId = _getEventId(4, "neg risk event");
        assertEq(positions.negRiskModule.conditionCount(EventIdLib.from(eventId)), 4);
    }

    function test_revert_invalidConditionCount() public {
        vm.expectRevert(ModuleErrors.InvalidConditionCount.selector);
        _getEventId(0, "neg risk event");

        vm.expectRevert(ModuleErrors.InvalidConditionCount.selector);
        _getEventId(1, "neg risk event");

        vm.expectRevert(ModuleErrors.InvalidConditionCount.selector);
        _getEventId(65537, "neg risk event");
    }
}

/*--------------------------------------------------------------
                       REPORT RESULT
--------------------------------------------------------------*/

contract NegRiskModuleTest_reportResult is NegRiskModuleTest {
    function test_reportResult() public {
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.expectEmit(true, false, false, true, address(positions.negRiskModule));
        emit RemainingConditionsDerivableAsNo(EventId.wrap(bytes29(eventId)));

        vm.prank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 0)), result);

        ConditionId conditionId = ConditionIdLib.from(_conditionFromEvent(eventId, 0));

        uint256[] memory result_ = positions.negRiskModule.getResult(conditionId);
        assertEq(result[0], result_[0]);
        assertEq(result[1], result_[1]);
    }

    function test_revert_resolverSyntheticOtherYes() public {
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.InvalidConditionIndex.selector);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 4)), result);
    }

    function test_revert_reportResult_eventPaused() public {
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(admin);
        positions.negRiskModule.pauseResolution(EventIdLib.from(eventId));

        vm.prank(oracle);
        vm.expectRevert(OracleModuleErrors.ResolutionIsPaused.selector);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 1)), result);
    }

    function test_revert_foreignModuleId() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("foreign-module-condition");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.InvalidEventId.selector);
        positions.negRiskModule.reportResult(conditionId, result);
    }

    function test_revert_multipleYesOutcomes() public {
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.startPrank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 0)), result);

        ConditionId conditionId1 = ConditionIdLib.from(_conditionFromEvent(eventId, 1));

        vm.expectRevert(ModuleErrors.InvalidResults.selector);
        positions.negRiskModule.reportResult(conditionId1, result);
    }

    function test_allNoResolvesSyntheticOther() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 0;
        result[1] = 1_000_000;

        vm.startPrank(oracle);
        for (uint256 i = 0; i < 3; ++i) {
            positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, i)), result);
        }

        ConditionId finalRealId = ConditionIdLib.from(_conditionFromEvent(eventId, 3));
        ConditionId otherId = ConditionIdLib.from(_conditionFromEvent(eventId, 4));

        vm.expectEmit(true, true, false, false, address(positions.negRiskModule));
        emit SyntheticConditionDerivableAsYes(EventId.wrap(bytes29(eventId)), otherId);
        vm.expectEmit(true, true, false, true, address(positions.negRiskModule));
        emit ResultReported(oracle, finalRealId, result);

        positions.negRiskModule.reportResult(finalRealId, result);
        vm.stopPrank();

        uint256[] memory otherResult = positions.negRiskModule.getResult(otherId);
        assertEq(otherResult[0], 1_000_000);
        assertEq(otherResult[1], 0);
        assertTrue(positions.negRiskModule.hasResult(otherId));
        assertEq(positions.negRiskModule.conditionsResolved(EventId.wrap(bytes29(eventId))), 4);
        assertEq(positions.negRiskModule.resultsSum(EventId.wrap(bytes29(eventId))), 0);

        // A matching bridge replay is a silent no-op and must not announce the transition again.
        vm.recordLogs();
        vm.prank(bridge);
        positions.negRiskModule.reportResult(finalRealId, result);
        assertEq(_syntheticYesDerivableLogCount(vm.getRecordedLogs()), 0);
    }

    function test_finalYesOutcome() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 0;
        result[1] = 1_000_000;

        vm.startPrank(oracle);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 0)), result);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 1)), result);
        positions.negRiskModule.reportResult(ConditionIdLib.from(_conditionFromEvent(eventId, 2)), result);

        ConditionId conditionId3 = ConditionIdLib.from(_conditionFromEvent(eventId, 3));
        result[0] = 1_000_000;
        result[1] = 0;
        positions.negRiskModule.reportResult(conditionId3, result);
    }

    function test_revert_unauthorized() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        ConditionId conditionId0 = ConditionIdLib.from(_conditionFromEvent(eventId, 0));

        vm.prank(alice); // alice is not the oracle
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positions.negRiskModule.reportResult(conditionId0, result);
    }
}

/*--------------------------------------------------------------
                      HORIZONTAL SPLIT
--------------------------------------------------------------*/

contract NegRiskModuleTest_horizontalSplit is NegRiskModuleTest {
    function test_horizontalSplit() public {
        uint256 conditionCount = 4;

        vm.prank(creator);
        bytes32 eventId = _getEventId(conditionCount, "neg risk event");

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.horizontalSplit(EventIdLib.from(eventId), 1_000_000_000);
        vm.stopPrank();

        for (uint256 i = 0; i < conditionCount; i++) {
            bytes32 conditionId = _conditionFromEvent(eventId, i);
            uint256 yesPositionId =
                PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));

            assertEq(positions.manager.balanceOf(alice, yesPositionId), 1_000_000_000);
        }

        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_revert_invalidEventId() public {
        // Construct an unprepared event ID via the ConditionId encoding (arity = 0).
        bytes32 unpreparedEventId = ConditionId.unwrap(
            ConditionIdLib.encodeFromData(ModuleIds.NEGRISK, 0, abi.encodePacked("UnpreparedEvent"))
        );

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        // Wrap USDC to PMCT first (router transfers PMCT, not USDC)
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        vm.expectRevert(ModuleErrors.InvalidEventId.selector);
        router.horizontalSplit(EventIdLib.from(unpreparedEventId), 1_000_000_000);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                      HORIZONTAL MERGE
--------------------------------------------------------------*/

contract NegRiskModuleTest_horizontalMerge is NegRiskModuleTest {
    function test_horizontalMerge() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");
        uint256 amount = 1_000_000_000;

        _fundAndHorizontalSplit(alice, eventId, amount);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        router.horizontalMerge(EventIdLib.from(eventId), amount);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), amount);
    }

    function test_revert_invalidEventId() public {
        bytes32 unpreparedEventId = ConditionId.unwrap(
            ConditionIdLib.encodeFromData(ModuleIds.NEGRISK, 0, abi.encodePacked("UnpreparedEvent"))
        );

        vm.expectRevert(ModuleErrors.InvalidEventId.selector);
        positions.negRiskModule.horizontalMerge(alice, EventIdLib.from(unpreparedEventId), 1);
    }
}

/*--------------------------------------------------------------
                   REASSIGN EVENT ORACLE
--------------------------------------------------------------*/

contract NegRiskModuleTest_resolverRole is NegRiskModuleTest {
    function test_addResolver_thenReport() public {
        address newResolver = vm.createWallet("newResolver").addr;
        vm.prank(admin);
        positions.negRiskModule.addResolver(newResolver);

        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        ConditionId conditionId0 = ConditionIdLib.from(_conditionFromEvent(eventId, 0));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(newResolver);
        positions.negRiskModule.reportResult(conditionId0, result);

        assertTrue(positions.negRiskModule.hasResult(conditionId0));
    }

    function test_revert_unauthorized() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        ConditionId conditionId0 = ConditionIdLib.from(_conditionFromEvent(eventId, 0));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        // Alice has no resolver role
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        positions.negRiskModule.reportResult(conditionId0, result);
    }

    function test_revert_reportResult_wrongResolutionChain() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        ConditionId conditionId0 = ConditionIdLib.from(_conditionFromEvent(eventId, 0));
        ConditionId wrongChainId =
            ConditionIdLib.from(bytes32(uint256(bytes32(ConditionId.unwrap(conditionId0))) | (uint256(1) << 24)));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(OracleModuleErrors.InvalidResolutionChain.selector);
        positions.negRiskModule.reportResult(wrongChainId, result);
    }

    function test_reportResult_replayCallerSemantics() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory resultYes = new uint256[](2);
        resultYes[0] = 1_000_000;
        resultYes[1] = 0;

        ConditionId conditionId0 = ConditionIdLib.from(_conditionFromEvent(eventId, 0));
        vm.prank(oracle);
        positions.negRiskModule.reportResult(conditionId0, resultYes);

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.ConditionAlreadyResolved.selector);
        positions.negRiskModule.reportResult(conditionId0, resultYes);

        vm.prank(bridge);
        positions.negRiskModule.reportResult(conditionId0, resultYes);

        assertEq(positions.negRiskModule.conditionsResolved(EventId.wrap(bytes29(eventId))), 1);

        uint256[] memory storedResult = positions.negRiskModule.getResult(conditionId0);
        assertEq(storedResult[0], 1_000_000);
        assertEq(storedResult[1], 0);

        resultYes[0] = 0;
        resultYes[1] = 1_000_000;

        vm.prank(bridge);
        vm.expectRevert(ModuleErrors.ExistingPayoutMismatch.selector);
        positions.negRiskModule.reportResult(conditionId0, resultYes);
    }

    function test_revert_reportResult_resolverReplayPayoutMismatch() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(4, "neg risk event");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        ConditionId conditionId0 = ConditionIdLib.from(_conditionFromEvent(eventId, 0));
        vm.prank(oracle);
        positions.negRiskModule.reportResult(conditionId0, result);

        result[0] = 0;
        result[1] = 1_000_000;

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.ExistingPayoutMismatch.selector);
        positions.negRiskModule.reportResult(conditionId0, result);
    }
}

/*--------------------------------------------------------------
                            VIEW
--------------------------------------------------------------*/

contract NegRiskModuleTest_view is NegRiskModuleTest {
    function test_getPositionId(bytes32 _conditionId, uint256 _outcomeIndex) public view {
        bytes32 canonical = bytes32(uint256(_conditionId) & ~uint256(0xFF));
        assertEq(
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(canonical)), _outcomeIndex)),
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(canonical)), _outcomeIndex))
        );
    }
}

/*--------------------------------------------------------------
     REPORT RESULT - COVERAGE BRANCHES
--------------------------------------------------------------*/

/// @notice Tests for NegRiskModule.migratePositions error branches
contract NegRiskModuleTest_reportResultCoverage is NegRiskModuleTest {
    // Test the operator migrate function with array length mismatch
    function test_revert_migratePositions_operator_arrayMismatch() public {
        bytes32[] memory legacyConditionIds = new bytes32[](2);
        legacyConditionIds[0] = bytes32(uint256(1));
        legacyConditionIds[1] = bytes32(uint256(2));

        uint256[] memory outcomeIndices = new uint256[](2);
        outcomeIndices[0] = 0;
        outcomeIndices[1] = 0;

        uint256[] memory amounts_ = new uint256[](1);
        amounts_[0] = 100;

        // Grant operator role so we hit the array length check, not auth
        vm.prank(admin);
        positions.negRiskModule.addOperator(admin);

        vm.prank(admin);
        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        positions.negRiskModule.migratePositions(alice, legacyConditionIds, outcomeIndices, amounts_);
    }
}

/*--------------------------------------------------------------
     PREPARE EVENT - COVERAGE BRANCHES
--------------------------------------------------------------*/

/// @notice Tests for NegRiskModule constructor _negRiskAdapter=address(0) branch
///         and prepareEvent already-prepared.
contract NegRiskModuleTest_prepareEventCoverage is NegRiskModuleTest {
    // NegRiskModule constructor with _negRiskAdapter = address(0)
    // The default PositionManagerSetup passes a real negRiskAdapter, so the TRUE
    // branch is covered. This test deploys a NegRiskModule with address(0) to
    // cover the FALSE branch (wrappedCollateralToken = address(0), skip approval).
    function test_constructor_zeroNegRiskAdapter() public {
        NegRiskModule zeroAdapterModule = new NegRiskModule(
            address(positions.manager),
            address(0), // conditionalTokens (unused when adapter is zero)
            address(0), // usdce (unused when adapter is zero)
            address(0), // _negRiskAdapter = 0 -> skips legacy adapter approval
            ResolutionChain.POLYGON
        );
        assertEq(address(zeroAdapterModule.NEG_RISK_ADAPTER()), address(0));
    }

    function test_getEventId_isDeterministic() public view {
        assertEq(_getEventId(2, "already_prepared_event"), _getEventId(2, "already_prepared_event"));
    }
}

/*--------------------------------------------------------------
     MIGRATE POSITIONS - ARRAY MISMATCH
--------------------------------------------------------------*/

/// @notice Tests for NegRiskModule.migratePositions operator overload
///         second array length check (_amounts mismatch).
///         The actual migration loop + _depositUSDCeToCollateralTokenVault
///         require legacy CTF infrastructure and are SKIPPED.
contract NegRiskModuleTest_migrateAmountsMismatch is NegRiskModuleTest {
    // legacyConditionIds.length != amounts.length mismatch (InvalidArrayLength)
    function test_revert_migratePositions_operator_amountsMismatch() public {
        bytes32[] memory legacyConditionIds = new bytes32[](2);
        legacyConditionIds[0] = bytes32(uint256(1));
        legacyConditionIds[1] = bytes32(uint256(2));

        uint256[] memory outcomeIndices = new uint256[](2);
        outcomeIndices[0] = 0;
        outcomeIndices[1] = 0;

        uint256[] memory amounts_ = new uint256[](1);
        amounts_[0] = 100;

        vm.prank(admin);
        positions.negRiskModule.addOperator(admin);

        vm.prank(admin);
        vm.expectRevert(ModuleErrors.InvalidArrayLength.selector);
        positions.negRiskModule.migratePositions(alice, legacyConditionIds, outcomeIndices, amounts_);
    }
}

/*--------------------------------------------------------------
     HORIZONTAL SPLIT/MERGE DIRECT
--------------------------------------------------------------*/

contract NegRiskModuleTest_directHorizontal is NegRiskModuleTest {
    function test_horizontalSplit_direct() public {
        uint256 conditionCount_ = 3;

        vm.prank(creator);
        bytes32 eventId = _getEventId(conditionCount_, "hsplit_no_cb");

        // Mint collateral and transfer to module
        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), address(positions.negRiskModule), 1_000_000);
        vm.stopPrank();

        positions.negRiskModule.horizontalSplit(alice, EventIdLib.from(eventId), 1_000_000);

        // Verify positions minted
        for (uint256 i = 0; i < conditionCount_; i++) {
            bytes32 condId = _conditionFromEvent(eventId, i);
            uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(condId)), 0));
            assertEq(positions.manager.balanceOf(alice, yesId), 1_000_000);
        }
    }

    function test_horizontalMerge_direct() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(3, "hmerge_no_cb");
        uint256 amount = 1_000_000;

        _fundAndHorizontalSplit(alice, eventId, amount);

        uint256 legCount = _horizontalLegCount(eventId);
        PositionId[] memory ids = new PositionId[](legCount);
        uint256[] memory amounts_ = new uint256[](legCount);
        for (uint256 i = 0; i < legCount; ++i) {
            ids[i] = PositionId.wrap(_yesPositionId(eventId, i));
            amounts_[i] = amount;
        }

        vm.startPrank(alice);
        positions.manager.unsafeBatchTransferFrom(alice, address(positions.negRiskModule), ids, amounts_);
        positions.negRiskModule.horizontalMerge(alice, EventIdLib.from(eventId), amount);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), amount);
    }

    function test_revert_horizontalSplit_noPreTransfer() public {
        uint256 conditionCount_ = 3;
        vm.prank(creator);
        EventId eventId = positions.negRiskModule.getEventId(conditionCount_, "revert_split_noPreTransfer");
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        positions.negRiskModule.horizontalSplit(alice, eventId, 1_000_000);
    }

    function test_revert_horizontalMerge_noPreTransfer() public {
        uint256 conditionCount_ = 3;
        vm.prank(creator);
        EventId eventId = positions.negRiskModule.getEventId(conditionCount_, "revert_merge_noPreTransfer");
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        positions.negRiskModule.horizontalMerge(alice, eventId, 1_000_000);
    }

    function test_revert_convert_noPreTransfer() public {
        uint256 conditionCount_ = 3;
        vm.prank(creator);
        EventId eventId = positions.negRiskModule.getEventId(conditionCount_, "revert_convert_noPreTransfer");
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        positions.negRiskModule.convert(alice, eventId, 0, 1_000_000);
    }
}

/*--------------------------------------------------------------
                       CONVERT
--------------------------------------------------------------*/

/// @notice Tests for NegRiskModule convert operations.
contract NegRiskModuleTest_convert is NegRiskModuleTest {
    function test_convert() public {
        uint256 conditionCount_ = 3;
        vm.prank(creator);
        bytes32 eventId = _getEventId(conditionCount_, "convert_event");

        uint256 amount = 1_000_000;

        // Split first condition to get YES+NO for alice
        collateral.usdc.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), alice, amount);
        collateral.token.approve(address(router), amount);
        bytes32 conditionId = _conditionFromEvent(eventId, 0);
        router.split(ConditionIdLib.from(conditionId), amount);

        // Transfer NO to module directly
        uint256 noPositionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 1));
        positions.manager.safeTransferFrom(alice, address(positions.negRiskModule), noPositionId, amount, "");

        positions.negRiskModule.convert(alice, EventIdLib.from(eventId), 0, amount);
        vm.stopPrank();

        // Alice should have YES positions for conditions 1 and 2
        for (uint256 i = 1; i < conditionCount_; i++) {
            bytes32 cid = _conditionFromEvent(eventId, i);
            uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(cid)), 0));
            assertEq(positions.manager.balanceOf(alice, yesId), amount);
        }

        // NO position for condition 0 should be burned
        assertEq(positions.manager.balanceOf(alice, noPositionId), 0);
        assertEq(positions.manager.balanceOf(address(positions.negRiskModule), noPositionId), 0);
    }

    function test_revert_invalidEventId() public {
        bytes32 unpreparedEventId = ConditionId.unwrap(
            ConditionIdLib.encodeFromData(ModuleIds.NEGRISK, 0, abi.encodePacked("UnpreparedConvert"))
        );

        vm.expectRevert(ModuleErrors.InvalidEventId.selector);
        positions.negRiskModule.convert(alice, EventIdLib.from(unpreparedEventId), 0, 1_000_000);
    }

    function test_revert_invalidConditionIndex() public {
        vm.prank(creator);
        bytes32 eventId = _getEventId(3, "convert_oob");

        vm.expectRevert(ModuleErrors.InvalidConditionIndex.selector);
        positions.negRiskModule.convert(alice, EventIdLib.from(eventId), 4, 1_000_000);
    }

    function test_convert_emitsPositionConverted() public {
        uint256 conditionCount_ = 3;
        vm.prank(creator);
        bytes32 eventId = _getEventId(conditionCount_, "convert_event_emit");

        uint256 amount = 1_000_000;

        collateral.usdc.mint(alice, amount);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), alice, amount);
        collateral.token.approve(address(router), amount);
        bytes32 sourceConditionId = _conditionFromEvent(eventId, 0);
        router.split(ConditionIdLib.from(sourceConditionId), amount);

        // Transfer NO to module directly
        uint256 noPositionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(sourceConditionId)), 1));
        positions.manager.safeTransferFrom(alice, address(positions.negRiskModule), noPositionId, amount, "");

        vm.expectEmit(true, true, true, true, address(positions.negRiskModule));
        emit PositionConverted(alice, EventIdLib.from(eventId), alice, 0, amount);

        positions.negRiskModule.convert(alice, EventIdLib.from(eventId), 0, amount);
        vm.stopPrank();

        // Sanity checks: NO burned, YES minted for other conditions
        assertEq(positions.manager.balanceOf(alice, noPositionId), 0);
        for (uint256 i = 1; i < conditionCount_; i++) {
            bytes32 cid = _conditionFromEvent(eventId, i);
            uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(cid)), 0));
            assertEq(positions.manager.balanceOf(alice, yesId), amount);
        }
    }
}

/*--------------------------------------------------------------
                      VIA ROUTER
--------------------------------------------------------------*/

contract NegRiskModuleTest_viaRouter is NegRiskModuleTest {
    function test_horizontalSplit_viaRouter() public {
        uint256 conditionCount_ = 3;
        vm.prank(creator);
        bytes32 eventId = _getEventId(conditionCount_, "hsplit_cb");

        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000);
        collateral.token.approve(address(router), 1_000_000);

        router.horizontalSplit(EventIdLib.from(eventId), 1_000_000);
        vm.stopPrank();

        for (uint256 i = 0; i < conditionCount_; i++) {
            bytes32 condId = _conditionFromEvent(eventId, i);
            uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(condId)), 0));
            assertEq(positions.manager.balanceOf(alice, yesId), 1_000_000);
        }
    }

    function test_horizontalMerge_viaRouter() public {
        uint256 conditionCount_ = 3;
        vm.prank(creator);
        bytes32 eventId = _getEventId(conditionCount_, "hmerge_cb");

        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000);
        collateral.token.approve(address(router), 1_000_000);
        router.horizontalSplit(EventIdLib.from(eventId), 1_000_000);

        positions.manager.setApprovalForAll(address(router), true);
        router.horizontalMerge(EventIdLib.from(eventId), 1_000_000);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 1_000_000);
    }
}

/*--------------------------------------------------------------
                         INITIALIZER
--------------------------------------------------------------*/

contract NegRiskModuleTest_initialize is NegRiskModuleTest {
    function test_revert_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        positions.negRiskModule.initialize(owner, admin);
    }
}

/*--------------------------------------------------------------
                            UUPS
--------------------------------------------------------------*/

contract NegRiskModuleTest_upgrade is NegRiskModuleTest {
    function test_upgradeToAndCall_preservesState() public {
        bytes32 eventId = EventId.unwrap(positions.negRiskModule.getEventId(2, "upgrade-state"));
        ConditionId conditionId = ConditionIdLib.from(_conditionFromEvent(eventId, 0));

        uint256[] memory result = new uint256[](2);
        result[1] = 1_000_000;

        vm.prank(oracle);
        positions.negRiskModule.reportResult(conditionId, result);

        address newImpl = address(
            new NegRiskModule(
                address(positions.manager),
                address(positions.negRiskModule.CONDITIONAL_TOKENS()),
                positions.negRiskModule.USDCE(),
                address(positions.negRiskModule.NEG_RISK_ADAPTER()),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(owner);
        positions.negRiskModule.upgradeToAndCall(newImpl, "");

        assertEq(positions.negRiskModule.conditionCount(EventIdLib.from(eventId)), 2);
        assertEq(positions.negRiskModule.resultsSum(EventId.wrap(bytes29(eventId))), result[0]);
        assertEq(positions.negRiskModule.conditionsResolved(EventId.wrap(bytes29(eventId))), 1);
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(
            new NegRiskModule(
                address(positions.manager),
                address(positions.negRiskModule.CONDITIONAL_TOKENS()),
                positions.negRiskModule.USDCE(),
                address(positions.negRiskModule.NEG_RISK_ADAPTER()),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        positions.negRiskModule.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_incompatibleModuleId() public {
        address newImpl = address(
            new BinaryModule(
                address(positions.manager),
                address(positions.negRiskModule.CONDITIONAL_TOKENS()),
                positions.negRiskModule.USDCE(),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(owner);
        vm.expectRevert(ModuleErrors.IncompatibleImplementation.selector);
        positions.negRiskModule.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_incompatibleUsdce() public {
        address newImpl = address(
            new NegRiskModule(
                address(positions.manager),
                address(positions.negRiskModule.CONDITIONAL_TOKENS()),
                address(0xBEEF),
                address(positions.negRiskModule.NEG_RISK_ADAPTER()),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(owner);
        vm.expectRevert(ModuleErrors.IncompatibleImplementation.selector);
        positions.negRiskModule.upgradeToAndCall(newImpl, "");
    }
}

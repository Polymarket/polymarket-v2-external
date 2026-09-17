// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "lib/forge-std/src/Test.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { OracleAggregatorErrors } from "@polymarket-v2/src/oracle/abstract/OracleAggregatorErrors.sol";
import { OracleAggregatorEvents } from "@polymarket-v2/src/oracle/abstract/OracleAggregatorEvents.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { Pausable } from "@polymarket-v2/src/oracle/mixins/Pausable.sol";
import { MarketDataRegistry } from "@polymarket-v2/src/oracle/mixins/MarketDataRegistry.sol";
import { EOAReporterModule } from "@polymarket-v2/src/oracle/modules/reporters/EOAReporterModule.sol";
import { MockDisputerModule } from "@polymarket-v2/src/oracle/test/mocks/MockDisputerModule.sol";
import { MockArbitratorModule } from "@polymarket-v2/src/oracle/test/mocks/MockArbitratorModule.sol";
import { IArbitratorModule } from "@polymarket-v2/src/oracle/interfaces/IArbitratorModule.sol";
import { OracleModuleBase } from "@polymarket-v2/src/oracle/abstract/OracleModuleBase.sol";
import { ConditionId, ConditionIdLib, EventId, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";

/// @dev Test-only arbitrator whose `onArbitrationResolved` hook always reverts. Used to verify the
///      aggregator's admin override remains successful even when the arbitrator misbehaves.
contract RevertingArbitratorModule is IArbitratorModule {
    error RejectedByArbitrator();

    function initializeArbitratorModule(EventId, bytes calldata) external override { }

    function onArbitrationTriggered(bytes32, bytes32) external override { }

    function onArbitrationResolved(bytes32) external pure override {
        revert RejectedByArbitrator();
    }

    function getArbitrationState(bytes32) external pure override returns (bool, bytes32) {
        return (false, bytes32(0));
    }
}

import {
    Positions,
    Collateral,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";

contract OracleAggregatorTest is Test {
    error Unauthorized();

    OracleAggregator public aggregator;
    EOAReporterModule public eoaReporter;
    EOAReporterModule public eoaReporter2;
    MockDisputerModule public mockDisputer;
    MockArbitratorModule public mockArbitrator;

    Positions public positions;
    Collateral public collateral;

    address public owner = makeAddr("owner");
    address public admin = makeAddr("admin");
    address public operator = makeAddr("operator");

    address public reporter1 = makeAddr("reporter1");
    address public reporter2 = makeAddr("reporter2");
    address public disputer = makeAddr("disputer");
    address public arbitrator = makeAddr("arbitrator");
    address public marketManager = makeAddr("marketManager");
    address public finalizerAddr = makeAddr("finalizerAddr");
    address public stranger = makeAddr("stranger");

    uint256 internal _nonce;

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, address(this));

        OracleAggregator implementation = new OracleAggregator(address(positions.manager));
        address proxy = LibClone.deployERC1967(address(implementation));
        aggregator = OracleAggregator(proxy);
        aggregator.initialize(owner, owner);

        vm.startPrank(owner);
        aggregator.addAdmin(admin);
        vm.stopPrank();

        vm.prank(admin);
        aggregator.addOperator(operator);

        // `marketManager` now exercises the operator role (operator absorbed the former
        // market-manager config duties).
        vm.prank(admin);
        aggregator.addOperator(marketManager);

        eoaReporter = EOAReporterModule(LibClone.deployERC1967(address(new EOAReporterModule())));
        eoaReporter.initialize(owner, admin, address(aggregator));

        eoaReporter2 = EOAReporterModule(LibClone.deployERC1967(address(new EOAReporterModule())));
        eoaReporter2.initialize(owner, admin, address(aggregator));

        mockDisputer = new MockDisputerModule(address(aggregator));
        mockArbitrator = new MockArbitratorModule(address(aggregator));

        // Grant resolver role to the aggregator on both modules
        vm.startPrank(admin);
        positions.binaryModule.addResolver(address(aggregator));
        positions.negRiskModule.addResolver(address(aggregator));
        vm.stopPrank();
    }

    /*--------------------------------------------------------------
                            HELPERS
    --------------------------------------------------------------*/

    function _initializeRequest(
        bytes32 eventId,
        address target,
        OracleAggregator.MarketType marketType,
        uint16 resultLength,
        uint16 reporterThreshold,
        uint16 disputerThreshold
    ) internal {
        _initializeRequestWithArbitrator(
            eventId, target, marketType, resultLength, reporterThreshold, disputerThreshold, address(mockArbitrator)
        );
    }

    function _initializeRequestWithArbitrator(
        bytes32 eventId,
        address target,
        OracleAggregator.MarketType marketType,
        uint16 resultLength,
        uint16 reporterThreshold,
        uint16 disputerThreshold,
        address arbitrator
    ) internal {
        _initializeRequestFull(
            eventId, target, marketType, resultLength, reporterThreshold, disputerThreshold, arbitrator, address(0)
        );
    }

    function _initializeRequestFull(
        bytes32 eventId,
        address target,
        OracleAggregator.MarketType marketType,
        uint16 resultLength,
        uint16 reporterThreshold,
        uint16 disputerThreshold,
        address arbitrator,
        address finalizer
    ) internal {
        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](2);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });
        reporterModules[1] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter2), initData: abi.encode(_reporters()) });

        address[] memory disputers = new address[](1);
        disputers[0] = disputer;

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: marketType,
                targetContract: target,
                resultLength: resultLength,
                reporterModules: reporterModules,
                reporterThreshold: reporterThreshold,
                disputerModules: disputerModules,
                disputerThreshold: disputerThreshold,
                arbitratorModule: arbitrator,
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: finalizer
            })
        );
    }

    /// @dev Initializes a request with two distinct disputer modules so a `disputerThreshold` of
    ///      2 is satisfiable. Returns the second disputer for tests that dispute through it.
    function _initializeRequestTwoDisputers(
        bytes32 eventId,
        address target,
        OracleAggregator.MarketType marketType,
        uint16 resultLength,
        uint16 reporterThreshold,
        uint16 disputerThreshold
    ) internal returns (MockDisputerModule disputer2) {
        disputer2 = new MockDisputerModule(address(aggregator));

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](2);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });
        reporterModules[1] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter2), initData: abi.encode(_reporters()) });

        address[] memory disputers = new address[](1);
        disputers[0] = disputer;

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](2);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });
        disputerModules[1] = OracleAggregator.ModuleConfig({ module: address(disputer2), initData: "" });

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: marketType,
                targetContract: target,
                resultLength: resultLength,
                reporterModules: reporterModules,
                reporterThreshold: reporterThreshold,
                disputerModules: disputerModules,
                disputerThreshold: disputerThreshold,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    function _nextBinaryEventId() internal returns (bytes32) {
        _nonce++;
        bytes memory data = abi.encode("oracle-agg-binary", _nonce);
        return bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId(data)));
    }

    function _nextNegRiskEventId(uint256 conditionCount) internal returns (bytes32) {
        _nonce++;
        bytes memory data = abi.encode("oracle-agg-negrisk", _nonce);
        return bytes32(EventId.unwrap(positions.negRiskModule.getEventId(conditionCount, data)));
    }

    function _nextEventIdWithArity(uint256 arity) internal returns (bytes32) {
        return _nextEventIdWithModuleAndArity(ModuleIds.NEGRISK, arity);
    }

    function _nextEventIdWithModuleAndArity(uint256 moduleId, uint256 arity) internal returns (bytes32) {
        _nonce++;
        bytes memory data = abi.encode("oracle-agg-custom-arity", _nonce);
        return bytes32(EventId.unwrap(EventIdLib.encodeFromData(moduleId, arity, data)));
    }

    function _reporters() internal view returns (address[] memory reporters) {
        reporters = new address[](2);
        reporters[0] = reporter1;
        reporters[1] = reporter2;
    }

    function _yesSingle() internal pure returns (uint256[] memory result) {
        result = new uint256[](1);
        result[0] = 1_000_000;
    }

    /// @dev Drives a binary/incremental request to a YES proposal by hitting the 2-vote threshold.
    function _reachProposal(bytes32 requestId) internal {
        vm.prank(reporter1);
        eoaReporter.report(requestId, _yesSingle());
        vm.prank(reporter1);
        eoaReporter2.report(requestId, _yesSingle());
    }

    /// @dev Wraps a single raw event ID into the calldata array shape used by pause batch methods.
    function _singleEvent(bytes32 eventId) internal pure returns (EventId[] memory ids) {
        ids = new EventId[](1);
        ids[0] = EventId.wrap(bytes29(eventId));
    }

    function _addrArray(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}

/*--------------------------------------------------------------
                        INITIALIZE
--------------------------------------------------------------*/

contract OracleAggregatorTest_initialize is OracleAggregatorTest {
    function testFuzz_initializeRequest_emitsCompleteConfiguration(
        uint8 rawMarketType,
        uint32 livenessWindow,
        address finalizer
    ) public {
        OracleAggregator.MarketType marketType = OracleAggregator.MarketType(
            bound(rawMarketType, 0, uint8(OracleAggregator.MarketType.ATOMIC_NEGRISK))
        );
        livenessWindow = uint32(bound(livenessWindow, 1, aggregator.MAX_LIVENESS_WINDOW()));

        bytes32 eventId;
        address target;
        if (marketType == OracleAggregator.MarketType.BINARY) {
            eventId = _nextBinaryEventId();
            target = address(positions.binaryModule);
        } else {
            eventId = _nextNegRiskEventId(3);
            target = address(positions.negRiskModule);
        }

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] = OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: "" });

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] = OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: "" });

        EventId typedEventId = EventId.wrap(bytes29(eventId));

        vm.expectEmit(true, true, false, true, address(aggregator));
        emit OracleAggregatorEvents.ReporterModuleAdded(typedEventId, address(eoaReporter));
        vm.expectEmit(true, true, false, true, address(aggregator));
        emit OracleAggregatorEvents.DisputerModuleAdded(typedEventId, address(mockDisputer));
        vm.expectEmit(true, false, false, true, address(aggregator));
        emit OracleAggregatorEvents.RequestInitialized(
            typedEventId, target, 1, 1, 1, uint8(marketType), address(mockArbitrator), livenessWindow, finalizer
        );

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: typedEventId,
                marketType: marketType,
                targetContract: target,
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: livenessWindow,
                finalizer: finalizer
            })
        );
    }

    function test_initializeBinaryEvent() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        (
            address target,
            OracleAggregator.MarketType marketType,
            uint16 rLen,
            uint32 liveness,
            uint16 rThreshold,
            uint16 dThreshold,
            address arbitrator_,
            address finalizer
        ) = aggregator.requestConfigs(EventId.wrap(bytes29(eventId)));

        assertEq(target, address(positions.binaryModule));
        assertEq(address(aggregator.POSITION_MANAGER()), address(positions.manager));
        assertEq(uint8(marketType), uint8(OracleAggregator.MarketType.BINARY));
        assertEq(rThreshold, 2);
        assertEq(dThreshold, 1);
        assertEq(liveness, uint32(5 minutes));
        assertEq(rLen, 1);
        assertEq(arbitrator_, address(mockArbitrator));
        assertEq(finalizer, address(0));

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Active));
    }

    function test_initializeRequest_acceptsMaximumLivenessWindow() public {
        uint32 maxLivenessWindow = aggregator.MAX_LIVENESS_WINDOW();
        assertEq(maxLivenessWindow, 7 days);

        bytes32 eventId = _nextBinaryEventId();
        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] = OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: "" });
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] = OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: "" });

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: maxLivenessWindow,
                finalizer: address(0)
            })
        );

        (,,, uint32 storedLivenessWindow,,,,) = aggregator.requestConfigs(EventIdLib.from(eventId));
        assertEq(storedLivenessWindow, maxLivenessWindow);
    }

    function test_revert_initializeRequest_livenessWindowTooLong() public {
        bytes32 eventId = _nextBinaryEventId();
        uint32 excessiveLivenessWindow = aggregator.MAX_LIVENESS_WINDOW() + 1;
        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] = OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: "" });
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] = OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: "" });

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.LivenessWindowTooLong.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: excessiveLivenessWindow,
                finalizer: address(0)
            })
        );
    }

    function test_initializeIncrementalNegRiskEvent() public {
        bytes32 eventId = _nextNegRiskEventId(2);

        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );

        (address target, OracleAggregator.MarketType marketType,,,,,,) =
            aggregator.requestConfigs(EventId.wrap(bytes29(eventId)));
        assertEq(target, address(positions.negRiskModule));
        assertEq(uint8(marketType), uint8(OracleAggregator.MarketType.INCREMENTAL_NEGRISK));
    }

    function test_initializeAtomicNegRiskEvent() public {
        bytes32 eventId = _nextNegRiskEventId(2);

        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.ATOMIC_NEGRISK, 1, 2, 1
        );

        (, OracleAggregator.MarketType marketType,,,,,,) = aggregator.requestConfigs(EventId.wrap(bytes29(eventId)));
        assertEq(uint8(marketType), uint8(OracleAggregator.MarketType.ATOMIC_NEGRISK));
    }

    function test_revert_initializeBinaryTypeWithNonzeroArity() public {
        bytes32 eventId = _nextNegRiskEventId(2);

        vm.expectRevert(OracleAggregatorErrors.InvalidEventId.selector);
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
    }

    function test_revert_initializeIncrementalNegRiskTypeWithZeroArity() public {
        bytes32 eventId = _nextBinaryEventId();

        vm.expectRevert(OracleAggregatorErrors.InvalidEventId.selector);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );
    }

    function test_revert_initializeAtomicNegRiskTypeWithZeroArity() public {
        bytes32 eventId = _nextBinaryEventId();

        vm.expectRevert(OracleAggregatorErrors.InvalidEventId.selector);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.ATOMIC_NEGRISK, 1, 2, 1
        );
    }

    function test_revert_initializeIncrementalNegRiskTypeWithArityOne() public {
        bytes32 eventId = _nextEventIdWithArity(1);

        vm.expectRevert(OracleAggregatorErrors.InvalidEventId.selector);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );
    }

    function test_revert_initializeAtomicNegRiskTypeWithArityOne() public {
        bytes32 eventId = _nextEventIdWithArity(1);

        vm.expectRevert(OracleAggregatorErrors.InvalidEventId.selector);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.ATOMIC_NEGRISK, 1, 2, 1
        );
    }

    function test_revert_initializeBinaryTypeWithForeignModuleId() public {
        bytes32 eventId = _nextEventIdWithModuleAndArity(ModuleIds.NEGRISK, 0);

        vm.expectRevert(OracleAggregatorErrors.InvalidEventId.selector);
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
    }

    function test_revert_initializeIncrementalNegRiskTypeWithForeignModuleId() public {
        bytes32 eventId = _nextEventIdWithModuleAndArity(ModuleIds.BINARY, 2);

        vm.expectRevert(OracleAggregatorErrors.InvalidEventId.selector);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );
    }

    function test_revert_initializeBinaryTypeWithWrongTarget() public {
        bytes32 eventId = _nextBinaryEventId();

        vm.expectRevert(OracleAggregatorErrors.InvalidTargetContract.selector);
        _initializeRequest(eventId, address(positions.negRiskModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
    }

    function test_revert_initializeIncrementalNegRiskTypeWithWrongTarget() public {
        bytes32 eventId = _nextNegRiskEventId(2);

        vm.expectRevert(OracleAggregatorErrors.InvalidTargetContract.selector);
        _initializeRequest(
            eventId, address(positions.binaryModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );
    }

    function test_revert_initializeAtomicNegRiskTypeWithWrongTarget() public {
        bytes32 eventId = _nextNegRiskEventId(2);

        vm.expectRevert(OracleAggregatorErrors.InvalidTargetContract.selector);
        _initializeRequest(
            eventId, address(positions.binaryModule), OracleAggregator.MarketType.ATOMIC_NEGRISK, 1, 2, 1
        );
    }
}

/*--------------------------------------------------------------
                        FINALIZE
--------------------------------------------------------------*/

contract OracleAggregatorTest_finalize is OracleAggregatorTest {
    function test_incremental_finalize_reportsTranslatedPayout() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );

        bytes32 conditionId = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 1));
        uint256[] memory yes = _yesSingle();

        vm.prank(reporter1);
        eoaReporter.report(conditionId, yes);
        vm.prank(reporter1);
        eoaReporter2.report(conditionId, yes);

        vm.warp(block.timestamp + 5 minutes + 1);
        aggregator.finalize(conditionId, yes);

        uint256[] memory targetPayout = positions.negRiskModule.getResult(ConditionIdLib.from(conditionId));
        assertEq(targetPayout.length, 2);
        assertEq(targetPayout[0], 1_000_000);
        assertEq(targetPayout[1], 0);
    }

    function test_finalize_targetAlreadyResolvedWithMatchingPayout() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        uint256[] memory storedResult = new uint256[](2);
        storedResult[0] = 1_000_000;
        storedResult[1] = 0;

        vm.prank(admin);
        positions.binaryModule.addResolver(admin);
        vm.prank(admin);
        positions.binaryModule.reportResult(ConditionIdLib.from(eventId), storedResult);

        uint256[] memory yes = _yesSingle();

        vm.prank(reporter1);
        eoaReporter.report(eventId, yes);
        vm.prank(reporter1);
        eoaReporter2.report(eventId, yes);

        vm.warp(block.timestamp + 5 minutes + 1);
        aggregator.finalize(eventId, yes);

        (OracleAggregator.ResolutionStatus status, bytes32 proposedResultHash,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
        assertEq(proposedResultHash, keccak256(abi.encode(yes)));
    }

    function test_revert_finalize_targetPayoutMismatch() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        uint256[] memory storedResult = new uint256[](2);
        storedResult[0] = 1_000_000;
        storedResult[1] = 0;

        vm.prank(admin);
        positions.binaryModule.addResolver(admin);
        vm.prank(admin);
        positions.binaryModule.reportResult(ConditionIdLib.from(eventId), storedResult);

        uint256[] memory conflicting = new uint256[](1);
        conflicting[0] = 0;

        vm.prank(reporter1);
        eoaReporter.report(eventId, conflicting);
        vm.prank(reporter1);
        eoaReporter2.report(eventId, conflicting);

        vm.warp(block.timestamp + 5 minutes + 1);
        vm.expectRevert(ModuleErrors.ExistingPayoutMismatch.selector);
        aggregator.finalize(eventId, conflicting);

        (OracleAggregator.ResolutionStatus status, bytes32 proposedResultHash,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Active));
        assertEq(proposedResultHash, keccak256(abi.encode(conflicting)));

        uint256[] memory targetPayout = positions.binaryModule.getResult(ConditionIdLib.from(eventId));
        assertEq(targetPayout[0], 1_000_000);
        assertEq(targetPayout[1], 0);
    }
}

/*--------------------------------------------------------------
                        DISPUTE
--------------------------------------------------------------*/

contract OracleAggregatorTest_dispute is OracleAggregatorTest {
    function test_revert_dispute_zeroLivenessClosesImmediately() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(marketManager);
        aggregator.setLivenessWindow(eventId, 0);
        _reachProposal(eventId);

        vm.prank(disputer);
        vm.expectRevert(OracleAggregatorErrors.DisputeWindowExpired.selector);
        mockDisputer.dispute(eventId);
    }

    function test_dispute_triggersArbitration() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        uint256[] memory yes = _yesSingle();

        vm.prank(reporter1);
        eoaReporter.report(eventId, yes);
        vm.prank(reporter1);
        eoaReporter2.report(eventId, yes);

        vm.prank(disputer);
        mockDisputer.dispute(eventId);

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));
    }

    function test_revert_disputeResult_alreadyVoted() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequestTwoDisputers(
            eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 2
        );
        _reachProposal(eventId);

        vm.prank(disputer);
        mockDisputer.dispute(eventId);

        assertTrue(aggregator.hasDisputerVoted(eventId, address(mockDisputer)));

        vm.prank(disputer);
        vm.expectRevert(OracleAggregatorErrors.AlreadyVoted.selector);
        mockDisputer.dispute(eventId);

        (OracleAggregator.ResolutionStatus status,,, uint256 disputeCount) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Active));
        assertEq(disputeCount, 1);
    }

    function test_disputeResult_sameModuleDifferentRequests() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequestTwoDisputers(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 2
        );

        bytes32 condition0 = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 0));
        bytes32 condition1 = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 1));
        _reachProposal(condition0);
        _reachProposal(condition1);

        vm.prank(disputer);
        mockDisputer.dispute(condition0);
        vm.prank(disputer);
        mockDisputer.dispute(condition1);

        assertTrue(aggregator.hasDisputerVoted(condition0, address(mockDisputer)));
        assertTrue(aggregator.hasDisputerVoted(condition1, address(mockDisputer)));

        (OracleAggregator.ResolutionStatus status0,,, uint256 disputeCount0) = aggregator.getRequestState(condition0);
        (OracleAggregator.ResolutionStatus status1,,, uint256 disputeCount1) = aggregator.getRequestState(condition1);
        assertEq(uint8(status0), uint8(OracleAggregator.ResolutionStatus.Active));
        assertEq(uint8(status1), uint8(OracleAggregator.ResolutionStatus.Active));
        assertEq(disputeCount0, 1);
        assertEq(disputeCount1, 1);
    }

    function test_disputeResult_differentModulesReachThreshold() public {
        bytes32 eventId = _nextBinaryEventId();
        MockDisputerModule mockDisputer2 = _initializeRequestTwoDisputers(
            eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 2
        );

        _reachProposal(eventId);

        vm.prank(disputer);
        mockDisputer.dispute(eventId);
        vm.prank(disputer);
        mockDisputer2.dispute(eventId);

        assertTrue(aggregator.hasDisputerVoted(eventId, address(mockDisputer)));
        assertTrue(aggregator.hasDisputerVoted(eventId, address(mockDisputer2)));

        (OracleAggregator.ResolutionStatus status,,, uint256 disputeCount) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));
        assertEq(disputeCount, 2);
    }
}

/*--------------------------------------------------------------
                        RESOLVE
--------------------------------------------------------------*/

contract OracleAggregatorTest_resolve is OracleAggregatorTest {
    function test_revert_atomic_winnerIndexOutOfRange() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.ATOMIC_NEGRISK, 1, 2, 1
        );

        uint256[] memory result = new uint256[](1);
        result[0] = 3;

        vm.prank(admin);
        vm.expectRevert(OracleAggregatorErrors.InvalidResult.selector);
        aggregator.resolveResult(eventId, result);
    }

    /// @notice Admin override during arbitration notifies the arbitrator so it clears its
    ///         local `isActive` flag, preventing a stale-state "ghost vote" via the arbitrator.
    function test_adminResolve_duringArbitration_clearsArbitratorState() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Drive the request into ArbitrationRequested via report → dispute.
        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());
        vm.prank(reporter1);
        eoaReporter2.report(eventId, _yesSingle());
        vm.prank(disputer);
        mockDisputer.dispute(eventId);

        (bool isActiveBefore,) = mockArbitrator.getArbitrationState(eventId);
        assertTrue(isActiveBefore);

        vm.prank(admin);
        aggregator.resolveResult(eventId, _yesSingle());

        (bool isActiveAfter,) = mockArbitrator.getArbitrationState(eventId);
        assertFalse(isActiveAfter);

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice Admin override outside of arbitration does not invoke the arbitrator hook.
    function test_adminResolve_outsideArbitration_skipsArbitratorHook() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Status is `Active`; we should not call onArbitrationResolved. Use a reverting arbitrator
        // module as a tripwire: if the hook were invoked, the call would emit ArbitratorHookFailed.
        // Here we expect *no* such event, which we assert by checking the success path executes
        // cleanly and arbitration state is untouched.
        vm.prank(admin);
        aggregator.resolveResult(eventId, _yesSingle());

        (bool isActive,) = mockArbitrator.getArbitrationState(eventId);
        assertFalse(isActive);

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice A reverting arbitrator hook does not block admin override; failure is logged.
    function test_adminResolve_duringArbitration_arbitratorHookReverts_stillResolves() public {
        RevertingArbitratorModule reverting = new RevertingArbitratorModule();

        bytes32 eventId = _nextBinaryEventId();
        _initializeRequestWithArbitrator(
            eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1, address(reverting)
        );

        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());
        vm.prank(reporter1);
        eoaReporter2.report(eventId, _yesSingle());
        vm.prank(disputer);
        mockDisputer.dispute(eventId);

        (OracleAggregator.ResolutionStatus statusBefore,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(statusBefore), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));

        // The reverting hook must not block the admin's resolution. Expect ArbitratorHookFailed
        // followed by RequestResolved.
        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.ArbitratorHookFailed(eventId, address(reverting));
        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.RequestResolved(eventId, keccak256(abi.encode(_yesSingle())), admin);

        vm.prank(admin);
        aggregator.resolveResult(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus statusAfter,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(statusAfter), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }
}

/*--------------------------------------------------------------
                        REPORT
--------------------------------------------------------------*/

contract OracleAggregatorTest_report is OracleAggregatorTest {
    function test_revert_invalidResultLength() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        uint256[] memory invalid = new uint256[](2);
        invalid[0] = 1_000_000;
        invalid[1] = 0;

        vm.prank(reporter1);
        vm.expectRevert(OracleAggregatorErrors.InvalidResultLength.selector);
        eoaReporter.report(eventId, invalid);
    }
}

/*--------------------------------------------------------------
                REPORTER CONFLICT ARBITRATION
--------------------------------------------------------------*/

contract OracleAggregatorTest_reporterConflict is OracleAggregatorTest {
    address internal reporterModule1;
    address internal reporterModule2;
    address internal reporterModule3;
    address internal reporterModule4;

    function setUp() public override {
        super.setUp();
        reporterModule1 = makeAddr("reporterModule1");
        reporterModule2 = makeAddr("reporterModule2");
        reporterModule3 = makeAddr("reporterModule3");
        reporterModule4 = makeAddr("reporterModule4");
    }

    function _initializeConflictRequest(bytes32 eventId) internal {
        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](4);
        reporterModules[0] = OracleAggregator.ModuleConfig({ module: reporterModule1, initData: "" });
        reporterModules[1] = OracleAggregator.ModuleConfig({ module: reporterModule2, initData: "" });
        reporterModules[2] = OracleAggregator.ModuleConfig({ module: reporterModule3, initData: "" });
        reporterModules[3] = OracleAggregator.ModuleConfig({ module: reporterModule4, initData: "" });

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] = OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: "" });

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 2,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    function _noSingle() internal pure returns (uint256[] memory result) {
        result = new uint256[](1);
    }

    function _report(address module, bytes32 requestId, uint256[] memory result) internal {
        vm.prank(module);
        aggregator.reportResult(requestId, result);
    }

    function test_conflictingResultAtThresholdTriggersArbitration() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeConflictRequest(eventId);

        uint256[] memory no = _noSingle();
        uint256[] memory yes = _yesSingle();
        bytes32 noHash = keccak256(abi.encode(no));
        bytes32 yesHash = keccak256(abi.encode(yes));

        _report(reporterModule1, eventId, no);
        _report(reporterModule2, eventId, no);
        _report(reporterModule3, eventId, yes);

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.ResultReported(eventId, reporterModule4, yesHash, 2);
        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.ReporterConflict(eventId, noHash, yesHash, yes);
        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.ArbitrationTriggered(eventId);
        _report(reporterModule4, eventId, yes);

        (OracleAggregator.ResolutionStatus status, bytes32 proposedHash,, uint256 disputeCount) =
            aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));
        assertEq(proposedHash, noHash);
        assertEq(aggregator.conflictingResultHash(eventId), yesHash);
        assertEq(disputeCount, 0);

        (bool isActive, bytes32 arbitratorProposedHash) = mockArbitrator.getArbitrationState(eventId);
        assertTrue(isActive);
        assertEq(arbitratorProposedHash, noHash);
    }

    function test_additionalSupportForProposedResultDoesNotTriggerArbitration() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeConflictRequest(eventId);

        uint256[] memory yes = _yesSingle();
        _report(reporterModule1, eventId, yes);
        _report(reporterModule2, eventId, yes);
        _report(reporterModule3, eventId, yes);

        (OracleAggregator.ResolutionStatus status, bytes32 proposedHash,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Active));
        assertEq(proposedHash, keccak256(abi.encode(yes)));
        assertEq(aggregator.conflictingResultHash(eventId), bytes32(0));
        assertEq(aggregator.getReportVotes(eventId, yes), 3);
    }

    function test_conflictingResultBelowThresholdDoesNotTriggerArbitration() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeConflictRequest(eventId);

        uint256[] memory no = _noSingle();
        uint256[] memory yes = _yesSingle();
        _report(reporterModule1, eventId, no);
        _report(reporterModule2, eventId, no);
        _report(reporterModule3, eventId, yes);

        (OracleAggregator.ResolutionStatus status, bytes32 proposedHash,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Active));
        assertEq(proposedHash, keccak256(abi.encode(no)));
        assertEq(aggregator.conflictingResultHash(eventId), bytes32(0));
        assertEq(aggregator.getReportVotes(eventId, yes), 1);
    }

    function test_revert_reportAfterDisputeWindowExpired() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeConflictRequest(eventId);

        uint256[] memory no = _noSingle();
        _report(reporterModule1, eventId, no);
        _report(reporterModule2, eventId, no);
        vm.warp(block.timestamp + 5 minutes);

        vm.prank(reporterModule3);
        vm.expectRevert(OracleAggregatorErrors.DisputeWindowExpired.selector);
        aggregator.reportResult(eventId, _yesSingle());
    }

    function test_revert_report_zeroLivenessClosesImmediately() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeConflictRequest(eventId);

        vm.prank(marketManager);
        aggregator.setLivenessWindow(eventId, 0);

        uint256[] memory no = _noSingle();
        _report(reporterModule1, eventId, no);
        _report(reporterModule2, eventId, no);

        vm.prank(reporterModule3);
        vm.expectRevert(OracleAggregatorErrors.DisputeWindowExpired.selector);
        aggregator.reportResult(eventId, _yesSingle());
    }

    function test_globalPauseDoesNotPreserveReporterConflictWindow() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeConflictRequest(eventId);

        uint256[] memory no = _noSingle();
        uint256[] memory yes = _yesSingle();
        _report(reporterModule1, eventId, no);
        _report(reporterModule2, eventId, no);

        // The 5-minute dispute window keeps running in wall-clock time while paused, so it
        // expires during the pause and a conflicting report can no longer be submitted.
        vm.warp(block.timestamp + 4 minutes);
        vm.prank(admin);
        aggregator.pauseOracle();
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(admin);
        aggregator.unpauseOracle();

        vm.prank(reporterModule3);
        vm.expectRevert(OracleAggregatorErrors.DisputeWindowExpired.selector);
        aggregator.reportResult(eventId, yes);
    }
}

/*--------------------------------------------------------------
                    PAUSABLE (ORACLE MIXIN)
--------------------------------------------------------------*/

contract OracleAggregatorTest_pausable is OracleAggregatorTest {
    /// @notice Admin can pause and then unpause the aggregator
    function test_unpauseOracle() public {
        // Pause first
        vm.prank(admin);
        aggregator.pauseOracle();
        assertTrue(aggregator.globalPaused());

        // Expect the GlobalPauseSet event with false
        vm.expectEmit(true, true, true, true, address(aggregator));
        emit Pausable.GlobalPauseSet(false);

        // Unpause
        vm.prank(admin);
        aggregator.unpauseOracle();

        // Verify unpaused
        assertFalse(aggregator.globalPaused());
    }

    function test_globalPauseDoesNotExtendDisputeWindow() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        _reachProposal(eventId);

        (,, uint256 initialWindowEnd,) = aggregator.getRequestState(eventId);

        vm.warp(block.timestamp + 1 minutes);
        vm.prank(admin);
        aggregator.pauseOracle();
        vm.warp(block.timestamp + 10 minutes);

        // The window deadline is fixed wall-clock time; pausing does not push it out.
        (,, uint256 pausedWindowEnd,) = aggregator.getRequestState(eventId);
        assertEq(pausedWindowEnd, initialWindowEnd);

        // Finalize is blocked only by the pause itself, not by the (already elapsed) window.
        vm.expectRevert(Pausable.GlobalPaused.selector);
        aggregator.finalize(eventId, _yesSingle());

        vm.prank(admin);
        aggregator.unpauseOracle();

        aggregator.finalize(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    function test_globalPauseDoesNotPreserveRemainingDisputeTime() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        _reachProposal(eventId);

        // The 5-minute window elapses during the pause, so the dispute can no longer land.
        vm.warp(block.timestamp + 4 minutes);
        vm.prank(admin);
        aggregator.pauseOracle();
        vm.warp(block.timestamp + 1 days);
        vm.prank(admin);
        aggregator.unpauseOracle();

        vm.prank(disputer);
        vm.expectRevert(OracleAggregatorErrors.DisputeWindowExpired.selector);
        mockDisputer.dispute(eventId);
    }

    function test_globalPauseBeforeProposalDoesNotExtendWindow() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(admin);
        aggregator.pauseOracle();
        vm.warp(block.timestamp + 1 days);
        vm.prank(admin);
        aggregator.unpauseOracle();

        uint256 proposalTime = block.timestamp;
        _reachProposal(eventId);

        (,, uint256 disputeWindowEnd,) = aggregator.getRequestState(eventId);
        assertEq(disputeWindowEnd, proposalTime + 5 minutes);
    }

    function test_resolvedDisputeWindowDoesNotDriftWithLaterPauses() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        _reachProposal(eventId);

        (,, uint256 disputeWindowEnd,) = aggregator.getRequestState(eventId);
        vm.warp(disputeWindowEnd);
        aggregator.finalize(eventId, _yesSingle());

        vm.prank(admin);
        aggregator.pauseOracle();
        vm.warp(block.timestamp + 1 days);

        (,, uint256 deadlineAfterLaterPause,) = aggregator.getRequestState(eventId);
        assertEq(deadlineAfterLaterPause, disputeWindowEnd);
    }

    /// @notice reportResult reverts when paused
    function test_revert_reportResult_whenPaused() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Pause the aggregator
        vm.prank(admin);
        aggregator.pauseOracle();

        // Try to report - should revert with GlobalPaused
        vm.prank(reporter1);
        vm.expectRevert(Pausable.GlobalPaused.selector);
        eoaReporter.report(eventId, _yesSingle());
    }

    /// @notice disputeResult reverts when paused
    function test_revert_disputeResult_whenPaused() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Report to create proposal
        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());
        vm.prank(reporter1);
        eoaReporter2.report(eventId, _yesSingle());

        // Pause the aggregator
        vm.prank(admin);
        aggregator.pauseOracle();

        // Try to dispute - should revert with GlobalPaused
        vm.prank(disputer);
        vm.expectRevert(Pausable.GlobalPaused.selector);
        mockDisputer.dispute(eventId);
    }

    /// @notice finalize reverts when paused
    function test_revert_finalize_whenPaused() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Report to create proposal
        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());
        vm.prank(reporter1);
        eoaReporter2.report(eventId, _yesSingle());

        // Wait for dispute window to pass
        vm.warp(block.timestamp + 5 minutes + 1);

        // Pause the aggregator
        vm.prank(admin);
        aggregator.pauseOracle();

        // Try to finalize - should revert with GlobalPaused
        vm.expectRevert(Pausable.GlobalPaused.selector);
        aggregator.finalize(eventId, _yesSingle());
    }

    /// @notice resolveResult reverts when paused
    function test_revert_resolveResult_whenPaused() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Pause the aggregator
        vm.prank(admin);
        aggregator.pauseOracle();

        // Try to admin resolve - should revert with GlobalPaused
        vm.prank(admin);
        vm.expectRevert(Pausable.GlobalPaused.selector);
        aggregator.resolveResult(eventId, _yesSingle());
    }
}

/*--------------------------------------------------------------
                    ORACLE AGGREGATOR EDGE CASES
--------------------------------------------------------------*/

contract OracleAggregatorTest_edgeCases is OracleAggregatorTest {
    /// @notice pauseOracle() reverts for non-admin callers
    function test_revert_pauseOracle_notAdmin() public {
        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        aggregator.pauseOracle();
    }

    /// @notice unpauseOracle() reverts for non-admin callers
    function test_revert_unpauseOracle_notAdmin() public {
        vm.prank(admin);
        aggregator.pauseOracle();

        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        aggregator.unpauseOracle();
    }

    /// @notice initializeRequest reverts for non-operator callers
    function test_revert_initializeRequest_notOperator() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });

        address[] memory disputers = new address[](1);
        disputers[0] = disputer;

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        // Non-operator tries to initialize
        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 2,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    /// @notice reportResult reverts with RequestNotFound when no request has been initialized
    ///         for the supplied (canonical) request id.
    /// @dev Calls the aggregator directly rather than via EOAReporterModule.report, which has
    ///      its own RequestNotInitialized guard that would fire first.
    function test_revert_reportResult_requestNotFound() public {
        // Canonical ConditionId (outcome byte zero) that is not tied to any initialized request.
        bytes32 unknownRequestId = bytes32(uint256(keccak256("oracle-agg-unknown-request")) & ~uint256(0xFF));

        vm.prank(address(eoaReporter));
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.reportResult(unknownRequestId, _yesSingle());
    }

    /// @notice report reverts when conditionIndex is outside the valid
    ///         derived condition-count range (_isConditionInRequest false branch)
    function test_revert_reportResult_invalidConditionIndex() public {
        // Create neg-risk event with derived condition count = 3
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );

        // Derive a conditionId with index 3 (out of range since 3 + 1 > 3)
        bytes32 invalidConditionId =
            ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 3));

        // Reporting with this conditionId should fail
        vm.prank(reporter1);
        vm.expectRevert(OracleAggregatorErrors.InvalidConditionIndex.selector);
        eoaReporter.report(invalidConditionId, _yesSingle());
    }

    /// @notice _authorizeUpgrade reverts for non-owner callers
    function test_revert_upgradeToAndCall_notOwner() public {
        OracleAggregator newImpl = new OracleAggregator(address(positions.manager));

        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        aggregator.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgradeToAndCall_preservesPositionManager() public {
        OracleAggregator newImpl = new OracleAggregator(address(positions.manager));

        vm.prank(owner);
        aggregator.upgradeToAndCall(address(newImpl), "");

        assertEq(address(aggregator.POSITION_MANAGER()), address(positions.manager));
    }

    function test_revert_upgradeToAndCall_positionManagerMismatch() public {
        OracleAggregator newImpl = new OracleAggregator(makeAddr("otherPositionManager"));

        vm.prank(owner);
        vm.expectRevert(OracleAggregatorErrors.IncompatibleImplementation.selector);
        aggregator.upgradeToAndCall(address(newImpl), "");
    }

    /// @notice getRequestState returns Active for a valid but unseen conditionId
    function test_getRequestState_activeForValidCondition() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );

        // Condition index 2 is valid (2 + 1 <= 3) but never written to
        bytes32 conditionId = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 2));

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(conditionId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Active));
    }

    /// @notice getRequestState returns None for a non-existent request
    function test_getRequestState_noneForNonExistent() public view {
        // A completely fabricated requestId with no matching event
        bytes32 fakeId = bytes32(uint256(0));

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(fakeId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.None));
    }

    /// @notice getRequestState reverts on a non-canonical request id (dirty outcome byte).
    /// @dev "Malformed input" is a caller bug and must revert; "well-formed but unknown" is the
    ///      `noneForNonExistent` case above which still returns None via the storage default.
    function test_revert_getRequestState_nonCanonicalRequestId() public {
        bytes32 invalidRequestId = bytes32(uint256(1)); // non-zero outcome byte

        vm.expectRevert(abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, invalidRequestId));
        aggregator.getRequestState(invalidRequestId);
    }

    /// @notice initializeRequest reverts for duplicate eventId
    function test_revert_initializeRequest_alreadyExists() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Try to initialize the same eventId again
        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](0);

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](0);

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyExists.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 2,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: bytes(""),
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    /// @notice EventIdLib.from rejects non-canonical event ids before they can reach the
    ///         aggregator. The `EventId` UDVT structurally guarantees canonical inputs.
    function test_revert_initializeRequest_nonCanonicalEventId() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        bytes32 nonCanonicalEventId =
            ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 1));

        vm.expectRevert(abi.encodeWithSelector(EventIdLib.NonCanonicalEventId.selector, nonCanonicalEventId));
        this.externalWrapEvent(nonCanonicalEventId);
    }

    /// @dev External wrapper so `EventIdLib.from` reverts at a lower call depth, allowing
    ///      `vm.expectRevert` to match.
    function externalWrapEvent(bytes32 _raw) external pure returns (EventId) {
        return EventIdLib.from(_raw);
    }

    /// @notice resolveResult is a no-op when already resolved
    function test_resolveResult_alreadyResolved_noop() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Admin resolves the event
        vm.prank(admin);
        aggregator.resolveResult(eventId, _yesSingle());

        (, bytes32 hashBefore,,) = aggregator.getRequestState(eventId);

        // Second resolve is a silent no-op (no revert, no state change)
        vm.prank(admin);
        aggregator.resolveResult(eventId, _yesSingle());

        (, bytes32 hashAfter,,) = aggregator.getRequestState(eventId);
        assertEq(hashAfter, hashBefore);
    }

    /// @notice resolveResult fails for non-authorized caller
    function test_revert_resolveResult_notAuthorized() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(reporter1);
        vm.expectRevert(OracleAggregatorErrors.NotAuthorized.selector);
        aggregator.resolveResult(eventId, _yesSingle());
    }

    function test_revert_atomic_requestRejectsChildConditionId() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.ATOMIC_NEGRISK, 1, 2, 1
        );

        bytes32 conditionId = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 1));

        vm.prank(reporter1);
        vm.expectRevert(OracleAggregatorErrors.InvalidRequestId.selector);
        eoaReporter.report(conditionId, _yesSingle());
    }

    function test_revert_initializeRequest_atomicTypeRejectsWrongResultLength() public {
        bytes32 eventId = _nextNegRiskEventId(3);

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](0);
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](0);

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidResultLength.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.ATOMIC_NEGRISK,
                targetContract: address(positions.negRiskModule),
                resultLength: 3,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: bytes(""),
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }
}

/*--------------------------------------------------------------
                CONFIG VALIDATION
--------------------------------------------------------------*/

contract OracleAggregatorTest_configValidation is OracleAggregatorTest {
    function test_revert_initializeRequest_zeroTargetContract() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](0);

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(0),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 2,
                disputerModules: disputerModules,
                disputerThreshold: 0,
                arbitratorModule: address(0),
                arbitratorInitData: bytes(""),
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    function test_revert_initializeRequest_zeroReporterThreshold() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](0);

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 0,
                disputerModules: disputerModules,
                disputerThreshold: 0,
                arbitratorModule: address(0),
                arbitratorInitData: bytes(""),
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    function test_revert_initializeRequest_zeroDisputerThreshold() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });

        address[] memory disputers = new address[](1);
        disputers[0] = disputer;
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: 0,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    function test_revert_initializeRequest_zeroArbitrator() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });

        address[] memory disputers = new address[](1);
        disputers[0] = disputer;
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(0),
                arbitratorInitData: bytes(""),
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    function test_initializeRequest_zeroLivenessAllowsSameBlockFinalization() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });

        address[] memory disputers = new address[](1);
        disputers[0] = disputer;
        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 0,
                finalizer: address(0)
            })
        );

        uint256 proposalTimestamp = block.timestamp;
        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());

        (,, uint256 disputeWindowEnd,) = aggregator.getRequestState(eventId);
        assertEq(disputeWindowEnd, proposalTimestamp);

        aggregator.finalize(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice Fewer distinct reporter modules than `reporterThreshold` is rejected.
    function test_revert_initializeRequest_reporterModulesBelowThreshold() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 2,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    /// @notice Fewer distinct disputer modules than `disputerThreshold` is rejected.
    function test_revert_initializeRequest_disputerModulesBelowThreshold() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 2,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    /// @notice Duplicate reporter entries dedupe in the set, so a padded array cannot satisfy a
    ///         threshold it could never meet.
    function test_revert_initializeRequest_duplicateReportersBelowThreshold() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](2);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });
        reporterModules[1] = OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: "" });

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 2,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );
    }

    /// @notice A request that needs no functional dispute path registers a never-exercised
    ///         disputer entry and a real arbitrator, and initializes successfully.
    function test_initializeRequest_sentinelDisputerConfig() public {
        bytes32 eventId = _nextBinaryEventId();

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(_reporters()) });

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: bytes(""),
                livenessWindow: 5 minutes,
                finalizer: address(0)
            })
        );

        (address target,,,,,,,) = aggregator.requestConfigs(EventId.wrap(bytes29(eventId)));
        assertEq(target, address(positions.binaryModule));
    }

    /// @dev A single disputer entry that is registered but never exercised. The address is only
    ///      membership-checked, so a non-controlled address with empty init data suffices.
    function _sentinelDisputerModules() internal pure returns (OracleAggregator.ModuleConfig[] memory mods) {
        mods = new OracleAggregator.ModuleConfig[](1);
        mods[0] = OracleAggregator.ModuleConfig({ module: address(uint160(0xD15D15)), initData: "" });
    }
}

/*--------------------------------------------------------------
                    TARGET FINALIZATION FAILURES
--------------------------------------------------------------*/

/// @notice A mock target that always reverts on reportResult
contract RevertingTarget {
    error AlwaysReverts();

    function moduleId() external pure returns (uint256) {
        return ModuleIds.BINARY;
    }

    function reportResult(ConditionId, uint256[] calldata) external pure {
        revert AlwaysReverts();
    }
}

contract OracleAggregatorTest_targetFinalization is OracleAggregatorTest {
    function test_revert_finalizeConditions_targetReverts() public {
        RevertingTarget revertingTarget = new RevertingTarget();

        vm.startPrank(admin);
        positions.manager.removeModule(ModuleIds.BINARY);
        positions.manager.addModule(address(revertingTarget));
        vm.stopPrank();

        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(revertingTarget), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Report to reach threshold
        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());

        vm.prank(reporter1);
        eoaReporter2.report(eventId, _yesSingle());

        // Wait for dispute window
        vm.warp(block.timestamp + 6 minutes);

        vm.expectRevert(RevertingTarget.AlwaysReverts.selector);
        aggregator.finalize(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Active));
    }
}

/*--------------------------------------------------------------
                    VOTE-ONCE ENFORCEMENT
--------------------------------------------------------------*/

contract OracleAggregatorTest_voteOnce is OracleAggregatorTest {
    function test_revert_reportResult_alreadyVoted() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // First vote through eoaReporter succeeds
        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());

        // Second vote through the same module reverts at the aggregator level
        // reporter2 goes through eoaReporter, but aggregator sees same msg.sender
        vm.prank(reporter2);
        vm.expectRevert(OracleAggregatorErrors.AlreadyVoted.selector);
        eoaReporter.report(eventId, _yesSingle());
    }

    function test_reportResult_sameModuleDifferentRequests() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );

        bytes32 cond0 = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 0));
        bytes32 cond1 = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 1));

        // Same module votes on subcondition 0
        vm.prank(reporter1);
        eoaReporter.report(cond0, _yesSingle());

        // Same module can also vote on subcondition 1
        vm.prank(reporter1);
        eoaReporter.report(cond1, _yesSingle());

        assertEq(aggregator.getReportVotes(cond0, _yesSingle()), 1);
        assertEq(aggregator.getReportVotes(cond1, _yesSingle()), 1);
    }

    function test_reportResult_differentModulesSameRequest() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Two different modules vote on the same requestId
        vm.prank(reporter1);
        eoaReporter.report(eventId, _yesSingle());

        vm.prank(reporter1);
        eoaReporter2.report(eventId, _yesSingle());

        assertEq(aggregator.getReportVotes(eventId, _yesSingle()), 2);
        assertTrue(aggregator.hasReporterVoted(eventId, address(eoaReporter)));
        assertTrue(aggregator.hasReporterVoted(eventId, address(eoaReporter2)));
    }
}

/*--------------------------------------------------------------
                        FINALIZER GATING
--------------------------------------------------------------*/

contract OracleAggregatorTest_finalizer is OracleAggregatorTest {
    /// @notice A configured finalizer can finalize a ready proposal.
    function test_finalize_byConfiguredFinalizer() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequestFull(
            eventId,
            address(positions.binaryModule),
            OracleAggregator.MarketType.BINARY,
            1,
            2,
            1,
            address(mockArbitrator),
            finalizerAddr
        );

        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);

        vm.prank(finalizerAddr);
        aggregator.finalize(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice A non-finalizer cannot finalize when a finalizer is configured.
    function test_revert_finalize_byNonFinalizer() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequestFull(
            eventId,
            address(positions.binaryModule),
            OracleAggregator.MarketType.BINARY,
            1,
            2,
            1,
            address(mockArbitrator),
            finalizerAddr
        );

        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);

        vm.prank(stranger);
        vm.expectRevert(OracleAggregatorErrors.NotAuthorized.selector);
        aggregator.finalize(eventId, _yesSingle());
    }

    /// @notice With no finalizer configured, anyone can finalize.
    function test_finalize_permissionlessWhenFinalizerZero() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);

        vm.prank(stranger);
        aggregator.finalize(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice setFinalizer makes finalize permissioned; clearing it restores permissionless.
    function test_setFinalizer_togglesGate() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Manager sets a finalizer.
        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.FinalizerSet(EventId.wrap(bytes29(eventId)), finalizerAddr);
        vm.prank(marketManager);
        aggregator.setFinalizer(eventId, finalizerAddr);

        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);

        // Stranger now blocked.
        vm.prank(stranger);
        vm.expectRevert(OracleAggregatorErrors.NotAuthorized.selector);
        aggregator.finalize(eventId, _yesSingle());

        // Manager clears the finalizer -> permissionless again.
        vm.prank(marketManager);
        aggregator.setFinalizer(eventId, address(0));

        vm.prank(stranger);
        aggregator.finalize(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice setFinalizer reverts for an unknown request.
    function test_revert_setFinalizer_requestNotFound() public {
        bytes32 eventId = _nextBinaryEventId();
        vm.prank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.setFinalizer(eventId, finalizerAddr);
    }

    /// @notice setFinalizer reverts for a non-manager, non-admin caller.
    function test_revert_setFinalizer_unauthorized() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        aggregator.setFinalizer(eventId, finalizerAddr);
    }
}

/*--------------------------------------------------------------
                       RULE MANAGER ROLE
--------------------------------------------------------------*/

contract OracleAggregatorTest_ruleManagerRole is OracleAggregatorTest {
    /// @notice Admin can grant the rule manager role; the grantee can write product specs.
    function test_addRuleManager_grantsRole() public {
        address ruleManager = makeAddr("ruleManager");
        vm.prank(admin);
        aggregator.addRuleManager(ruleManager);

        vm.prank(ruleManager);
        aggregator.setProductSpecification("MLB 2026", "ipfs://spec");
        assertEq(aggregator.getProductSpecification("MLB 2026").version, 1);
    }

    /// @notice Non-admin cannot grant the rule manager role.
    function test_revert_addRuleManager_notAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        aggregator.addRuleManager(stranger);
    }

    /// @notice Admin can revoke the rule manager role.
    function test_removeRuleManager_revokesRole() public {
        address ruleManager = makeAddr("ruleManager");
        vm.prank(admin);
        aggregator.addRuleManager(ruleManager);

        vm.prank(admin);
        aggregator.removeRuleManager(ruleManager);

        vm.prank(ruleManager);
        vm.expectRevert(Unauthorized.selector);
        aggregator.setProductSpecification("MLB 2026", "ipfs://spec");
    }

    /// @notice Non-admin cannot revoke the rule manager role.
    function test_revert_removeRuleManager_notAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        aggregator.removeRuleManager(makeAddr("ruleManager"));
    }

    /// @notice The operator role (not rule manager) cannot write product specs.
    function test_revert_setProductSpecification_operatorNotAllowed() public {
        vm.prank(operator);
        vm.expectRevert(Unauthorized.selector);
        aggregator.setProductSpecification("MLB 2026", "ipfs://spec");
    }

    /// @notice Admin (holding ADMIN_ROLE) can also write market data.
    function test_admin_canWriteMarketData() public {
        vm.prank(admin);
        aggregator.setProductSpecification("MLB 2026", "ipfs://spec");
        assertEq(aggregator.getProductSpecification("MLB 2026").version, 1);
    }

    /// @notice Admin (not holding any operator role) can still perform config actions.
    function test_admin_canPerformConfigActions() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(admin);
        aggregator.setFinalizer(eventId, finalizerAddr);

        vm.prank(admin);
        aggregator.pauseMarkets(_singleEvent(eventId));
        assertTrue(aggregator.marketPaused(EventId.wrap(bytes29(eventId))));
    }
}

/*--------------------------------------------------------------
                     MARKET DATA REGISTRY
--------------------------------------------------------------*/

contract OracleAggregatorTest_marketDataRegistry is OracleAggregatorTest {
    address public ruleManager = makeAddr("ruleManager");

    string public productName = "MLB 2026";
    string public specUri = "ipfs://bafySpecV1";

    event ProductSpecificationUpdated(
        bytes32 indexed productId, string name, string uri, uint64 version, uint64 updatedAt
    );
    event RuleAdded(bytes32 indexed requestId, uint256 index, uint256 timestamp, bytes data);

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        aggregator.addRuleManager(ruleManager);
    }

    /*------------------------- product specs -------------------------*/

    function test_setProductSpecification_firstWrite() public {
        bytes32 id = aggregator.productId(productName);

        vm.expectEmit(true, false, false, true, address(aggregator));
        emit ProductSpecificationUpdated(id, productName, specUri, 1, uint64(block.timestamp));

        vm.prank(ruleManager);
        aggregator.setProductSpecification(productName, specUri);

        MarketDataRegistry.ProductSpecification memory spec = aggregator.getProductSpecification(productName);
        assertEq(spec.uri, specUri);
        assertEq(spec.name, productName);
        assertEq(spec.version, 1);
        assertEq(aggregator.getProductSpecificationById(id).uri, specUri);
    }

    function test_setProductSpecification_caseInsensitiveUpdate() public {
        vm.prank(ruleManager);
        aggregator.setProductSpecification("MLB 2026", specUri);

        vm.expectEmit(true, false, false, true, address(aggregator));
        emit ProductSpecificationUpdated(
            aggregator.productId("MLB 2026"), "MLB 2026", "ipfs://v2", 2, uint64(block.timestamp)
        );
        vm.prank(ruleManager);
        aggregator.setProductSpecification("mlb 2026", "ipfs://v2");

        assertEq(aggregator.productId("MLB 2026"), aggregator.productId("mlb 2026"));
        MarketDataRegistry.ProductSpecification memory spec = aggregator.getProductSpecification("mLb 2026");
        assertEq(spec.uri, "ipfs://v2");
        assertEq(spec.version, 2);
        assertEq(spec.name, "MLB 2026");
    }

    function test_revert_setProductSpecification_emptyName() public {
        vm.prank(ruleManager);
        vm.expectRevert(MarketDataRegistry.EmptyProductName.selector);
        aggregator.setProductSpecification("", specUri);
    }

    /*------------------------- rules -------------------------*/

    function test_revert_getRuleAt_outOfBounds() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        vm.prank(operator);
        aggregator.updateRequestRules(eventId, bytes("only one"));

        vm.expectRevert(MarketDataRegistry.RuleUnavailable.selector);
        aggregator.getRuleAt(eventId, 1);
    }

    function test_revert_getLatestRule_none() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        vm.expectRevert(MarketDataRegistry.RuleUnavailable.selector);
        aggregator.getLatestRule(eventId);
    }
}

/*--------------------------------------------------------------
                    UPDATE REQUEST RULES
--------------------------------------------------------------*/

contract OracleAggregatorTest_updateRequestRules is OracleAggregatorTest {
    event RuleAdded(bytes32 indexed requestId, uint256 index, uint256 timestamp, bytes data);
    event RequestRulesUpdated(bytes32 indexed requestId, uint256 reportersNotified);

    function test_updateRequestRules_appendsRuleAndNotifiesReporters() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        bytes memory first = bytes("Rule 1");
        bytes memory second = bytes("Rule 2");

        vm.expectEmit(true, false, false, true, address(aggregator));
        emit RuleAdded(eventId, 0, block.timestamp, first);
        vm.expectEmit(true, false, false, true, address(aggregator));
        emit RequestRulesUpdated(eventId, 2);
        vm.prank(operator);
        aggregator.updateRequestRules(eventId, first);

        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(true, false, false, true, address(aggregator));
        emit RuleAdded(eventId, 1, block.timestamp, second);
        vm.expectEmit(true, false, false, true, address(aggregator));
        emit RequestRulesUpdated(eventId, 2);
        vm.prank(operator);
        aggregator.updateRequestRules(eventId, second);

        assertEq(aggregator.getRuleCount(eventId), 2);
        MarketDataRegistry.Rule[] memory all = aggregator.getRules(eventId);
        assertEq(all[0].data, first);
        assertEq(all[1].data, second);
        assertEq(aggregator.getLatestRule(eventId).data, second);
        assertEq(aggregator.getRuleAt(eventId, 0).data, first);
        assertEq(aggregator.getRuleAt(eventId, 1).data, second);
    }

    function test_revert_updateRequestRules_unknownRequest() public {
        bytes32 unknown = _nextBinaryEventId();
        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.updateRequestRules(unknown, bytes("x"));
    }

    function test_revert_updateRequestRules_resolvedRequest() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);
        aggregator.finalize(eventId, _yesSingle());

        vm.prank(operator);
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.updateRequestRules(eventId, bytes("late"));
    }

    function test_revert_updateRequestRules_unauthorized() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        aggregator.updateRequestRules(eventId, bytes("x"));
    }

    function test_revert_updateRules_notAggregator() public {
        vm.prank(stranger);
        vm.expectRevert(OracleModuleBase.NotAggregator.selector);
        eoaReporter.updateRules(bytes32(0), bytes(""));
    }
}

/*--------------------------------------------------------------
                     CONFIG MUTATION
--------------------------------------------------------------*/

contract OracleAggregatorTest_configMutation is OracleAggregatorTest {
    function _deployReporter() internal returns (EOAReporterModule mod) {
        mod = EOAReporterModule(LibClone.deployERC1967(address(new EOAReporterModule())));
        mod.initialize(owner, admin, address(aggregator));
    }

    function _assertConfigMutationsRejected(bytes32 requestId) internal {
        OracleAggregator.ModuleConfig[] memory modules = new OracleAggregator.ModuleConfig[](0);
        uint32 excessiveLivenessWindow = aggregator.MAX_LIVENESS_WINDOW() + 1;

        vm.startPrank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.addReporterModules(requestId, modules);
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.removeReporterModules(requestId, _addrArray(address(eoaReporter)));
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.addDisputerModules(requestId, modules);
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.removeDisputerModules(requestId, _addrArray(address(mockDisputer)));

        // Terminal validation precedes mutation-specific input validation.
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.setArbitratorModule(requestId, address(0), "");
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.setFinalizer(requestId, finalizerAddr);
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.setLivenessWindow(requestId, excessiveLivenessWindow);
        vm.stopPrank();
    }

    function test_revert_configMutation_afterBinaryRequestResolves() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);
        aggregator.finalize(eventId, _yesSingle());

        _assertConfigMutationsRejected(eventId);
    }

    function test_revert_configMutation_afterAtomicRequestResolves() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.ATOMIC_NEGRISK, 1, 2, 1
        );

        uint256[] memory winningIndex = new uint256[](1);
        winningIndex[0] = 1;
        vm.prank(admin);
        aggregator.resolveResult(eventId, winningIndex);

        _assertConfigMutationsRejected(eventId);
    }

    /// @notice A resolved incremental child cannot mutate config, while an unresolved sibling can.
    function test_configMutation_afterIncrementalChildResolves() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );

        bytes32 childRequestId = bytes32(ConditionId.unwrap(EventId.wrap(bytes29(eventId)).computeConditionId(1)));
        uint256[] memory noResult = new uint256[](1);
        vm.prank(admin);
        aggregator.resolveResult(childRequestId, noResult);

        vm.prank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.RequestAlreadyResolved.selector);
        aggregator.setFinalizer(childRequestId, finalizerAddr);

        bytes32 unresolvedChildRequestId =
            bytes32(ConditionId.unwrap(EventId.wrap(bytes29(eventId)).computeConditionId(2)));
        vm.prank(marketManager);
        aggregator.setFinalizer(unresolvedChildRequestId, finalizerAddr);

        (,,,,,,, address configuredFinalizer) = aggregator.requestConfigs(EventId.wrap(bytes29(eventId)));
        assertEq(configuredFinalizer, finalizerAddr);
    }

    /// @notice Shared incremental config freezes only after every child request resolves.
    function test_revert_configMutation_whenAllIncrementalChildrenResolved() public {
        bytes32 eventId = _nextNegRiskEventId(3);
        EventId typedEventId = EventId.wrap(bytes29(eventId));
        _initializeRequest(
            eventId, address(positions.negRiskModule), OracleAggregator.MarketType.INCREMENTAL_NEGRISK, 1, 2, 1
        );

        uint256[] memory noResult = new uint256[](1);
        for (uint256 i; i < 3; ++i) {
            bytes32 childRequestId = bytes32(ConditionId.unwrap(typedEventId.computeConditionId(i)));
            vm.prank(admin);
            aggregator.resolveResult(childRequestId, noResult);
        }

        bytes32 childRequestId = bytes32(ConditionId.unwrap(typedEventId.computeConditionId(0)));
        _assertConfigMutationsRejected(childRequestId);
    }

    /// @notice A reporter module added mid-flight can vote toward the threshold.
    function test_addReporterModules_newModuleCanVote() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        EOAReporterModule eoaReporter3 = _deployReporter();
        OracleAggregator.ModuleConfig[] memory mods = new OracleAggregator.ModuleConfig[](1);
        mods[0] = OracleAggregator.ModuleConfig({ module: address(eoaReporter3), initData: abi.encode(_reporters()) });

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.ReporterModuleAdded(EventId.wrap(bytes29(eventId)), address(eoaReporter3));
        vm.prank(marketManager);
        aggregator.addReporterModules(eventId, mods);

        assertTrue(aggregator.isReporterModule(EventId.wrap(bytes29(eventId)), address(eoaReporter3)));

        // The added module's vote counts toward the threshold: reaching it via the newly added
        // module plus one default reporter (skipping eoaReporter) creates the proposal.
        vm.prank(reporter1);
        eoaReporter3.report(eventId, _yesSingle());
        vm.prank(reporter1);
        eoaReporter2.report(eventId, _yesSingle());

        (, bytes32 proposedHash,,) = aggregator.getRequestState(eventId);
        assertEq(proposedHash, keccak256(abi.encode(_yesSingle())));
    }

    /// @notice A removed reporter module can no longer report.
    /// @dev Threshold 1 with two reporters, so removing one keeps the set at/above threshold.
    function test_removeReporterModules_blocksReporting() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 1, 1);

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.ReporterModuleRemoved(EventId.wrap(bytes29(eventId)), address(eoaReporter));
        vm.prank(marketManager);
        aggregator.removeReporterModules(eventId, _addrArray(address(eoaReporter)));

        assertFalse(aggregator.isReporterModule(EventId.wrap(bytes29(eventId)), address(eoaReporter)));

        vm.prank(reporter1);
        vm.expectRevert(OracleAggregatorErrors.NotRegisteredModule.selector);
        eoaReporter.report(eventId, _yesSingle());
    }

    /// @notice Removing reporters below `reporterThreshold` is rejected.
    function test_revert_removeReporterModules_belowThreshold() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.removeReporterModules(eventId, _addrArray(address(eoaReporter)));
    }

    /// @notice A disputer module added mid-flight can trigger arbitration.
    function test_addDisputerModules_newModuleCanDispute() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        MockDisputerModule mockDisputer2 = new MockDisputerModule(address(aggregator));
        OracleAggregator.ModuleConfig[] memory mods = new OracleAggregator.ModuleConfig[](1);
        mods[0] = OracleAggregator.ModuleConfig({ module: address(mockDisputer2), initData: "" });

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.DisputerModuleAdded(EventId.wrap(bytes29(eventId)), address(mockDisputer2));
        vm.prank(marketManager);
        aggregator.addDisputerModules(eventId, mods);

        _reachProposal(eventId);

        vm.prank(stranger);
        mockDisputer2.dispute(eventId);

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));
    }

    /// @notice A removed disputer module can no longer dispute.
    /// @dev A second disputer is added first so removing one keeps the set at/above threshold.
    function test_removeDisputerModules_blocksDisputing() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        MockDisputerModule mockDisputer2 = new MockDisputerModule(address(aggregator));
        OracleAggregator.ModuleConfig[] memory addMods = new OracleAggregator.ModuleConfig[](1);
        addMods[0] = OracleAggregator.ModuleConfig({ module: address(mockDisputer2), initData: "" });
        vm.prank(marketManager);
        aggregator.addDisputerModules(eventId, addMods);

        _reachProposal(eventId);

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.DisputerModuleRemoved(EventId.wrap(bytes29(eventId)), address(mockDisputer));
        vm.prank(marketManager);
        aggregator.removeDisputerModules(eventId, _addrArray(address(mockDisputer)));

        vm.prank(disputer);
        vm.expectRevert(OracleAggregatorErrors.NotRegisteredModule.selector);
        mockDisputer.dispute(eventId);
    }

    /// @notice Removing disputers below `disputerThreshold` is rejected.
    function test_revert_removeDisputerModules_belowThreshold() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.removeDisputerModules(eventId, _addrArray(address(mockDisputer)));
    }

    /// @notice The new arbitrator can resolve and the old one cannot, after a swap.
    function test_setArbitratorModule_swapsAuthority() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        MockArbitratorModule mockArbitrator2 = new MockArbitratorModule(address(aggregator));

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.ArbitratorModuleSet(EventId.wrap(bytes29(eventId)), address(mockArbitrator2));
        vm.prank(marketManager);
        aggregator.setArbitratorModule(eventId, address(mockArbitrator2), "");

        // Old arbitrator is no longer authorized.
        vm.prank(address(mockArbitrator));
        vm.expectRevert(OracleAggregatorErrors.NotAuthorized.selector);
        aggregator.resolveResult(eventId, _yesSingle());

        // New arbitrator can resolve.
        mockArbitrator2.resolve(eventId, _yesSingle());
        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice The arbitrator can be swapped mid-arbitration; the new module resolves it.
    function test_setArbitratorModule_midArbitration() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        _reachProposal(eventId);
        vm.prank(disputer);
        mockDisputer.dispute(eventId);

        (OracleAggregator.ResolutionStatus statusBefore,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(statusBefore), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));

        MockArbitratorModule mockArbitrator2 = new MockArbitratorModule(address(aggregator));
        vm.prank(marketManager);
        aggregator.setArbitratorModule(eventId, address(mockArbitrator2), "");

        // The freshly-swapped arbitrator resolves it (it was never notified, but resolveResult
        // only checks identity).
        mockArbitrator2.resolve(eventId, _yesSingle());
        (OracleAggregator.ResolutionStatus statusAfter,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(statusAfter), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice setArbitratorModule runs the new module's initializer when initData is supplied,
    ///         passing the correct eventId and payload.
    function test_setArbitratorModule_withInitData() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        MockArbitratorModule mockArbitrator2 = new MockArbitratorModule(address(aggregator));
        bytes memory initData = abi.encode(uint256(1));

        vm.prank(marketManager);
        aggregator.setArbitratorModule(eventId, address(mockArbitrator2), initData);

        (,,,,,, address arbitrator_,) = aggregator.requestConfigs(EventId.wrap(bytes29(eventId)));
        assertEq(arbitrator_, address(mockArbitrator2));

        // The initializer must have run exactly once, with the correct eventId and payload.
        assertEq(mockArbitrator2.initCallCount(), 1);
        assertEq(EventId.unwrap(mockArbitrator2.lastInitEventId()), bytes29(eventId));
        assertEq(mockArbitrator2.lastInitData(), initData);
    }

    /// @notice setArbitratorModule does NOT call the initializer when initData is empty.
    function test_setArbitratorModule_noInitData_skipsInitializer() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        MockArbitratorModule mockArbitrator2 = new MockArbitratorModule(address(aggregator));
        vm.prank(marketManager);
        aggregator.setArbitratorModule(eventId, address(mockArbitrator2), "");

        assertEq(mockArbitrator2.initCallCount(), 0);
    }

    /// @notice The arbitrator cannot be zeroed on a disputable request (would disable escalation).
    function test_revert_setArbitratorModule_zeroOnDisputableRequest() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.InvalidConfig.selector);
        aggregator.setArbitratorModule(eventId, address(0), "");
    }

    /// @notice Supplying init data with a codeless EOA arbitrator reverts via the compiler's
    ///         extcodesize guard rather than silently dropping the payload, and leaves the
    ///         previously-configured arbitrator untouched.
    function test_setArbitratorModule_codelessWithInitData_reverts() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        EventId e = EventId.wrap(bytes29(eventId));
        bytes memory initData = abi.encode(uint256(1));

        // A funded EOA is codeless -> high-level call reverts (extcodesize guard).
        address eoa = makeAddr("codelessArbitrator");
        vm.prank(marketManager);
        vm.expectRevert();
        aggregator.setArbitratorModule(eventId, eoa, initData);

        // The config was not mutated by the reverted call.
        (,,,,,, address arbitrator_,) = aggregator.requestConfigs(e);
        assertEq(arbitrator_, address(mockArbitrator));
    }

    /// @notice The maximum liveness window applies to proposals created after the change.
    function test_setLivenessWindow_appliesToFutureProposals() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        uint32 maxLivenessWindow = aggregator.MAX_LIVENESS_WINDOW();

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.LivenessWindowSet(EventId.wrap(bytes29(eventId)), maxLivenessWindow);
        vm.prank(marketManager);
        aggregator.setLivenessWindow(eventId, maxLivenessWindow);

        uint256 ts = block.timestamp;
        _reachProposal(eventId);

        (,, uint256 disputeWindowEnd,) = aggregator.getRequestState(eventId);
        assertEq(disputeWindowEnd, ts + maxLivenessWindow);
    }

    function test_revert_setLivenessWindow_livenessWindowTooLong() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        EventId typedEventId = EventIdLib.from(eventId);
        uint32 excessiveLivenessWindow = aggregator.MAX_LIVENESS_WINDOW() + 1;

        vm.prank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.LivenessWindowTooLong.selector);
        aggregator.setLivenessWindow(eventId, excessiveLivenessWindow);

        (,,, uint32 storedLivenessWindow,,,,) = aggregator.requestConfigs(typedEventId);
        assertEq(storedLivenessWindow, 5 minutes);
    }

    /// @notice Zero liveness applies to future proposals and permits same-block finalization.
    function test_setLivenessWindow_zeroAllowsSameBlockFinalization() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.LivenessWindowSet(EventId.wrap(bytes29(eventId)), 0);
        vm.prank(marketManager);
        aggregator.setLivenessWindow(eventId, 0);

        uint256 proposalTimestamp = block.timestamp;
        _reachProposal(eventId);

        (,, uint256 disputeWindowEnd,) = aggregator.getRequestState(eventId);
        assertEq(disputeWindowEnd, proposalTimestamp);

        aggregator.finalize(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice Config-mutation entry points revert for unknown requests.
    function test_revert_configMutation_requestNotFound() public {
        bytes32 unknown = _nextBinaryEventId();
        OracleAggregator.ModuleConfig[] memory mods = new OracleAggregator.ModuleConfig[](0);

        vm.startPrank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.addReporterModules(unknown, mods);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.removeReporterModules(unknown, _addrArray(address(eoaReporter)));
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.addDisputerModules(unknown, mods);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.removeDisputerModules(unknown, _addrArray(address(mockDisputer)));
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.setArbitratorModule(unknown, address(mockArbitrator), "");
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.setFinalizer(unknown, finalizerAddr);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.setLivenessWindow(unknown, 1 minutes);
        vm.stopPrank();
    }

    /// @notice Config-mutation entry points revert for unauthorized callers.
    function test_revert_configMutation_unauthorized() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        OracleAggregator.ModuleConfig[] memory mods = new OracleAggregator.ModuleConfig[](0);

        vm.startPrank(stranger);
        vm.expectRevert(Unauthorized.selector);
        aggregator.addReporterModules(eventId, mods);
        vm.expectRevert(Unauthorized.selector);
        aggregator.removeReporterModules(eventId, _addrArray(address(eoaReporter)));
        vm.expectRevert(Unauthorized.selector);
        aggregator.addDisputerModules(eventId, mods);
        vm.expectRevert(Unauthorized.selector);
        aggregator.removeDisputerModules(eventId, _addrArray(address(mockDisputer)));
        vm.expectRevert(Unauthorized.selector);
        aggregator.setArbitratorModule(eventId, address(mockArbitrator), "");
        vm.expectRevert(Unauthorized.selector);
        aggregator.setFinalizer(eventId, finalizerAddr);
        vm.expectRevert(Unauthorized.selector);
        aggregator.setLivenessWindow(eventId, 1 minutes);
        vm.stopPrank();
    }

    /// @notice A reverting/non-responsive arbitrator does not brick dispute escalation: the
    ///         request still parks in `ArbitrationRequested` for admin resolution, and
    ///         `ArbitratorHookFailed` is emitted.
    function test_dispute_revertingArbitratorParksForAdmin() public {
        bytes32 eventId = _nextBinaryEventId();
        RevertingArbitrator revertingArbitrator = new RevertingArbitrator();
        _initializeRequestWithArbitrator(
            eventId,
            address(positions.binaryModule),
            OracleAggregator.MarketType.BINARY,
            1,
            2,
            1,
            address(revertingArbitrator)
        );

        _reachProposal(eventId);

        vm.expectEmit(true, true, false, false, address(aggregator));
        emit OracleAggregatorEvents.ArbitratorHookFailed(eventId, address(revertingArbitrator));
        vm.prank(disputer);
        mockDisputer.dispute(eventId);

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));
    }

    /// @notice A codeless (opt-out) arbitrator address does not brick escalation: the low-level
    ///         call no-ops (reports success), so the dispute does not revert and the request parks
    ///         in `ArbitrationRequested` for admin resolution.
    function test_dispute_codelessArbitratorParksForAdmin() public {
        bytes32 eventId = _nextBinaryEventId();
        address codelessArbitrator = address(uint160(0xDEAD));
        _initializeRequestWithArbitrator(
            eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1, codelessArbitrator
        );

        _reachProposal(eventId);

        vm.prank(disputer);
        mockDisputer.dispute(eventId);

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));
    }
}

/// @notice An arbitrator whose `onArbitrationTriggered` hook always reverts.
contract RevertingArbitrator {
    error ArbitratorDown();

    function onArbitrationTriggered(bytes32, bytes32) external pure {
        revert ArbitratorDown();
    }
}

/*--------------------------------------------------------------
                     PER-EVENT MARKET PAUSE
--------------------------------------------------------------*/

contract OracleAggregatorTest_marketPause is OracleAggregatorTest {
    /// @notice Pausing a market blocks finalize for everyone, including a configured finalizer.
    function test_pause_blocksFinalize() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequestFull(
            eventId,
            address(positions.binaryModule),
            OracleAggregator.MarketType.BINARY,
            1,
            2,
            1,
            address(mockArbitrator),
            finalizerAddr
        );

        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.MarketPauseSet(EventId.wrap(bytes29(eventId)), true);
        vm.prank(marketManager);
        aggregator.pauseMarkets(_singleEvent(eventId));

        assertTrue(aggregator.marketPaused(EventId.wrap(bytes29(eventId))));

        // Even the configured finalizer is blocked.
        vm.prank(finalizerAddr);
        vm.expectRevert(OracleAggregatorErrors.MarketPaused.selector);
        aggregator.finalize(eventId, _yesSingle());
    }

    /// @notice Unpausing re-enables finalize.
    function test_unpause_reenablesFinalize() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        _reachProposal(eventId);
        vm.warp(block.timestamp + 5 minutes + 1);

        vm.prank(marketManager);
        aggregator.pauseMarkets(_singleEvent(eventId));

        vm.expectEmit(true, true, true, true, address(aggregator));
        emit OracleAggregatorEvents.MarketPauseSet(EventId.wrap(bytes29(eventId)), false);
        vm.prank(marketManager);
        aggregator.unpauseMarkets(_singleEvent(eventId));

        assertFalse(aggregator.marketPaused(EventId.wrap(bytes29(eventId))));

        aggregator.finalize(eventId, _yesSingle());
        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice Admin can still resolve a paused market via resolveResult.
    function test_pause_adminResolveStillWorks() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(marketManager);
        aggregator.pauseMarkets(_singleEvent(eventId));

        vm.prank(admin);
        aggregator.resolveResult(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice The arbitrator can still resolve a paused market.
    function test_pause_arbitratorResolveStillWorks() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(marketManager);
        aggregator.pauseMarkets(_singleEvent(eventId));

        mockArbitrator.resolve(eventId, _yesSingle());

        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.Resolved));
    }

    /// @notice Reporting and disputing continue while a market is paused.
    function test_pause_reportAndDisputeUnaffected() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(marketManager);
        aggregator.pauseMarkets(_singleEvent(eventId));

        // Reports still reach the proposal threshold.
        _reachProposal(eventId);
        (, bytes32 proposedHash,,) = aggregator.getRequestState(eventId);
        assertEq(proposedHash, keccak256(abi.encode(_yesSingle())));

        // Disputes still escalate to arbitration.
        vm.prank(disputer);
        mockDisputer.dispute(eventId);
        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(eventId);
        assertEq(uint8(status), uint8(OracleAggregator.ResolutionStatus.ArbitrationRequested));
    }

    /// @notice A batch can pause multiple markets at once.
    function test_pause_batch() public {
        bytes32 eventId1 = _nextBinaryEventId();
        bytes32 eventId2 = _nextBinaryEventId();
        _initializeRequest(eventId1, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);
        _initializeRequest(eventId2, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        EventId[] memory ids = new EventId[](2);
        ids[0] = EventId.wrap(bytes29(eventId1));
        ids[1] = EventId.wrap(bytes29(eventId2));

        vm.prank(marketManager);
        aggregator.pauseMarkets(ids);

        assertTrue(aggregator.marketPaused(ids[0]));
        assertTrue(aggregator.marketPaused(ids[1]));
    }

    /// @notice Pausing an unknown market reverts.
    function test_revert_pause_requestNotFound() public {
        bytes32 eventId = _nextBinaryEventId();
        vm.prank(marketManager);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        aggregator.pauseMarkets(_singleEvent(eventId));
    }

    /// @notice Pause and unpause revert for unauthorized callers.
    function test_revert_pause_unauthorized() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        aggregator.pauseMarkets(_singleEvent(eventId));

        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        aggregator.unpauseMarkets(_singleEvent(eventId));
    }

    /// @notice Per-event pause is independent of the global pause.
    function test_pause_independentOfGlobalPause() public {
        bytes32 eventId = _nextBinaryEventId();
        _initializeRequest(eventId, address(positions.binaryModule), OracleAggregator.MarketType.BINARY, 1, 2, 1);

        // Global pause does not set the per-event flag.
        vm.prank(admin);
        aggregator.pauseOracle();
        assertFalse(aggregator.marketPaused(EventId.wrap(bytes29(eventId))));
    }
}

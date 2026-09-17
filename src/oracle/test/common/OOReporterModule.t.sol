// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { IOOReporter } from "managed-oracle/pm-v2-oo-reporter/interfaces/IOOReporter.sol";

import { OracleAggregatorErrors } from "@polymarket-v2/src/oracle/abstract/OracleAggregatorErrors.sol";
import { OracleAggregatorEvents } from "@polymarket-v2/src/oracle/abstract/OracleAggregatorEvents.sol";
import { OracleModuleBase } from "@polymarket-v2/src/oracle/abstract/OracleModuleBase.sol";
import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { MockOOReporter } from "@polymarket-v2/src/external/uma/mocks/MockOOReporter.sol";
import { OOReporterModule } from "@polymarket-v2/src/oracle/modules/OOReporterModule.sol";
import { ConditionId, ConditionIdLib, EventId, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

import { ModuleTestBase } from "./ModuleTestBase.sol";

contract OOReporterModuleV2 is OOReporterModule {
    constructor(address _ooReporter) OOReporterModule(_ooReporter) { }

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Tests for OOReporterModule's pull-based UMA reporter integration.
contract OOReporterModuleTest is ModuleTestBase, OracleAggregatorEvents {
    OOReporterModule public module;
    MockOOReporter public ooReporter;

    address public moduleOperator = makeAddr("moduleOperator");
    address public otherFinalizer = makeAddr("otherFinalizer");

    bytes public requestRules = bytes("Will ETH reach 10k?");

    int256 public constant NO_PRICE = 0;
    int256 public constant P3_PRICE = 0.5e18;
    int256 public constant YES_PRICE = 1e18;
    bytes32 public constant BINARY_IDENTIFIER = bytes32("YES_OR_NO_QUERY");
    bytes32 public constant NUMERICAL_IDENTIFIER = bytes32("NUMERICAL");
    uint64 public constant MINIMUM_LIVENESS = 1 hours;
    uint64 public constant MAXIMUM_LIVENESS = 2 days;

    event RequestInitialized(ConditionId indexed scopeId);
    event OOReporterRequestCreated(bytes32 indexed requestId, bytes32 identifier);
    event OOReporterResultReported(bytes32 indexed requestId, int256 price, bytes32 resultHash);

    function setUp() public virtual override {
        super.setUp();

        ooReporter = new MockOOReporter();
        module = OOReporterModule(LibClone.deployERC1967(address(new OOReporterModule(address(ooReporter)))));
        module.initialize(owner, admin, address(aggregator));

        vm.prank(admin);
        module.addOperator(moduleOperator);
    }

    /// @dev A disputer entry that is registered but never exercised, for requests that do not
    ///      rely on a functional dispute path. The address is only ever membership-checked, so a
    ///      plain non-controlled address with empty init data suffices.
    function _noopDisputerModules() internal pure returns (OracleAggregator.ModuleConfig[] memory modules) {
        modules = new OracleAggregator.ModuleConfig[](1);
        modules[0] = OracleAggregator.ModuleConfig({ module: address(uint160(0xD15D15)), initData: "" });
    }

    function _reporterModules(bytes memory _initData)
        internal
        view
        returns (OracleAggregator.ModuleConfig[] memory modules)
    {
        modules = new OracleAggregator.ModuleConfig[](1);
        modules[0] = OracleAggregator.ModuleConfig({ module: address(module), initData: _initData });
    }

    function _disputerModules() internal view returns (OracleAggregator.ModuleConfig[] memory modules) {
        address[] memory disputers = new address[](1);
        disputers[0] = disputer1;

        modules = new OracleAggregator.ModuleConfig[](1);
        modules[0] = OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });
    }

    function _registration(bytes32 _requestId)
        internal
        view
        returns (OOReporterModule.RequestRegistration memory registration)
    {
        registration = OOReporterModule.RequestRegistration({
            requestId: _requestId,
            requestRules: requestRules,
            minimumLiveness: MINIMUM_LIVENESS,
            maximumLiveness: MAXIMUM_LIVENESS
        });
    }

    function _singleRegistrationData(bytes32 _requestId) internal view returns (bytes memory) {
        OOReporterModule.RequestRegistration[] memory registrations = new OOReporterModule.RequestRegistration[](1);
        registrations[0] = _registration(_requestId);
        return abi.encode(registrations);
    }

    function _initializeRequest(
        bytes32 _eventId,
        OracleAggregator.MarketType _marketType,
        address _targetContract,
        uint16 _resultLength,
        uint16 _reporterThreshold,
        bytes memory _reporterInitData,
        address _finalizer,
        bool _withDisputer
    ) internal {
        OracleAggregator.ModuleConfig[] memory disputerModules =
            _withDisputer ? _disputerModules() : _noopDisputerModules();

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(_eventId),
                marketType: _marketType,
                targetContract: _targetContract,
                resultLength: _resultLength,
                reporterModules: _reporterModules(_reporterInitData),
                reporterThreshold: _reporterThreshold,
                disputerModules: disputerModules,
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: _finalizer
            })
        );
    }

    function _initializeBinaryRequest(bytes memory _initData) internal returns (bytes32 eventId) {
        eventId = _nextEventId(ModuleIds.BINARY);
        _initializeRequest({
            _eventId: eventId,
            _marketType: OracleAggregator.MarketType.BINARY,
            _targetContract: address(positions.binaryModule),
            _resultLength: 1,
            _reporterThreshold: 1,
            _reporterInitData: _initData,
            _finalizer: address(module),
            _withDisputer: false
        });
    }

    function _initializeIncrementalRequest(bytes32 _eventId, bytes memory _initData) internal {
        _initializeRequest({
            _eventId: _eventId,
            _marketType: OracleAggregator.MarketType.INCREMENTAL_NEGRISK,
            _targetContract: address(positions.negRiskModule),
            _resultLength: 1,
            _reporterThreshold: 1,
            _reporterInitData: _initData,
            _finalizer: address(module),
            _withDisputer: false
        });
    }

    function _initializeAtomicRequest(bytes32 _eventId, bytes memory _initData) internal {
        _initializeRequest({
            _eventId: _eventId,
            _marketType: OracleAggregator.MarketType.ATOMIC_NEGRISK,
            _targetContract: address(positions.negRiskModule),
            _resultLength: 1,
            _reporterThreshold: 1,
            _reporterInitData: _initData,
            _finalizer: address(module),
            _withDisputer: false
        });
    }

    function _createRequest(bytes32 _requestId) internal {
        vm.prank(moduleOperator);
        module.createRequest(_requestId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function _registeredBinaryRequest() internal returns (bytes32 eventId) {
        eventId = _initializeBinaryRequest("");
        _createRequest(eventId);
    }

    function _settledBinaryRequest(int256 _price) internal returns (bytes32 eventId) {
        eventId = _registeredBinaryRequest();
        ooReporter.resolveRequest(eventId, _price);
    }

    /// @dev Initializes a binary request with the OOReporter module plus an unused filler reporter
    ///      module, so a `reporterThreshold` of 2 is satisfiable. Only the OOReporter module is
    ///      exercised by callers.
    function _initializeBinaryRequestTwoReporters(bytes32 _eventId, uint16 _reporterThreshold, address _finalizer)
        internal
    {
        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](2);
        reporterModules[0] = OracleAggregator.ModuleConfig({ module: address(module), initData: "" });
        reporterModules[1] = OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: "" });

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(_eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: _reporterThreshold,
                disputerModules: _noopDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: _finalizer
            })
        );
    }

    function _reportAndWarp(bytes32 _requestId) internal {
        module.report(_requestId);
        vm.warp(_getDisputeWindowEnd(_requestId));
    }
}

/*--------------------------------------------------------------
                    OO REPORTER MODULE: INITIALIZER
--------------------------------------------------------------*/

contract OOReporterModuleTest_initializer is OOReporterModuleTest {
    function test_constructor() public view {
        assertEq(module.aggregator(), address(aggregator));
        assertEq(module.owner(), owner);
        assertEq(address(module.ooReporter()), address(ooReporter));
    }

    function test_revert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        module.initialize(owner, admin, address(aggregator));
    }

    function test_revert_constructor_zeroOOReporter() public {
        vm.expectRevert(OOReporterModule.ZeroOOReporter.selector);
        new OOReporterModule(address(0));
    }

    function test_revert_initialize_onImplementation() public {
        OOReporterModule implementation = new OOReporterModule(address(ooReporter));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, admin, address(aggregator));
    }
}

/*--------------------------------------------------------------
                    OO REPORTER MODULE: UPGRADE
--------------------------------------------------------------*/

contract OOReporterModuleTest_upgrade is OOReporterModuleTest {
    function test_upgradeToAndCall_preservesStateAndRoles() public {
        bytes32 eventId = _registeredBinaryRequest();
        address newImpl = address(new OOReporterModuleV2(address(ooReporter)));

        vm.prank(owner);
        module.upgradeToAndCall(newImpl, "");

        OOReporterModuleV2 upgraded = OOReporterModuleV2(address(module));
        assertEq(upgraded.version(), 2);
        assertEq(upgraded.owner(), owner);
        assertEq(upgraded.aggregator(), address(aggregator));
        assertEq(address(upgraded.ooReporter()), address(ooReporter));
        assertTrue(upgraded.requestInitialized(ConditionIdLib.from(eventId)));
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(new OOReporterModule(address(ooReporter)));

        vm.prank(moduleOperator);
        vm.expectRevert(Unauthorized.selector);
        module.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
                    OO REPORTER MODULE: REGISTRATION
--------------------------------------------------------------*/

contract OOReporterModuleTest_registration is OOReporterModuleTest {
    function test_createRequest_registersBinaryRequestAndEmitsEvents() public {
        bytes32 eventId = _initializeBinaryRequest("");
        ConditionId conditionId = ConditionIdLib.from(eventId);

        vm.expectEmit(true, false, false, true, address(module));
        emit RequestInitialized(conditionId);
        vm.expectEmit(true, false, false, true, address(module));
        emit OOReporterRequestCreated(eventId, BINARY_IDENTIFIER);

        _createRequest(eventId);

        assertTrue(module.requestInitialized(conditionId));
        assertEq(ooReporter.registerCallCount(), 1);
        assertEq(ooReporter.lastRequestId(), eventId);
        assertEq(ooReporter.lastPriceIdentifier(), BINARY_IDENTIFIER);
        assertEq(ooReporter.getLastRequestRules(), requestRules);
        assertEq(ooReporter.lastMinimumLiveness(), MINIMUM_LIVENESS);
        assertEq(ooReporter.lastMaximumLiveness(), MAXIMUM_LIVENESS);
    }

    function test_initializeReporterModule_registersFromAggregatorInitData() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        ConditionId conditionId = ConditionIdLib.from(eventId);

        vm.expectEmit(true, false, false, true, address(module));
        emit RequestInitialized(conditionId);
        vm.expectEmit(true, false, false, true, address(module));
        emit OOReporterRequestCreated(eventId, BINARY_IDENTIFIER);

        _initializeRequest({
            _eventId: eventId,
            _marketType: OracleAggregator.MarketType.BINARY,
            _targetContract: address(positions.binaryModule),
            _resultLength: 1,
            _reporterThreshold: 1,
            _reporterInitData: _singleRegistrationData(eventId),
            _finalizer: address(module),
            _withDisputer: false
        });

        assertTrue(module.requestInitialized(conditionId));
        assertEq(ooReporter.registerCallCount(), 1);
        assertEq(ooReporter.lastRequestId(), eventId);
    }

    function test_initializeReporterModule_registersMultipleIncrementalRequests() public {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        bytes32 request0 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 0)));
        bytes32 request1 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 1)));

        OOReporterModule.RequestRegistration[] memory registrations = new OOReporterModule.RequestRegistration[](2);
        registrations[0] = _registration(request0);
        registrations[1] = _registration(request1);

        _initializeIncrementalRequest(eventId, abi.encode(registrations));

        assertEq(ooReporter.registerCallCount(), 2);
        assertTrue(module.requestInitialized(ConditionIdLib.from(request0)));
        assertTrue(module.requestInitialized(ConditionIdLib.from(request1)));
        assertEq(ooReporter.lastPriceIdentifier(), BINARY_IDENTIFIER);
    }

    function test_createRequest_derivesNumericalIdentifier() public {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        _initializeAtomicRequest(eventId, "");

        _createRequest(eventId);

        assertEq(ooReporter.lastPriceIdentifier(), NUMERICAL_IDENTIFIER);
    }

    function test_revert_createRequest_unauthorized() public {
        bytes32 eventId = _initializeBinaryRequest("");

        vm.prank(makeAddr("random"));
        vm.expectRevert(Unauthorized.selector);
        module.createRequest(eventId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function test_revert_initializeReporterModule_onlyAggregator() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);

        vm.expectRevert(OracleModuleBase.NotAggregator.selector);
        module.initializeReporterModule(EventIdLib.from(eventId), _singleRegistrationData(eventId));
    }

    function test_revert_initializeReporterModule_emptyRegistrations() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        OOReporterModule.RequestRegistration[] memory registrations = new OOReporterModule.RequestRegistration[](0);

        vm.prank(address(aggregator));
        vm.expectRevert(OOReporterModule.EmptyRequestRegistrations.selector);
        module.initializeReporterModule(EventIdLib.from(eventId), abi.encode(registrations));
    }

    function test_revert_initializeReporterModule_eventIdMismatch() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        bytes32 otherEventId = _nextEventId(ModuleIds.BINARY);

        vm.prank(address(aggregator));
        vm.expectRevert(OOReporterModule.EventIdMismatch.selector);
        module.initializeReporterModule(EventIdLib.from(eventId), _singleRegistrationData(otherEventId));
    }

    function test_revert_duplicateRequestIdAcrossRegistrationPaths() public {
        bytes32 eventId = _initializeBinaryRequest("");
        _createRequest(eventId);

        vm.prank(address(aggregator));
        vm.expectRevert(OracleModuleBase.RequestAlreadyInitialized.selector);
        module.initializeReporterModule(EventIdLib.from(eventId), _singleRegistrationData(eventId));
    }

    function test_revert_createRequest_beforeAggregatorInitialization() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);

        vm.prank(moduleOperator);
        vm.expectRevert(OracleAggregatorErrors.RequestNotFound.selector);
        module.createRequest(eventId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function test_revert_createRequest_nonCanonicalRequestId() public {
        bytes32 eventId = _initializeBinaryRequest("");
        bytes32 dirtyRequestId = bytes32(uint256(eventId) | 1);

        vm.prank(moduleOperator);
        vm.expectRevert(abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, dirtyRequestId));
        module.createRequest(dirtyRequestId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function test_revert_createRequest_invalidLivenessRange() public {
        bytes32 eventId = _initializeBinaryRequest("");

        vm.prank(moduleOperator);
        vm.expectRevert(
            abi.encodeWithSelector(OOReporterModule.InvalidLivenessRange.selector, MAXIMUM_LIVENESS, MINIMUM_LIVENESS)
        );
        module.createRequest(eventId, requestRules, MAXIMUM_LIVENESS, MINIMUM_LIVENESS);
    }
}

/*--------------------------------------------------------------
                    OO REPORTER MODULE: UPDATE RULES
--------------------------------------------------------------*/

contract OOReporterModuleTest_updateRules is OOReporterModuleTest {
    event OOReporterRulesForwarded(bytes32 indexed requestId, bytes updatedRules);
    event OOReporterRulesForwardFailed(bytes32 indexed requestId, bytes reason);

    function test_updateRules_forwardsToOOReporterForRegisteredRequest() public {
        bytes32 eventId = _initializeBinaryRequest("");
        _createRequest(eventId);

        bytes memory updatedRules = bytes("revised rules v2");

        vm.expectEmit(true, false, false, true, address(module));
        emit OOReporterRulesForwarded(eventId, updatedRules);

        vm.prank(address(aggregator));
        module.updateRules(eventId, updatedRules);

        assertEq(ooReporter.updateRulesCallCount(), 1);
        assertEq(ooReporter.lastRulesRequestId(), eventId);
        assertEq(ooReporter.getLastUpdatedRules(), updatedRules);
    }

    function test_updateRules_skipsUnregisteredRequest() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);

        vm.prank(address(aggregator));
        module.updateRules(eventId, bytes("noop"));

        assertEq(ooReporter.updateRulesCallCount(), 0);
    }

    function test_updateRules_ignoresRequestAlreadyResolved() public {
        bytes32 eventId = _initializeBinaryRequest("");
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, YES_PRICE);

        bytes memory expectedReason = abi.encodeWithSelector(IOOReporter.RequestAlreadyResolved.selector);
        vm.expectEmit(true, false, false, true, address(module));
        emit OOReporterRulesForwardFailed(eventId, expectedReason);

        vm.prank(operator);
        aggregator.updateRequestRules(eventId, bytes("revised"));

        assertEq(ooReporter.updateRulesCallCount(), 0);
        assertEq(aggregator.getRuleCount(eventId), 1);
    }

    function test_updateRules_ignoresRequestNotRegistered() public {
        bytes32 eventId = _initializeBinaryRequest("");
        _createRequest(eventId);
        ooReporter.setRegistered(eventId, false);

        bytes memory expectedReason = abi.encodeWithSelector(IOOReporter.RequestNotRegistered.selector);
        vm.expectEmit(true, false, false, true, address(module));
        emit OOReporterRulesForwardFailed(eventId, expectedReason);

        vm.prank(operator);
        aggregator.updateRequestRules(eventId, bytes("revised"));

        assertEq(ooReporter.updateRulesCallCount(), 0);
        assertEq(aggregator.getRuleCount(eventId), 1);
    }

    function test_revert_updateRules_unexpectedOOReporterError() public {
        bytes32 eventId = _initializeBinaryRequest("");
        _createRequest(eventId);

        ooReporter.setForceUpdateRulesRevert(true);

        vm.prank(operator);
        vm.expectRevert(MockOOReporter.ForcedUpdateRulesRevert.selector);
        aggregator.updateRequestRules(eventId, bytes("revised"));

        assertEq(ooReporter.updateRulesCallCount(), 0);
        assertEq(aggregator.getRuleCount(eventId), 0);
    }

    function test_revert_updateRules_emptyOOReporterError() public {
        bytes32 eventId = _initializeBinaryRequest("");
        _createRequest(eventId);

        ooReporter.setForceUpdateRulesEmptyRevert(true);

        vm.prank(operator);
        vm.expectRevert();
        aggregator.updateRequestRules(eventId, bytes("revised"));

        assertEq(ooReporter.updateRulesCallCount(), 0);
        assertEq(aggregator.getRuleCount(eventId), 0);
    }

    function test_revert_updateRules_notAggregator() public {
        bytes32 eventId = _initializeBinaryRequest("");
        _createRequest(eventId);

        vm.prank(makeAddr("intruder"));
        vm.expectRevert(OracleModuleBase.NotAggregator.selector);
        module.updateRules(eventId, bytes("nope"));
    }
}

/*--------------------------------------------------------------
                        OO REPORTER MODULE: REPORT
--------------------------------------------------------------*/

contract OOReporterModuleTest_report is OOReporterModuleTest {
    function test_report_yesCreatesProposalWithoutResolvingTarget() public {
        bytes32 eventId = _settledBinaryRequest(YES_PRICE);
        uint256[] memory expected = _yesPayouts();
        bytes32 resultHash = keccak256(abi.encode(expected));

        vm.expectEmit(true, false, false, true, address(module));
        emit OOReporterResultReported(eventId, YES_PRICE, resultHash);
        vm.expectEmit(true, true, false, true, address(aggregator));
        emit ResultReported(eventId, address(module), resultHash, 1);
        vm.expectEmit(true, false, false, true, address(aggregator));
        emit OutcomeProposed(eventId, resultHash, expected);

        module.report(eventId);

        assertEq(_getProposedResultHash(eventId), resultHash);
        assertEq(aggregator.getReportVotes(eventId, expected), 1);
        assertFalse(_isConditionResolved(eventId));
    }

    function test_report_noTranslatesToZero() public {
        bytes32 eventId = _settledBinaryRequest(NO_PRICE);

        module.report(eventId);

        assertEq(_getProposedResultHash(eventId), keccak256(abi.encode(_noPayouts())));
    }

    function test_report_binaryP3TranslatesToHalf() public {
        bytes32 eventId = _settledBinaryRequest(P3_PRICE);

        module.report(eventId);

        assertEq(_getProposedResultHash(eventId), keccak256(abi.encode(_fiftyFiftyPayouts())));
    }

    function test_revert_report_malformedBinaryPrice() public {
        bytes32 eventId = _settledBinaryRequest(0.25e18);

        vm.expectRevert(OOReporterModule.InvalidPrice.selector);
        module.report(eventId);
    }

    function test_report_belowThresholdDoesNotCreateProposal() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        _initializeBinaryRequestTwoReporters(eventId, 2, address(module));
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, YES_PRICE);

        module.report(eventId);

        assertEq(aggregator.getReportVotes(eventId, _yesPayouts()), 1);
        assertEq(_getProposedResultHash(eventId), bytes32(0));
    }

    function test_report_incrementalNegRiskYes() public {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        bytes32 requestId = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 1)));
        _initializeIncrementalRequest(eventId, "");
        _createRequest(requestId);
        ooReporter.resolveRequest(requestId, YES_PRICE);

        module.report(requestId);

        assertEq(_getProposedResultHash(requestId), keccak256(abi.encode(_yesPayouts())));
    }

    function test_report_incrementalNegRiskNo() public {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        bytes32 requestId = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 1)));
        _initializeIncrementalRequest(eventId, "");
        _createRequest(requestId);
        ooReporter.resolveRequest(requestId, NO_PRICE);

        module.report(requestId);

        assertEq(_getProposedResultHash(requestId), keccak256(abi.encode(_noPayouts())));
    }

    function test_revert_report_incrementalNegRiskP3() public {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        bytes32 requestId = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 1)));
        _initializeIncrementalRequest(eventId, "");
        _createRequest(requestId);
        ooReporter.resolveRequest(requestId, P3_PRICE);

        vm.expectRevert(OOReporterModule.InvalidPrice.selector);
        module.report(requestId);

        assertEq(aggregator.getReportVotes(requestId, _fiftyFiftyPayouts()), 0);
    }

    function test_report_atomicNumericalResult() public {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        _initializeAtomicRequest(eventId, "");
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, 1e18);

        module.report(eventId);

        uint256[] memory expected = new uint256[](1);
        expected[0] = 1;
        assertEq(_getProposedResultHash(eventId), keccak256(abi.encode(expected)));
    }

    function test_revert_report_unregisteredRequest() public {
        bytes32 eventId = _initializeBinaryRequest("");

        vm.expectRevert(OracleModuleBase.RequestNotInitialized.selector);
        module.report(eventId);
    }

    function test_revert_report_beforeUMAResultAvailable() public {
        bytes32 eventId = _registeredBinaryRequest();

        vm.expectRevert(OOReporterModule.RequestNotResolved.selector);
        module.report(eventId);
    }

    function test_revert_report_twice() public {
        bytes32 eventId = _settledBinaryRequest(YES_PRICE);
        module.report(eventId);

        vm.expectRevert(OracleAggregatorErrors.AlreadyVoted.selector);
        module.report(eventId);
    }

    function test_revert_report_afterModuleRemoval() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        _initializeBinaryRequestTwoReporters(eventId, 1, address(module));
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, YES_PRICE);

        address[] memory modules = new address[](1);
        modules[0] = address(module);

        vm.prank(admin);
        aggregator.removeReporterModules(eventId, modules);

        vm.expectRevert(OracleAggregatorErrors.NotRegisteredModule.selector);
        module.report(eventId);
    }

    function test_revert_report_atomicNumericalNegativeResult() public {
        _assertInvalidAtomicPrice(-1);
    }

    function test_revert_report_atomicNumericalNonMultipleResult() public {
        _assertInvalidAtomicPrice(1e18 + 1);
    }

    function test_revert_report_atomicNumericalWinnerOutOfRange() public {
        _assertInvalidAtomicPrice(3e18);
    }

    function _assertInvalidAtomicPrice(int256 _price) internal {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        _initializeAtomicRequest(eventId, "");
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, _price);

        vm.expectRevert(OOReporterModule.InvalidPrice.selector);
        module.report(eventId);
    }
}

/*--------------------------------------------------------------
                       OO REPORTER MODULE: FINALIZE
--------------------------------------------------------------*/

contract OOReporterModuleTest_finalize is OOReporterModuleTest {
    function test_finalize_afterLivenessResolvesBinaryResult() public {
        bytes32 eventId = _settledBinaryRequest(YES_PRICE);
        _reportAndWarp(eventId);
        bytes32 resultHash = keccak256(abi.encode(_yesPayouts()));

        vm.expectEmit(true, true, false, true, address(aggregator));
        emit RequestResolved(eventId, resultHash, address(aggregator));
        module.finalize(eventId);

        assertTrue(_isConditionResolved(eventId));
        uint256[] memory result = positions.binaryModule.getResult(ConditionIdLib.from(eventId));
        assertEq(result[0], RESULT_DENOMINATOR);
        assertEq(result[1], 0);
    }

    function test_finalize_zeroLivenessResolvesInReportingBlock() public {
        bytes32 eventId = _settledBinaryRequest(YES_PRICE);

        vm.prank(operator);
        aggregator.setLivenessWindow(eventId, 0);

        uint256 reportingBlock = block.number;
        module.report(eventId);
        module.finalize(eventId);

        assertEq(block.number, reportingBlock);
        assertTrue(_isConditionResolved(eventId));
    }

    function test_finalize_zeroFinalizerAllowsDirectPermissionlessFinalization() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        _initializeRequest({
            _eventId: eventId,
            _marketType: OracleAggregator.MarketType.BINARY,
            _targetContract: address(positions.binaryModule),
            _resultLength: 1,
            _reporterThreshold: 1,
            _reporterInitData: "",
            _finalizer: address(0),
            _withDisputer: false
        });
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, YES_PRICE);
        _reportAndWarp(eventId);

        vm.prank(makeAddr("permissionlessFinalizer"));
        aggregator.finalize(eventId, _yesPayouts());

        assertTrue(_isConditionResolved(eventId));
    }

    function test_finalize_atomicNumericalResult() public {
        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);
        _initializeAtomicRequest(eventId, "");
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, 1e18);
        _reportAndWarp(eventId);

        module.finalize(eventId);

        bytes32 c0 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 0)));
        bytes32 c1 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 1)));
        bytes32 c2 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 2)));
        bytes32 c3 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(eventId), 3)));

        assertEq(positions.negRiskModule.getResult(ConditionIdLib.from(c0))[1], RESULT_DENOMINATOR);
        assertEq(positions.negRiskModule.getResult(ConditionIdLib.from(c1))[0], RESULT_DENOMINATOR);
        assertEq(positions.negRiskModule.getResult(ConditionIdLib.from(c2))[1], RESULT_DENOMINATOR);
        assertEq(positions.negRiskModule.getResult(ConditionIdLib.from(c3))[1], RESULT_DENOMINATOR);
    }

    function test_revert_finalize_beforeThreshold() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        _initializeBinaryRequestTwoReporters(eventId, 2, address(module));
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, YES_PRICE);
        module.report(eventId);

        vm.expectRevert(OracleAggregatorErrors.ThresholdNotMet.selector);
        module.finalize(eventId);
    }

    function test_revert_finalize_beforeLiveness() public {
        bytes32 eventId = _settledBinaryRequest(YES_PRICE);
        module.report(eventId);

        vm.expectRevert(OracleAggregatorErrors.DisputeWindowActive.selector);
        module.finalize(eventId);
    }

    function test_revert_finalize_whenAnotherFinalizerConfigured() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        _initializeRequest({
            _eventId: eventId,
            _marketType: OracleAggregator.MarketType.BINARY,
            _targetContract: address(positions.binaryModule),
            _resultLength: 1,
            _reporterThreshold: 1,
            _reporterInitData: "",
            _finalizer: otherFinalizer,
            _withDisputer: false
        });
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, YES_PRICE);
        _reportAndWarp(eventId);

        vm.expectRevert(OracleAggregatorErrors.NotAuthorized.selector);
        module.finalize(eventId);
    }

    function test_arbitrationBlocksFinalizeAndSeparateArbitratorResolves() public {
        bytes32 eventId = _nextEventId(ModuleIds.BINARY);
        _initializeRequest({
            _eventId: eventId,
            _marketType: OracleAggregator.MarketType.BINARY,
            _targetContract: address(positions.binaryModule),
            _resultLength: 1,
            _reporterThreshold: 1,
            _reporterInitData: "",
            _finalizer: address(module),
            _withDisputer: true
        });
        _createRequest(eventId);
        ooReporter.resolveRequest(eventId, YES_PRICE);
        module.report(eventId);

        vm.prank(disputer1);
        mockDisputer.dispute(eventId);

        vm.warp(block.timestamp + defaultLivenessWindow + 1);
        vm.expectRevert(OracleAggregatorErrors.RequestNotActive.selector);
        module.finalize(eventId);

        mockArbitrator.resolve(eventId, _yesPayouts());
        assertTrue(_isConditionResolved(eventId));
    }

    function test_moduleHasNoResolveAuthority() public {
        bytes32 eventId = _registeredBinaryRequest();

        vm.prank(address(module));
        vm.expectRevert(OracleAggregatorErrors.NotAuthorized.selector);
        aggregator.resolveResult(eventId, _yesPayouts());
    }
}

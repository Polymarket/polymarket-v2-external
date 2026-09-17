// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";
import { MockERC20 } from "@solady/test/utils/mocks/MockERC20.sol";
import { OOReporter } from "managed-oracle/pm-v2-oo-reporter/OOReporter.sol";
import { IOOReporter, RequestData } from "managed-oracle/pm-v2-oo-reporter/interfaces/IOOReporter.sol";

import { OracleAggregatorErrors } from "@polymarket-v2/src/oracle/abstract/OracleAggregatorErrors.sol";
import { ModuleTestBase } from "@polymarket-v2/src/oracle/test/common/ModuleTestBase.sol";
import {
    IntegrationOptimisticOracleV2
} from "@polymarket-v2/src/oracle/test/integration/mocks/IntegrationOptimisticOracleV2.sol";
import { OOReporterModule } from "@polymarket-v2/src/oracle/modules/OOReporterModule.sol";
import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { ConditionId, ConditionIdLib, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

/// @notice End-to-end integration between Polymarket's module and UMA's production OOReporter implementation.
contract OOReporterIntegrationTest is ModuleTestBase {
    OOReporterModule public module;
    IOOReporter public reporter;
    IntegrationOptimisticOracleV2 public optimisticOracle;
    MockERC20 public rewardCurrency;

    address public moduleOperator = makeAddr("moduleOperator");
    address public umaOwner = makeAddr("umaOwner");
    address public umaOracleInitializer = makeAddr("umaOracleInitializer");
    address public umaRequesterAdmin = makeAddr("umaRequesterAdmin");
    address public umaResolver = makeAddr("umaResolver");

    bytes public requestRules = bytes("Will ETH reach 10k?");

    bytes32 public constant BINARY_IDENTIFIER = bytes32("YES_OR_NO_QUERY");
    bytes32 public constant NUMERICAL_IDENTIFIER = bytes32("NUMERICAL");
    uint64 public constant MINIMUM_LIVENESS = 1 hours;
    uint64 public constant MAXIMUM_LIVENESS = 2 days;
    uint64 public constant SELECTED_LIVENESS = 1 days;

    function setUp() public virtual override {
        super.setUp();

        optimisticOracle = new IntegrationOptimisticOracleV2(umaRequesterAdmin, umaResolver);
        rewardCurrency = new MockERC20("Mock USDC", "USDC", 6);

        OOReporter concreteReporter = OOReporter(LibClone.deployERC1967(address(new OOReporter())));

        // Intentional implicit derived-to-interface conversion: compilation fails if the concrete
        // OOReporter no longer implements the complete upstream IOOReporter interface.
        reporter = concreteReporter;
        module = OOReporterModule(LibClone.deployERC1967(address(new OOReporterModule(address(reporter)))));

        module.initialize(owner, admin, address(aggregator));
        reporter.initialize({
            initialOwner: umaOwner,
            optimisticOracle: address(optimisticOracle),
            rewardCurrency: address(rewardCurrency),
            initialOracleInitializer: umaOracleInitializer,
            initialRequester: address(module),
            initialDefaultRerequestBudget: 1
        });

        vm.prank(umaRequesterAdmin);
        optimisticOracle.setRequesterEnabled(address(reporter), true);

        vm.prank(admin);
        module.addOperator(moduleOperator);
    }

    /// @dev A disputer entry registered but never exercised, for requests with no functional
    ///      dispute path. The address is only membership-checked, so a non-controlled address
    ///      with empty init data suffices.
    function _sentinelDisputerModules() internal pure returns (OracleAggregator.ModuleConfig[] memory modules) {
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

    function _registrationData(bytes32 _requestId) internal view returns (bytes memory) {
        OOReporterModule.RequestRegistration[] memory registrations = new OOReporterModule.RequestRegistration[](1);
        registrations[0] = OOReporterModule.RequestRegistration({
            requestId: _requestId,
            requestRules: requestRules,
            minimumLiveness: MINIMUM_LIVENESS,
            maximumLiveness: MAXIMUM_LIVENESS
        });
        return abi.encode(registrations);
    }

    function _initializeBinaryRequest(bytes memory _initData) internal returns (bytes32 requestId) {
        requestId = _nextEventId(ModuleIds.BINARY);
        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(requestId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: _reporterModules(_initData),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(module)
            })
        );
    }

    function _registerExternally(bytes32 _requestId) internal {
        vm.prank(moduleOperator);
        module.createRequest(_requestId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function _initializeUMARequest(bytes32 _requestId) internal {
        vm.prank(umaOracleInitializer);
        reporter.initializeRequest(_requestId, 0, 0, SELECTED_LIVENESS);
    }

    function _settle(bytes32 _requestId, bytes32 _identifier, int256 _price) internal {
        RequestData memory request = reporter.getRequest(_requestId);
        vm.prank(umaResolver);
        optimisticOracle.settle({
            requester: address(reporter),
            identifier: _identifier,
            timestamp: request.requestTimestamp,
            requestRules: requestRules,
            price: _price
        });
    }

    function _reportAndFinalize(bytes32 _requestId) internal {
        module.report(_requestId);
        assertFalse(_isConditionResolved(_requestId));

        vm.warp(_getDisputeWindowEnd(_requestId));
        module.finalize(_requestId);
    }
}

/*--------------------------------------------------------------
                        TRUST BOUNDARIES
--------------------------------------------------------------*/

contract OOReporterIntegrationTest_trustBoundaries is OOReporterIntegrationTest {
    function test_fixtureSeparatesPolymarketAndUMARoles() public view {
        assertNotEq(owner, umaOwner);
        assertEq(OOReporter(address(reporter)).owner(), umaOwner);
        assertTrue(reporter.isRequester(address(module)));
        assertFalse(reporter.isOracleInitializer(address(module)));
        assertTrue(reporter.isOracleInitializer(umaOracleInitializer));
        assertTrue(optimisticOracle.isRequester(address(reporter)));
        assertFalse(optimisticOracle.isRequester(address(module)));
        assertEq(optimisticOracle.requesterAdmin(), umaRequesterAdmin);
        assertEq(optimisticOracle.resolver(), umaResolver);
    }

    function test_revert_polymarketOwnerCannotManageUMAReporterRoles() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        reporter.setRequesterEnabled(makeAddr("requester"), true);
    }

    function test_revert_umaOwnerCannotRegisterPolymarketRequest() public {
        bytes32 requestId = _initializeBinaryRequest("");

        vm.prank(umaOwner);
        vm.expectRevert(Unauthorized.selector);
        module.createRequest(requestId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function test_revert_umaRolesCannotResolvePolymarketRequest() public {
        bytes32 requestId = _initializeBinaryRequest("");
        address[4] memory umaActors = [umaOwner, umaOracleInitializer, umaRequesterAdmin, umaResolver];

        for (uint256 i = 0; i < umaActors.length; i++) {
            vm.prank(umaActors[i]);
            vm.expectRevert(OracleAggregatorErrors.NotAuthorized.selector);
            aggregator.resolveResult(requestId, _yesPayouts());
        }
    }

    function test_revert_moduleCannotInitializeUMARequest() public {
        bytes32 requestId = _initializeBinaryRequest("");
        _registerExternally(requestId);

        vm.prank(address(module));
        vm.expectRevert(IOOReporter.CallerNotOracleInitializer.selector);
        reporter.initializeRequest(requestId, 0, 0, SELECTED_LIVENESS);
    }

    function test_revert_umaInitializationWhenOOReporterIsNotMOOV2Requester() public {
        bytes32 requestId = _initializeBinaryRequest("");
        _registerExternally(requestId);

        vm.prank(umaRequesterAdmin);
        optimisticOracle.setRequesterEnabled(address(reporter), false);

        vm.prank(umaOracleInitializer);
        vm.expectRevert(IntegrationOptimisticOracleV2.RequesterNotEnabled.selector);
        reporter.initializeRequest(requestId, 0, 0, SELECTED_LIVENESS);

        assertFalse(reporter.getRequest(requestId).initialized);
    }

    function test_revert_nonUMAResolverCannotSettleMOOV2Request() public {
        bytes32 requestId = _initializeBinaryRequest("");
        _registerExternally(requestId);
        _initializeUMARequest(requestId);
        RequestData memory request = reporter.getRequest(requestId);

        vm.expectRevert(IntegrationOptimisticOracleV2.CallerNotResolver.selector);
        optimisticOracle.settle({
            requester: address(reporter),
            identifier: BINARY_IDENTIFIER,
            timestamp: request.requestTimestamp,
            requestRules: requestRules,
            price: 1e18
        });
    }
}

/*--------------------------------------------------------------
                         REGISTRATION
--------------------------------------------------------------*/

contract OOReporterIntegrationTest_registration is OOReporterIntegrationTest {
    function test_aggregatorInitDataRegistersWithoutInitializingUMA() public {
        bytes32 requestId = _nextEventId(ModuleIds.BINARY);

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(requestId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: _reporterModules(_registrationData(requestId)),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(module)
            })
        );

        RequestData memory request = reporter.getRequest(requestId);
        assertTrue(request.registered);
        assertFalse(request.initialized);
        assertFalse(reporter.isOracleInitializer(address(module)));
    }

    function test_operatorCanRegisterAfterAggregatorInitialization() public {
        bytes32 requestId = _initializeBinaryRequest("");

        _registerExternally(requestId);

        RequestData memory request = reporter.getRequest(requestId);
        assertTrue(request.registered);
        assertFalse(request.initialized);
    }
}

/*--------------------------------------------------------------
                         RULE UPDATES
--------------------------------------------------------------*/

contract OOReporterIntegrationTest_ruleUpdates is OOReporterIntegrationTest {
    event OOReporterRulesForwardFailed(bytes32 indexed requestId, bytes reason);

    function test_updateRules_ignoresResolvedProductionOOReporterRequest() public {
        bytes32 requestId = _initializeBinaryRequest("");
        _registerExternally(requestId);
        _initializeUMARequest(requestId);
        _settle(requestId, BINARY_IDENTIFIER, 1e18);

        bytes memory expectedReason = abi.encodeWithSelector(IOOReporter.RequestAlreadyResolved.selector);
        vm.expectEmit(true, false, false, true, address(module));
        emit OOReporterRulesForwardFailed(requestId, expectedReason);

        vm.prank(operator);
        aggregator.updateRequestRules(requestId, bytes("revised"));

        assertEq(aggregator.getRuleCount(requestId), 1);
    }

    function test_revert_updateRules_whenProductionOOReporterRequesterRoleIsRevoked() public {
        bytes32 requestId = _initializeBinaryRequest("");
        _registerExternally(requestId);

        vm.prank(umaOwner);
        reporter.setRequesterEnabled(address(module), false);

        vm.prank(operator);
        vm.expectRevert(IOOReporter.CallerNotRequester.selector);
        aggregator.updateRequestRules(requestId, bytes("revised"));

        assertEq(aggregator.getRuleCount(requestId), 0);
    }
}

/*--------------------------------------------------------------
                          SETTLEMENT
--------------------------------------------------------------*/

contract OOReporterIntegrationTest_settlement is OOReporterIntegrationTest {
    function test_binarySettlement_reportsThenFinalizesAfterPolymarketLiveness() public {
        bytes32 requestId = _initializeBinaryRequest("");
        _registerExternally(requestId);
        _initializeUMARequest(requestId);
        _settle(requestId, BINARY_IDENTIFIER, 1e18);

        _reportAndFinalize(requestId);

        assertTrue(_isConditionResolved(requestId));
        uint256[] memory result = positions.binaryModule.getResult(ConditionIdLib.from(requestId));
        assertEq(result[0], RESULT_DENOMINATOR);
        assertEq(result[1], 0);
    }

    function test_atomicSettlement_reportsThenFinalizesAfterPolymarketLiveness() public {
        bytes32 requestId = _nextEventId(ModuleIds.NEGRISK);

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(requestId),
                marketType: OracleAggregator.MarketType.ATOMIC_NEGRISK,
                targetContract: address(positions.negRiskModule),
                resultLength: 1,
                reporterModules: _reporterModules(_registrationData(requestId)),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(module)
            })
        );
        _initializeUMARequest(requestId);
        _settle(requestId, NUMERICAL_IDENTIFIER, 1e18);

        _reportAndFinalize(requestId);

        assertTrue(_isConditionResolved(requestId));
        bytes32 winningCondition =
            bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventIdLib.from(requestId), 1)));
        uint256[] memory result = positions.negRiskModule.getResult(ConditionIdLib.from(winningCondition));
        assertEq(result[0], RESULT_DENOMINATOR);
        assertEq(result[1], 0);
    }
}

/*--------------------------------------------------------------
                          UMA DISPUTE
--------------------------------------------------------------*/

contract OOReporterIntegrationTest_umaDispute is OOReporterIntegrationTest {
    function test_firstDispute_usesRealReporterAutomaticRerequest() public {
        bytes32 requestId = _initializeBinaryRequest("");
        _registerExternally(requestId);
        _initializeUMARequest(requestId);

        RequestData memory initialRequest = reporter.getRequest(requestId);
        vm.warp(block.timestamp + 1);
        optimisticOracle.dispute({
            requester: address(reporter),
            identifier: BINARY_IDENTIFIER,
            timestamp: initialRequest.requestTimestamp,
            requestRules: requestRules
        });

        RequestData memory rerequested = reporter.getRequest(requestId);
        assertTrue(rerequested.automaticDisputeRerequestUsed);
        assertGt(rerequested.requestTimestamp, initialRequest.requestTimestamp);
        assertEq(rerequested.manualRerequestsRemaining, initialRequest.manualRerequestsRemaining);
    }
}

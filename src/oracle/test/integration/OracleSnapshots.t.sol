// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { ModuleTestBase } from "@polymarket-v2/src/oracle/test/common/ModuleTestBase.sol";
import { OOReporterModule } from "@polymarket-v2/src/oracle/modules/OOReporterModule.sol";
import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { ConditionId, EventId, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";

/// @notice Minimal UMA OOReporter mock for gas snapshots.
contract MockOOReporterSnapshots {
    uint256 public registerCallCount;
    mapping(bytes32 => bool) public resolved;
    mapping(bytes32 => int256) public resolutions;

    function registerRequest(bytes32, bytes32, bytes calldata, uint64, uint64) external {
        registerCallCount++;
    }

    function updateRequestRules(bytes32, bytes calldata) external { }

    function isRequestResolved(bytes32 requestId) external view returns (bool) {
        return resolved[requestId];
    }

    function getRequestResolution(bytes32 requestId) external view returns (int256) {
        return resolutions[requestId];
    }

    function resolveRequest(bytes32 requestId, int256 resolution) external {
        resolved[requestId] = true;
        resolutions[requestId] = resolution;
    }
}

/// @notice Gas snapshot tests for core oracle operations.
/// @dev Run with: forge snapshot --match-contract OracleSnapshotsTest
/// @dev Snapshots are written to snapshots/OracleSnapshotsTest.json
contract OracleSnapshotsTest is ModuleTestBase {
    OOReporterModule public ooModule;
    MockOOReporterSnapshots public mockReporter;

    address public user = makeAddr("user");

    bytes public requestRules = bytes("Will candidate listed at the bottom win?");
    int256 public constant YES_PRICE = 1e18;
    uint64 public constant MINIMUM_LIVENESS = 1 hours;
    uint64 public constant MAXIMUM_LIVENESS = 2 days;

    function setUp() public virtual override {
        super.setUp();

        mockReporter = new MockOOReporterSnapshots();
        ooModule = OOReporterModule(LibClone.deployERC1967(address(new OOReporterModule(address(mockReporter)))));
        ooModule.initialize(owner, admin, address(aggregator));

        vm.prank(admin);
        ooModule.addOperator(user);
    }

    /*--------------------------------------------------------------
                            HELPERS
    --------------------------------------------------------------*/

    /// @dev A disputer entry registered but never exercised, for requests with no functional
    ///      dispute path. The address is only membership-checked, so a non-controlled address
    ///      with empty init data suffices.
    function _sentinelDisputerModules() internal pure returns (OracleAggregator.ModuleConfig[] memory modules) {
        modules = new OracleAggregator.ModuleConfig[](1);
        modules[0] = OracleAggregator.ModuleConfig({ module: address(uint160(0xD15D15)), initData: "" });
    }

    function _ooReporterModules() internal view returns (OracleAggregator.ModuleConfig[] memory modules) {
        modules = new OracleAggregator.ModuleConfig[](1);
        modules[0] = OracleAggregator.ModuleConfig({ module: address(ooModule), initData: "" });
    }

    function _initBinaryOOEvent() internal returns (bytes32 eventId) {
        eventId = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId(abi.encode("oo-binary"))));

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: _ooReporterModules(),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(ooModule)
            })
        );
    }

    function _initNegRiskOOEvent(uint8 conditionCount) internal returns (bytes32 eventId) {
        eventId = bytes32(EventId.unwrap(positions.negRiskModule.getEventId(conditionCount, abi.encode("oo-negrisk"))));

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.INCREMENTAL_NEGRISK,
                targetContract: address(positions.negRiskModule),
                resultLength: 1,
                reporterModules: _ooReporterModules(),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(ooModule)
            })
        );
    }

    function _registerOORequest(bytes32 requestId) internal {
        vm.prank(user);
        ooModule.createRequest(requestId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }

    function _registerNumericalOORequest(bytes32 requestId) internal {
        vm.prank(user);
        ooModule.createRequest(requestId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
    }
}

/*--------------------------------------------------------------
                    BINARY SNAPSHOTS
--------------------------------------------------------------*/

contract OracleSnapshotsTest_binary is OracleSnapshotsTest {
    function test_binary_initializeRequest() public {
        bytes32 eventId =
            bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId(abi.encode("snap_binary_init"))));

        vm.prank(operator);
        vm.startSnapshotGas("binary_initializeRequest");
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: _ooReporterModules(),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(ooModule)
            })
        );
        vm.stopSnapshotGas();
    }

    function test_binary_createRequest() public {
        bytes32 eventId = _initBinaryOOEvent();

        vm.prank(user);
        vm.startSnapshotGas("binary_createRequest");
        ooModule.createRequest(eventId, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
        vm.stopSnapshotGas();
    }

    function test_binary_report() public {
        bytes32 eventId = _initBinaryOOEvent();
        _registerOORequest(eventId);
        mockReporter.resolveRequest(eventId, YES_PRICE);

        vm.startSnapshotGas("binary_report");
        ooModule.report(eventId);
        vm.stopSnapshotGas();
    }

    function test_binary_finalize() public {
        bytes32 eventId = _initBinaryOOEvent();
        _registerOORequest(eventId);
        mockReporter.resolveRequest(eventId, YES_PRICE);
        ooModule.report(eventId);
        vm.warp(_getDisputeWindowEnd(eventId));

        vm.startSnapshotGas("binary_finalize");
        ooModule.finalize(eventId);
        vm.stopSnapshotGas();
    }
}

/*--------------------------------------------------------------
                    NEGRISK SNAPSHOTS
--------------------------------------------------------------*/

contract OracleSnapshotsTest_negRisk is OracleSnapshotsTest {
    function test_negRisk_initializeRequest() public {
        bytes32 eventId =
            bytes32(EventId.unwrap(positions.negRiskModule.getEventId(2, abi.encode("snap_negrisk_init"))));
        bytes32 c0 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 0)));

        vm.prank(operator);
        vm.startSnapshotGas("negRisk_initializeRequest");
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.INCREMENTAL_NEGRISK,
                targetContract: address(positions.negRiskModule),
                resultLength: 1,
                reporterModules: _ooReporterModules(),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(ooModule)
            })
        );
        vm.stopSnapshotGas();
    }

    function test_negRisk_createRequest() public {
        bytes32 eventId = _initNegRiskOOEvent(2);
        bytes32 c0 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 0)));

        vm.prank(user);
        vm.startSnapshotGas("negRisk_createRequest");
        ooModule.createRequest(c0, requestRules, MINIMUM_LIVENESS, MAXIMUM_LIVENESS);
        vm.stopSnapshotGas();
    }

    function test_negRisk_reportAndFinalize() public {
        bytes32 eventId = _initNegRiskOOEvent(2);
        bytes32 c0 = bytes32(ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 0)));
        _registerOORequest(c0);
        mockReporter.resolveRequest(c0, YES_PRICE);

        ooModule.report(c0);
        vm.warp(_getDisputeWindowEnd(c0));
        ooModule.finalize(c0);

        assertTrue(_getConditionStatus(c0) == OracleAggregator.ResolutionStatus.Resolved);
    }

    function test_negRisk_atomicReportAndFinalize() public {
        bytes32 eventId =
            bytes32(EventId.unwrap(positions.negRiskModule.getEventId(3, abi.encode("oo-atomic-negrisk"))));

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.ATOMIC_NEGRISK,
                targetContract: address(positions.negRiskModule),
                resultLength: 1,
                reporterModules: _ooReporterModules(),
                reporterThreshold: 1,
                disputerModules: _sentinelDisputerModules(),
                disputerThreshold: 1,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(ooModule)
            })
        );

        _registerNumericalOORequest(eventId);
        mockReporter.resolveRequest(eventId, 1e18);

        ooModule.report(eventId);
        vm.warp(_getDisputeWindowEnd(eventId));
        ooModule.finalize(eventId);

        assertTrue(_getConditionStatus(eventId) == OracleAggregator.ResolutionStatus.Resolved);
    }
}

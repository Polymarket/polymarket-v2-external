// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "lib/forge-std/src/Test.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";

import { EOAReporterModule } from "@polymarket-v2/src/oracle/modules/reporters/EOAReporterModule.sol";
import { MockDisputerModule } from "@polymarket-v2/src/oracle/test/mocks/MockDisputerModule.sol";
import { MockArbitratorModule } from "@polymarket-v2/src/oracle/test/mocks/MockArbitratorModule.sol";

import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { ConditionId, ConditionIdLib, EventId, EventIdLib, PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";

import {
    Positions,
    Collateral,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";

/// @title ModuleTestBase
/// @notice Shared test base contract for module tests using real OracleAggregator
/// @dev Tests extending this contract test against real aggregator logic, not mocks
abstract contract ModuleTestBase is Test {
    error Unauthorized();

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    // Core contracts
    OracleAggregator public aggregator;
    Positions public positions;
    Collateral public collateral;
    // Supporting modules for event creation
    EOAReporterModule public eoaReporter;
    EOAReporterModule public eoaReporter2;
    MockDisputerModule public mockDisputer;
    MockArbitratorModule public mockArbitrator;

    // Standard actors
    address public owner = makeAddr("owner");
    address public admin = makeAddr("admin");
    address public operator = makeAddr("operator");

    // Default reporters for EOAReporterModule
    address public reporter1 = makeAddr("reporter1");
    address public reporter2 = makeAddr("reporter2");
    address public reporter3 = makeAddr("reporter3");

    // Default disputers
    address public disputer1 = makeAddr("disputer1");
    address public disputer2 = makeAddr("disputer2");

    // Constants
    uint256 public constant RESULT_DENOMINATOR = 1_000_000;
    uint16 public defaultReporterThreshold = 2;
    uint16 public defaultDisputerThreshold = 1;
    uint32 public defaultLivenessWindow = 5 minutes;

    // Counter for unique event IDs
    uint256 internal _eventIdCounter;

    /*--------------------------------------------------------------
                                 SETUP
    --------------------------------------------------------------*/

    function setUp() public virtual {
        _deployPositions();
        _deployAggregator();
        _setupRoles();
        _deploySupportingModules();
        _grantResolverRoles();
    }

    function _deployPositions() internal {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, address(this));
    }

    function _deployAggregator() internal {
        OracleAggregator implementation = new OracleAggregator(address(positions.manager));
        address proxy = LibClone.deployERC1967(address(implementation));
        aggregator = OracleAggregator(proxy);
        aggregator.initialize(owner, owner);
    }

    function _setupRoles() internal {
        vm.startPrank(owner);
        aggregator.addAdmin(admin);
        vm.stopPrank();

        vm.startPrank(admin);
        aggregator.addOperator(operator);
        vm.stopPrank();
    }

    function _deploySupportingModules() internal {
        eoaReporter = EOAReporterModule(_deployProxy(address(new EOAReporterModule())));
        eoaReporter.initialize(owner, admin, address(aggregator));

        eoaReporter2 = EOAReporterModule(_deployProxy(address(new EOAReporterModule())));
        eoaReporter2.initialize(owner, admin, address(aggregator));

        mockDisputer = new MockDisputerModule(address(aggregator));
        mockArbitrator = new MockArbitratorModule(address(aggregator));
    }

    function _deployProxy(address _implementation) internal returns (address) {
        return LibClone.deployERC1967(_implementation);
    }

    function _grantResolverRoles() internal {
        vm.startPrank(admin);
        positions.binaryModule.addResolver(address(aggregator));
        positions.negRiskModule.addResolver(address(aggregator));
        vm.stopPrank();
    }

    /*--------------------------------------------------------------
                        MARKET CREATION HELPERS
    --------------------------------------------------------------*/

    function _nextEventId(uint256 _moduleId) internal returns (bytes32) {
        _eventIdCounter++;
        if (_moduleId == ModuleIds.NEGRISK) {
            return
                bytes32(EventId.unwrap(positions.negRiskModule.getEventId(3, abi.encode("negrisk", _eventIdCounter))));
        }
        return bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId(abi.encode("binary", _eventIdCounter))));
    }

    function _nextEventId() internal returns (bytes32) {
        return _nextEventId(ModuleIds.BINARY);
    }

    /// @notice Creates a standard binary event with default modules
    function _createBinaryEvent() internal returns (bytes32) {
        return _createBinaryEventWithConfig(defaultReporterThreshold, defaultDisputerThreshold, defaultLivenessWindow);
    }

    /// @notice Creates a binary event with custom configuration
    function _createBinaryEventWithConfig(uint16 reporterThreshold, uint16 disputerThreshold, uint32 livenessWindow)
        internal
        returns (bytes32)
    {
        address[] memory reporters = new address[](3);
        reporters[0] = reporter1;
        reporters[1] = reporter2;
        reporters[2] = reporter3;

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](2);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(reporters) });
        reporterModules[1] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter2), initData: abi.encode(reporters) });

        address[] memory disputers = new address[](2);
        disputers[0] = disputer1;
        disputers[1] = disputer2;

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        bytes32 conditionId = _nextEventId();

        return _initializeBinaryEvent(
            conditionId,
            reporterModules,
            reporterThreshold,
            disputerModules,
            disputerThreshold,
            address(mockArbitrator),
            "",
            livenessWindow
        );
    }

    /// @notice Creates a binary event with a custom arbitrator module
    function _createBinaryEventWithArbitrator(address arbitratorModule, bytes memory arbitratorInitData)
        internal
        returns (bytes32)
    {
        address[] memory reporters = new address[](3);
        reporters[0] = reporter1;
        reporters[1] = reporter2;
        reporters[2] = reporter3;

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](2);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(reporters) });
        reporterModules[1] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter2), initData: abi.encode(reporters) });

        address[] memory disputers = new address[](2);
        disputers[0] = disputer1;
        disputers[1] = disputer2;

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        bytes32 conditionId = _nextEventId();

        return _initializeBinaryEvent(
            conditionId,
            reporterModules,
            defaultReporterThreshold,
            disputerModules,
            defaultDisputerThreshold,
            arbitratorModule,
            arbitratorInitData,
            defaultLivenessWindow
        );
    }

    /// @notice Creates a binary event with custom reporter module(s)
    function _createBinaryEventWithReporter(
        OracleAggregator.ModuleConfig[] memory reporterModules,
        uint16 reporterThreshold
    ) internal returns (bytes32) {
        address[] memory disputers = new address[](2);
        disputers[0] = disputer1;
        disputers[1] = disputer2;

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        bytes32 conditionId = _nextEventId();

        return _initializeBinaryEvent(
            conditionId,
            reporterModules,
            reporterThreshold,
            disputerModules,
            defaultDisputerThreshold,
            address(mockArbitrator),
            "",
            defaultLivenessWindow
        );
    }

    /// @notice Creates a binary event with custom disputer module(s)
    function _createBinaryEventWithDisputer(
        OracleAggregator.ModuleConfig[] memory disputerModules,
        uint16 disputerThreshold
    ) internal returns (bytes32) {
        address[] memory reporters = new address[](3);
        reporters[0] = reporter1;
        reporters[1] = reporter2;
        reporters[2] = reporter3;

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](2);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter), initData: abi.encode(reporters) });
        reporterModules[1] =
            OracleAggregator.ModuleConfig({ module: address(eoaReporter2), initData: abi.encode(reporters) });

        bytes32 conditionId = _nextEventId();

        return _initializeBinaryEvent(
            conditionId,
            reporterModules,
            defaultReporterThreshold,
            disputerModules,
            disputerThreshold,
            address(mockArbitrator),
            "",
            defaultLivenessWindow
        );
    }

    function _initializeBinaryEvent(
        bytes32 conditionId,
        OracleAggregator.ModuleConfig[] memory reporterModules,
        uint16 reporterThreshold,
        OracleAggregator.ModuleConfig[] memory disputerModules,
        uint16 disputerThreshold,
        address arbitratorModule,
        bytes memory arbitratorInitData,
        uint32 livenessWindow
    ) internal returns (bytes32) {
        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(conditionId),
                marketType: OracleAggregator.MarketType.BINARY,
                targetContract: address(positions.binaryModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: reporterThreshold,
                disputerModules: disputerModules,
                disputerThreshold: disputerThreshold,
                arbitratorModule: arbitratorModule,
                arbitratorInitData: arbitratorInitData,
                livenessWindow: livenessWindow,
                finalizer: address(0)
            })
        );
        return conditionId;
    }

    /*--------------------------------------------------------------
                        STATE TRANSITION HELPERS
    --------------------------------------------------------------*/

    /// @notice Reports with enough reporters to meet threshold and create proposal
    function _reportAndMeetThreshold(bytes32 eventId) internal {
        _reportAndMeetThreshold(eventId, _yesPayouts());
    }

    /// @notice Reports via two distinct modules to meet threshold
    function _reportAndMeetThreshold(bytes32 eventId, uint256[] memory result) internal {
        vm.prank(reporter1);
        eoaReporter.report(eventId, result);

        vm.prank(reporter1);
        eoaReporter2.report(eventId, result);
    }

    /// @notice Files dispute and triggers arbitration if threshold met
    function _dispute(bytes32 eventId) internal {
        vm.prank(disputer1);
        mockDisputer.dispute(eventId);
    }

    /// @notice Creates an event, reports to meet threshold, and disputes to trigger arbitration
    function _createEventAndTriggerArbitration() internal returns (bytes32) {
        bytes32 eventId = _createBinaryEvent();
        _reportAndMeetThreshold(eventId);
        _dispute(eventId);
        return eventId;
    }

    /// @notice Creates an event and reports to create a proposal (but not disputed)
    function _createEventWithProposal() internal returns (bytes32) {
        bytes32 eventId = _createBinaryEvent();
        _reportAndMeetThreshold(eventId);
        return eventId;
    }

    /*--------------------------------------------------------------
                      RESULT HELPERS
    --------------------------------------------------------------*/

    function _yesPayouts() internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](1);
        result[0] = RESULT_DENOMINATOR;
        return result;
    }

    function _noPayouts() internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](1);
        result[0] = 0;
        return result;
    }

    function _fiftyFiftyPayouts() internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](1);
        result[0] = RESULT_DENOMINATOR / 2;
        return result;
    }

    function _invalidPayouts() internal pure returns (uint256[] memory) {
        uint256[] memory result = new uint256[](1);
        result[0] = RESULT_DENOMINATOR + 1;
        return result;
    }

    /*--------------------------------------------------------------
                       STATE VERIFICATION HELPERS
    --------------------------------------------------------------*/

    function _getConditionStatus(bytes32 conditionId) internal view returns (OracleAggregator.ResolutionStatus) {
        (OracleAggregator.ResolutionStatus status,,,) = aggregator.getRequestState(conditionId);
        return status;
    }

    function _getProposedResultHash(bytes32 conditionId) internal view returns (bytes32) {
        (, bytes32 proposedResultHash,,) = aggregator.getRequestState(conditionId);
        return proposedResultHash;
    }

    function _getDisputeWindowEnd(bytes32 conditionId) internal view returns (uint256) {
        (,, uint256 disputeWindowEnd,) = aggregator.getRequestState(conditionId);
        return disputeWindowEnd;
    }

    function _getDisputeCount(bytes32 conditionId) internal view returns (uint256) {
        (,,, uint256 disputeCount) = aggregator.getRequestState(conditionId);
        return disputeCount;
    }

    function _isConditionActive(bytes32 conditionId) internal view returns (bool) {
        return _getConditionStatus(conditionId) == OracleAggregator.ResolutionStatus.Active;
    }

    function _isConditionDisputed(bytes32 conditionId) internal view returns (bool) {
        return _getConditionStatus(conditionId) == OracleAggregator.ResolutionStatus.ArbitrationRequested;
    }

    function _isConditionResolved(bytes32 conditionId) internal view returns (bool) {
        return _getConditionStatus(conditionId) == OracleAggregator.ResolutionStatus.Resolved;
    }
}

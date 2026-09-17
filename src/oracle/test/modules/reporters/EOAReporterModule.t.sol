// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { ModuleTestBase } from "@polymarket-v2/src/oracle/test/common/ModuleTestBase.sol";
import { OracleModuleBase } from "@polymarket-v2/src/oracle/abstract/OracleModuleBase.sol";
import { EOAReporterModule } from "@polymarket-v2/src/oracle/modules/reporters/EOAReporterModule.sol";
import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { OracleAggregatorErrors } from "@polymarket-v2/src/oracle/abstract/OracleAggregatorErrors.sol";
import { ConditionId, EventId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";

contract EOAReporterModuleTest is ModuleTestBase {
    EOAReporterModule public module;

    function setUp() public virtual override {
        super.setUp();

        module = EOAReporterModule(LibClone.deployERC1967(address(new EOAReporterModule())));
        module.initialize(owner, admin, address(aggregator));
    }

    /*--------------------------------------------------------------
                            HELPERS
    --------------------------------------------------------------*/

    function _createEvent() internal returns (bytes32) {
        address[] memory reporters = new address[](3);
        reporters[0] = reporter1;
        reporters[1] = reporter2;
        reporters[2] = reporter3;

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] = OracleAggregator.ModuleConfig({ module: address(module), initData: abi.encode(reporters) });

        return _createBinaryEventWithReporter(reporterModules, 1);
    }
}

/*--------------------------------------------------------------
                        CONSTRUCTOR
--------------------------------------------------------------*/

contract EOAReporterModuleTest_constructor is EOAReporterModuleTest {
    function test_constructor() public view {
        assertEq(module.aggregator(), address(aggregator));
        assertEq(module.owner(), owner);
    }
}

/*--------------------------------------------------------------
                        INITIALIZER
--------------------------------------------------------------*/

contract EOAReporterModuleTest_initializer is EOAReporterModuleTest {
    function test_revert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        module.initialize(owner, admin, address(aggregator));
    }

    function test_revert_initialize_onImplementation() public {
        EOAReporterModule implementation = new EOAReporterModule();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, admin, address(aggregator));
    }
}

/*--------------------------------------------------------------
                          UPGRADE
--------------------------------------------------------------*/

contract EOAReporterModuleTest_upgrade is EOAReporterModuleTest {
    function test_upgradeToAndCall() public {
        address newImpl = address(new EOAReporterModule());

        vm.prank(owner);
        module.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(new EOAReporterModule());

        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector);
        module.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
                    INITIALIZE REQUEST
--------------------------------------------------------------*/

contract EOAReporterModuleTest_initializeRequest is EOAReporterModuleTest {
    function test_initializeRequest() public {
        bytes32 mktId = _createEvent();

        assertTrue(module.requestInitialized(ConditionId.wrap(bytes31(mktId))));
        assertTrue(module.isReporter(EventIdLib.from(mktId), reporter1));
        assertTrue(module.isReporter(EventIdLib.from(mktId), reporter2));
        assertTrue(module.isReporter(EventIdLib.from(mktId), reporter3));
    }

    function test_revert_onlyAggregator() public {
        address[] memory reporters = new address[](1);
        reporters[0] = reporter1;

        vm.prank(admin);
        vm.expectRevert(OracleModuleBase.NotAggregator.selector);
        module.initializeReporterModule(EventId.wrap(bytes29(keccak256("test"))), abi.encode(reporters));
    }

    function test_revert_cannotReinitialize() public {
        bytes32 mktId = _createEvent();

        address[] memory reporters = new address[](1);
        reporters[0] = reporter1;

        vm.prank(address(aggregator));
        vm.expectRevert(OracleModuleBase.RequestAlreadyInitialized.selector);
        module.initializeReporterModule(EventIdLib.from(mktId), abi.encode(reporters));
    }

    function test_revert_emptyReporters() public {
        EventId eventId = EventId.wrap(bytes29(keccak256("empty-reporters")));
        address[] memory reporters = new address[](0);

        vm.prank(address(aggregator));
        vm.expectRevert(EOAReporterModule.EmptyReporters.selector);
        module.initializeReporterModule(eventId, abi.encode(reporters));

        assertFalse(module.requestInitialized(eventId.asCondition()));
    }
}

/*--------------------------------------------------------------
                        REPORT
--------------------------------------------------------------*/

contract EOAReporterModuleTest_report is EOAReporterModuleTest {
    function test_revert_unauthorizedReporter() public {
        bytes32 mktId = _createEvent();

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(EOAReporterModule.NotAuthorizedReporter.selector);
        module.report(mktId, _yesPayouts());
    }

    function test_revert_alreadyReported() public {
        bytes32 mktId = _createEvent();

        vm.prank(reporter1);
        module.report(mktId, _yesPayouts());

        vm.prank(reporter1);
        vm.expectRevert(OracleModuleBase.AlreadyReported.selector);
        module.report(mktId, _yesPayouts());
    }

    function test_revert_eventNotInitialized() public {
        bytes32 nonexistent = bytes32(uint256(keccak256("nonexistent")) & ~uint256(0xFF));
        vm.prank(reporter1);
        vm.expectRevert(OracleModuleBase.RequestNotInitialized.selector);
        module.report(nonexistent, _yesPayouts());
    }

    function test_updatesAggregatorState() public {
        bytes32 mktId = _createEvent();

        vm.prank(reporter1);
        module.report(mktId, _yesPayouts());

        // Threshold is 1, so proposal is created immediately
        bytes32 expectedHash = keccak256(abi.encode(_yesPayouts()));
        (, bytes32 proposedHash,,) = aggregator.getRequestState(mktId);
        assertEq(proposedHash, expectedHash);

        assertEq(aggregator.getReportVotes(mktId, _yesPayouts()), 1);
    }

    function test_revert_invalidResultSum() public {
        bytes32 mktId = _createEvent();

        vm.prank(reporter1);
        vm.expectRevert(OracleAggregatorErrors.InvalidResultSum.selector);
        module.report(mktId, _invalidPayouts());
    }

    function test_revert_invalidResultLength() public {
        bytes32 mktId = _createEvent();

        uint256[] memory invalidResult = new uint256[](3);
        invalidResult[0] = RESULT_DENOMINATOR;

        vm.prank(reporter1);
        vm.expectRevert(OracleAggregatorErrors.InvalidResultLength.selector);
        module.report(mktId, invalidResult);
    }
}

/*--------------------------------------------------------------
                        ADMIN
--------------------------------------------------------------*/

contract EOAReporterModuleTest_admin is EOAReporterModuleTest {
    function test_setAggregator() public {
        address newAggregator = makeAddr("newAggregator");

        vm.prank(admin);
        module.setAggregator(newAggregator);

        assertEq(module.aggregator(), newAggregator);
    }

    function test_revert_setAggregator_onlyAdmin() public {
        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        module.setAggregator(makeAddr("newAggregator"));
    }

    /// @notice Owner can remove an admin via removeAdmin
    function test_removeAdmin() public {
        // _ROLE_0 = 1 << 0 = 1 (admin role in Solady OwnableRoles)
        uint256 ADMIN_ROLE = 1;

        // Verify admin has the role before removal
        assertTrue(module.hasAllRoles(admin, ADMIN_ROLE));

        // Admin removes themselves (onlyAdmin guard)
        vm.prank(admin);
        module.removeAdmin(admin);

        // Admin role should be revoked
        assertFalse(module.hasAllRoles(admin, ADMIN_ROLE));
    }

    /// @notice Admin can remove an operator via removeOperator
    function test_removeOperator() public {
        // _ROLE_1 = 1 << 1 = 2 (operator role)
        uint256 OPERATOR_ROLE = 2;
        address op = makeAddr("testOperator");

        // Admin grants operator role
        vm.prank(admin);
        module.addOperator(op);
        assertTrue(module.hasAllRoles(op, OPERATOR_ROLE));

        // Admin removes operator
        vm.prank(admin);
        module.removeOperator(op);
        assertFalse(module.hasAllRoles(op, OPERATOR_ROLE));
    }

    /// @notice Non-admin cannot call removeAdmin
    function test_revert_removeAdmin_unauthorized() public {
        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        module.removeAdmin(admin);
    }

    /// @notice Non-admin cannot call removeOperator
    function test_revert_removeOperator_unauthorized() public {
        address op = makeAddr("testOperator");

        vm.prank(admin);
        module.addOperator(op);

        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        module.removeOperator(op);
    }
}

/*--------------------------------------------------------------
                        VIEW
--------------------------------------------------------------*/

contract EOAReporterModuleTest_view is EOAReporterModuleTest {
    function test_isReporter() public {
        bytes32 mktId = _createEvent();

        assertTrue(module.isReporter(EventIdLib.from(mktId), reporter1));
        assertTrue(module.isReporter(EventIdLib.from(mktId), reporter2));
        assertTrue(module.isReporter(EventIdLib.from(mktId), reporter3));
        assertFalse(module.isReporter(EventIdLib.from(mktId), makeAddr("unauthorized")));
    }

    function test_hasReporterReported() public {
        bytes32 mktId = _createEvent();
        assertFalse(module.hasReporterReported(ConditionIdLib.from(mktId), reporter1));
        assertFalse(module.hasReporterReported(ConditionIdLib.from(mktId), reporter2));

        vm.prank(reporter1);
        module.report(mktId, _yesPayouts());

        assertTrue(module.hasReporterReported(ConditionIdLib.from(mktId), reporter1));
        assertFalse(module.hasReporterReported(ConditionIdLib.from(mktId), reporter2));
    }
}

/*--------------------------------------------------------------
            INCREMENTAL NEGRISK (OracleModuleBase branch)
--------------------------------------------------------------*/

contract EOAReporterModuleTest_incrementalNegRisk is EOAReporterModuleTest {
    /// @notice Reports on a sub-condition where conditionId != eventId
    function test_reportOnSubCondition() public {
        // Create a NegRisk event with 3 sub-conditions
        address[] memory reporters = new address[](3);
        reporters[0] = reporter1;
        reporters[1] = reporter2;
        reporters[2] = reporter3;

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] = OracleAggregator.ModuleConfig({ module: address(module), initData: abi.encode(reporters) });

        address[] memory disputers = new address[](2);
        disputers[0] = disputer1;
        disputers[1] = disputer2;

        OracleAggregator.ModuleConfig[] memory disputerModules = new OracleAggregator.ModuleConfig[](1);
        disputerModules[0] =
            OracleAggregator.ModuleConfig({ module: address(mockDisputer), initData: abi.encode(disputers) });

        bytes32 eventId = _nextEventId(ModuleIds.NEGRISK);

        vm.prank(operator);
        aggregator.initializeRequest(
            OracleAggregator.InitParams({
                eventId: EventIdLib.from(eventId),
                marketType: OracleAggregator.MarketType.INCREMENTAL_NEGRISK,
                targetContract: address(positions.negRiskModule),
                resultLength: 1,
                reporterModules: reporterModules,
                reporterThreshold: 1,
                disputerModules: disputerModules,
                disputerThreshold: defaultDisputerThreshold,
                arbitratorModule: address(mockArbitrator),
                arbitratorInitData: "",
                livenessWindow: defaultLivenessWindow,
                finalizer: address(0)
            })
        );

        // Derive sub-condition ID at index 1
        // (conditionId != eventId, exercises else branch)
        bytes32 conditionId = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(eventId)), 1));

        // Report on the sub-condition
        vm.prank(reporter1);
        module.report(conditionId, _yesPayouts());

        // Verify the report was accepted
        assertTrue(module.hasReporterReported(ConditionIdLib.from(conditionId), reporter1));
        assertEq(aggregator.getReportVotes(conditionId, _yesPayouts()), 1);
    }
}

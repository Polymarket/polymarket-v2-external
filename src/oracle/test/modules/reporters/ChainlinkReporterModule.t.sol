// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { ModuleTestBase } from "@polymarket-v2/src/oracle/test/common/ModuleTestBase.sol";
import { OracleModuleBase } from "@polymarket-v2/src/oracle/abstract/OracleModuleBase.sol";
import { Pausable } from "@polymarket-v2/src/oracle/mixins/Pausable.sol";
import { ChainlinkReporterModule } from "@polymarket-v2/src/oracle/modules/reporters/ChainlinkReporterModule.sol";
import { OracleAggregator } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { ConditionId, ConditionIdLib, EventId, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";

contract MockDataStore {
    error KeyNotWritten();

    mapping(address => mapping(bytes32 => bool)) public written;
    mapping(address => mapping(bytes32 => bytes32)) public values;

    function write(address _writer, bytes32 _key, bytes32 _value) external {
        written[_writer][_key] = true;
        values[_writer][_key] = _value;
    }

    function isWritten(address _writer, bytes32 _key) external view returns (bool) {
        return written[_writer][_key];
    }

    function read(address _writer, bytes32 _key) external view returns (bytes32) {
        if (!written[_writer][_key]) revert KeyNotWritten();
        return values[_writer][_key];
    }
}

contract ChainlinkReporterModuleTest is ModuleTestBase {
    ChainlinkReporterModule public module;
    MockDataStore public dataStore;

    address public priceSource = makeAddr("priceSource");

    bytes32 public constant BTC_USD = "BTC_USD";
    bytes32 public constant BTC_FEED = bytes32(uint256(1));
    uint256 public constant DURATION = 5 minutes;

    function setUp() public virtual override {
        super.setUp();

        dataStore = new MockDataStore();
        module =
            ChainlinkReporterModule(LibClone.deployERC1967(address(new ChainlinkReporterModule(address(dataStore)))));
        module.initialize(owner, owner, address(aggregator), priceSource);

        vm.prank(owner);
        module.setFeedId(BTC_USD, BTC_FEED);
    }

    /*--------------------------------------------------------------
                            HELPERS
    --------------------------------------------------------------*/

    function _createEvent(uint256 _startTimestamp) internal returns (bytes32) {
        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] = OracleAggregator.ModuleConfig({
            module: address(module), initData: abi.encode(BTC_USD, DURATION, _startTimestamp)
        });

        return _createBinaryEventWithReporter(reporterModules, 1);
    }

    function _writePrice(uint256 _timestamp, int192 _price) internal {
        _writeRawPrice(_timestamp, bytes32(uint256(int256(_price))));
    }

    function _writeRawPrice(uint256 _timestamp, bytes32 _price) internal {
        bytes32 key = keccak256(abi.encode(BTC_FEED, _timestamp));
        dataStore.write(priceSource, key, _price);
    }
}

/*--------------------------------------------------------------
                        INITIALIZER
--------------------------------------------------------------*/

contract ChainlinkReporterModuleTest_initializer is ChainlinkReporterModuleTest {
    function test_revert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        module.initialize(owner, owner, address(aggregator), priceSource);
    }

    function test_revert_initialize_onImplementation() public {
        ChainlinkReporterModule implementation = new ChainlinkReporterModule(address(dataStore));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, owner, address(aggregator), priceSource);
    }
}

/*--------------------------------------------------------------
                          UPGRADE
--------------------------------------------------------------*/

contract ChainlinkReporterModuleTest_upgrade is ChainlinkReporterModuleTest {
    function test_upgradeToAndCall() public {
        address newImpl = address(new ChainlinkReporterModule(address(dataStore)));

        vm.prank(owner);
        module.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(new ChainlinkReporterModule(address(dataStore)));

        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector);
        module.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
                    INITIALIZE REQUEST
--------------------------------------------------------------*/

contract ChainlinkReporterModuleTest_initializeRequest is ChainlinkReporterModuleTest {
    function test_initializeRequest() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        (bytes32 assetPair, uint256 duration, uint256 startTimestamp) =
            module.eventConfigs(EventId.wrap(bytes29(requestId)));
        assertEq(assetPair, BTC_USD);
        assertEq(duration, DURATION);
        assertEq(startTimestamp, start);
    }

    function test_revert_initializeRequest_notBinaryEvent() public {
        bytes32 negRiskEventId =
            bytes32(EventId.unwrap(positions.negRiskModule.getEventId(3, abi.encode("neg-risk-event"))));
        uint256 start = block.timestamp + 1;

        vm.prank(address(aggregator));
        vm.expectRevert(ChainlinkReporterModule.NotBinaryEvent.selector);
        module.initializeReporterModule(EventIdLib.from(negRiskEventId), abi.encode(BTC_USD, DURATION, start));
    }

    function test_revert_initializeRequest_windowAlreadyEnded() public {
        vm.warp(DURATION + 100);
        // start + duration == block.timestamp → fails the strict inequality
        uint256 staleStart = block.timestamp - DURATION;
        bytes32 binaryEventId =
            bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId(abi.encode("binary-stale"))));

        vm.prank(address(aggregator));
        vm.expectRevert(ChainlinkReporterModule.WindowAlreadyEnded.selector);
        module.initializeReporterModule(EventIdLib.from(binaryEventId), abi.encode(BTC_USD, DURATION, staleStart));
    }

    function test_revert_initializeRequest_zeroDuration() public {
        // even with a future start, a zero-length window must be rejected
        uint256 start = block.timestamp + 1;
        bytes32 binaryEventId =
            bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId(abi.encode("binary-zero-duration"))));

        vm.prank(address(aggregator));
        vm.expectRevert(ChainlinkReporterModule.ZeroDuration.selector);
        module.initializeReporterModule(EventIdLib.from(binaryEventId), abi.encode(BTC_USD, uint256(0), start));
    }
}

/*--------------------------------------------------------------
                        REPORT
--------------------------------------------------------------*/

contract ChainlinkReporterModuleTest_report is ChainlinkReporterModuleTest {
    function test_zeroLiveness_reportAndFinalizeInSameBlock() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        vm.prank(operator);
        aggregator.setLivenessWindow(requestId, 0);

        _writePrice(start, 100_000);
        _writePrice(start + DURATION, 110_000);

        vm.warp(start + DURATION + 1);
        uint256 reportingBlock = block.number;
        uint256 reportingTimestamp = block.timestamp;

        vm.prank(makeAddr("chainlinkReportRelayer"));
        module.report(requestId);

        (,, uint256 disputeWindowEnd,) = aggregator.getRequestState(requestId);
        assertEq(disputeWindowEnd, reportingTimestamp);

        vm.prank(makeAddr("permissionlessFinalizer"));
        aggregator.finalize(requestId, _yesPayouts());

        assertEq(block.number, reportingBlock);
        assertTrue(_isConditionResolved(requestId));
    }

    function test_priceUp() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, 100_000);
        _writePrice(start + DURATION, 110_000);

        vm.warp(start + DURATION + 1);
        module.report(requestId);

        (, bytes32 proposedHash,,) = aggregator.getRequestState(requestId);
        assertEq(proposedHash, keccak256(abi.encode(_yesPayouts())));

        vm.warp(block.timestamp + defaultLivenessWindow + 1);
        aggregator.finalize(requestId, _yesPayouts());

        uint256[] memory result = positions.binaryModule.getResult(ConditionIdLib.from(requestId));
        assertEq(result[0], RESULT_DENOMINATOR);
        assertEq(result[1], 0);
    }

    function test_priceDown() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, 100_000);
        _writePrice(start + DURATION, 90_000);

        vm.warp(start + DURATION + 1);
        module.report(requestId);

        (, bytes32 proposedHash,,) = aggregator.getRequestState(requestId);
        assertEq(proposedHash, keccak256(abi.encode(_noPayouts())));
    }

    function test_priceUpAcrossZero() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, -1);
        _writePrice(start + DURATION, 1);

        vm.expectEmit(true, true, false, true, address(module));
        emit ChainlinkReporterModule.RequestReported(
            EventId.wrap(bytes29(requestId)),
            module.computeQuestionId(BTC_USD, DURATION, start),
            -1,
            1,
            RESULT_DENOMINATOR
        );
        module.report(requestId);

        (, bytes32 proposedHash,,) = aggregator.getRequestState(requestId);
        assertEq(proposedHash, keccak256(abi.encode(_yesPayouts())));
    }

    function test_priceDownAcrossZero() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, 1);
        _writePrice(start + DURATION, -1);

        module.report(requestId);

        (, bytes32 proposedHash,,) = aggregator.getRequestState(requestId);
        assertEq(proposedHash, keccak256(abi.encode(_noPayouts())));
    }

    function test_priceUpWhileNegative() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, -10);
        _writePrice(start + DURATION, -5);

        module.report(requestId);

        (, bytes32 proposedHash,,) = aggregator.getRequestState(requestId);
        assertEq(proposedHash, keccak256(abi.encode(_yesPayouts())));
    }

    function testFuzz_signedPriceComparison(int192 startPrice, int192 endPrice) public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, startPrice);
        _writePrice(start + DURATION, endPrice);

        module.report(requestId);

        bytes32 expectedHash =
            endPrice >= startPrice ? keccak256(abi.encode(_yesPayouts())) : keccak256(abi.encode(_noPayouts()));
        (, bytes32 proposedHash,,) = aggregator.getRequestState(requestId);
        assertEq(proposedHash, expectedHash);
    }

    function test_revert_priceMissingInDataStore() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, 100_000);

        vm.warp(start + DURATION + 1);
        vm.expectRevert(MockDataStore.KeyNotWritten.selector);
        module.report(requestId);
    }

    function test_succeedsBeforeWindowEndWhenPricesExist() public {
        uint256 start = block.timestamp;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, 100_000);
        _writePrice(start + DURATION, 110_000);

        module.report(requestId);

        (, bytes32 proposedHash,,) = aggregator.getRequestState(requestId);
        assertEq(proposedHash, keccak256(abi.encode(_yesPayouts())));
    }

    function test_revert_eventNotInitialized() public {
        bytes32 missing = bytes32(uint256(keccak256("missing")) & ~uint256(0xFF));
        vm.expectRevert(OracleModuleBase.RequestNotInitialized.selector);
        module.report(missing);
    }

    function test_revert_whenPaused() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        _writePrice(start, 100_000);
        _writePrice(start + DURATION, 110_000);

        vm.prank(owner);
        module.pause();

        vm.warp(start + DURATION + 1);
        vm.expectRevert(Pausable.GlobalPaused.selector);
        module.report(requestId);
    }

    /// @notice report reverts when called with a subcondition request id rather than the parent
    ///         event id. This module only supports binary directional markets.
    function test_revert_report_nonBinaryRequestId() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        // Derive a subcondition ID (non-zero conditionIndex) from the initialized event.
        // The bottom outcome byte stays zero so ConditionIdLib.from accepts it; the canonicality
        // check that fires is the eventId-equivalence check inside report().
        bytes32 subconditionId = ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(requestId)), 1));

        vm.warp(start + DURATION + 1);
        vm.expectRevert(ChainlinkReporterModule.InvalidRequestId.selector);
        module.report(subconditionId);
    }

    /// @notice report reverts when feedId is not set for the asset pair
    function test_revert_feedIdNotSet() public {
        // Create event using a different asset pair that has no feedId
        bytes32 ETH_USD = "ETH_USD";
        uint256 start = block.timestamp + 1;

        OracleAggregator.ModuleConfig[] memory reporterModules = new OracleAggregator.ModuleConfig[](1);
        reporterModules[0] =
            OracleAggregator.ModuleConfig({ module: address(module), initData: abi.encode(ETH_USD, DURATION, start) });

        bytes32 requestId = _createBinaryEventWithReporter(reporterModules, 1);

        vm.warp(start + DURATION + 1);
        vm.expectRevert(ChainlinkReporterModule.FeedIdNotSet.selector);
        module.report(requestId);
    }
}

/*--------------------------------------------------------------
                        VIEW
--------------------------------------------------------------*/

contract ChainlinkReporterModuleTest_view is ChainlinkReporterModuleTest {
    /// @notice computeQuestionId returns deterministic hash
    function test_computeQuestionId() public view {
        uint256 start = 1000;
        bytes32 expected = keccak256(abi.encode(module.CHAINLINK_CANDLE_IDENTIFIER(), BTC_USD, DURATION, start));

        bytes32 result = module.computeQuestionId(BTC_USD, DURATION, start);
        assertEq(result, expected);
    }

    /// @notice getEventWindow returns stored config for initialized event
    function test_getEventWindow() public {
        uint256 start = block.timestamp + 1;
        bytes32 requestId = _createEvent(start);

        (bytes32 assetPair, uint256 duration, uint256 startTimestamp, uint256 endTimestamp) =
            module.getEventWindow(ConditionIdLib.from(requestId));

        assertEq(assetPair, BTC_USD);
        assertEq(duration, DURATION);
        assertEq(startTimestamp, start);
        assertEq(endTimestamp, start + DURATION);
    }

    /// @notice getEventWindow reverts for uninitialized event
    function test_revert_getEventWindow_notInitialized() public {
        bytes32 nonexistent = bytes32(uint256(keccak256("nonexistent")) & ~uint256(0xFF));
        vm.expectRevert(OracleModuleBase.RequestNotInitialized.selector);
        module.getEventWindow(ConditionIdLib.from(nonexistent));
    }

    /// @notice isPriceAvailable returns true when a valid price is written
    function test_isPriceAvailable_true() public {
        uint256 ts = 1000;
        _writePrice(ts, 50000);

        assertTrue(module.isPriceAvailable(BTC_USD, ts));
    }

    function test_isPriceAvailable_trueForNegativePrice() public {
        uint256 ts = 1000;
        _writePrice(ts, -50000);

        assertTrue(module.isPriceAvailable(BTC_USD, ts));
    }

    function test_isPriceAvailable_falseForNonCanonicalPositiveEncoding() public {
        uint256 ts = 1000;
        _writeRawPrice(ts, bytes32(uint256(int256(type(int192).max)) + 1));

        assertFalse(module.isPriceAvailable(BTC_USD, ts));
    }

    function test_isPriceAvailable_falseForNonCanonicalNegativeEncoding() public {
        uint256 ts = 1000;
        int256 belowInt192Min = int256(type(int192).min) - 1;
        _writeRawPrice(ts, bytes32(uint256(belowInt192Min)));

        assertFalse(module.isPriceAvailable(BTC_USD, ts));
    }

    /// @notice isPriceAvailable returns false when price is not written
    function test_isPriceAvailable_false() public view {
        assertFalse(module.isPriceAvailable(BTC_USD, 9999));
    }

    /// @notice isPriceAvailable returns false for unknown asset pair
    function test_isPriceAvailable_noFeedId() public view {
        // ETH_USD has no feedId configured
        assertFalse(module.isPriceAvailable("ETH_USD", 1000));
    }

    /// @notice getPrice returns the price from the DataStore
    function test_getPrice() public {
        uint256 ts = 1000;
        _writePrice(ts, 42000);

        int192 price = module.getPrice(BTC_USD, ts);
        assertEq(price, 42000);
    }

    function test_getPrice_negative() public {
        uint256 ts = 1000;
        _writePrice(ts, -42000);

        int192 price = module.getPrice(BTC_USD, ts);
        assertEq(price, -42000);
    }

    function test_getPrice_int192Bounds() public {
        uint256 minTs = 1000;
        uint256 maxTs = 1001;
        _writePrice(minTs, type(int192).min);
        _writePrice(maxTs, type(int192).max);

        assertEq(int256(module.getPrice(BTC_USD, minTs)), int256(type(int192).min));
        assertEq(int256(module.getPrice(BTC_USD, maxTs)), int256(type(int192).max));
    }

    function test_revert_getPrice_nonCanonicalPositiveEncoding() public {
        uint256 ts = 1000;
        _writeRawPrice(ts, bytes32(uint256(int256(type(int192).max)) + 1));

        vm.expectRevert(ChainlinkReporterModule.InvalidPriceEncoding.selector);
        module.getPrice(BTC_USD, ts);
    }

    function test_revert_getPrice_nonCanonicalNegativeEncoding() public {
        uint256 ts = 1000;
        int256 belowInt192Min = int256(type(int192).min) - 1;
        _writeRawPrice(ts, bytes32(uint256(belowInt192Min)));

        vm.expectRevert(ChainlinkReporterModule.InvalidPriceEncoding.selector);
        module.getPrice(BTC_USD, ts);
    }

    /// @notice getPrice reverts when feedId is not set
    function test_revert_getPrice_feedIdNotSet() public {
        vm.expectRevert(ChainlinkReporterModule.FeedIdNotSet.selector);
        module.getPrice("ETH_USD", 1000);
    }
}

/*--------------------------------------------------------------
                        ADMIN
--------------------------------------------------------------*/

contract ChainlinkReporterModuleTest_admin is ChainlinkReporterModuleTest {
    /// @notice Admin can pause the module
    function test_pause() public {
        vm.expectEmit(true, true, true, true, address(module));
        emit Pausable.GlobalPauseSet(true);

        vm.prank(owner);
        module.pause();

        assertTrue(module.globalPaused());
    }

    /// @notice Admin can unpause the module
    function test_unpause() public {
        vm.prank(owner);
        module.pause();
        assertTrue(module.globalPaused());

        vm.expectEmit(true, true, true, true, address(module));
        emit Pausable.GlobalPauseSet(false);

        vm.prank(owner);
        module.unpause();

        assertFalse(module.globalPaused());
    }

    /// @notice Admin can set the price source
    function test_setPriceSource() public {
        address newSource = makeAddr("newPriceSource");

        vm.expectEmit(true, true, true, true, address(module));
        emit ChainlinkReporterModule.PriceSourceUpdated(priceSource, newSource);

        vm.prank(owner);
        module.setPriceSource(newSource);

        assertEq(module.priceSource(), newSource);
    }

    /// @notice Admin can set a feed ID
    function test_setFeedId() public {
        bytes32 ethUsd = "ETH_USD";
        bytes32 ethFeed = bytes32(uint256(2));

        vm.expectEmit(true, true, true, true, address(module));
        emit ChainlinkReporterModule.FeedIdUpdated(ethUsd, ethFeed);

        vm.prank(owner);
        module.setFeedId(ethUsd, ethFeed);

        assertEq(module.feedIds(ethUsd), ethFeed);
    }

    /// @notice Non-admin cannot pause
    function test_revert_pause_notAdmin() public {
        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        module.pause();
    }

    /// @notice Non-admin cannot unpause
    function test_revert_unpause_notAdmin() public {
        vm.prank(owner);
        module.pause();

        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        module.unpause();
    }

    /// @notice Non-admin cannot set price source
    function test_revert_setPriceSource_notAdmin() public {
        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        module.setPriceSource(makeAddr("newSource"));
    }

    /// @notice Non-admin cannot set feed ID
    function test_revert_setFeedId_notAdmin() public {
        vm.prank(reporter1);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        module.setFeedId("ETH_USD", bytes32(uint256(2)));
    }
}

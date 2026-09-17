// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OracleModuleBase } from "@polymarket-v2/src/oracle/abstract/OracleModuleBase.sol";
import { Pausable } from "@polymarket-v2/src/oracle/mixins/Pausable.sol";
import { IOracleAggregator } from "@polymarket-v2/src/oracle/interfaces/IOracleAggregator.sol";
import { IReporterModule } from "@polymarket-v2/src/oracle/interfaces/IReporterModule.sol";
import { ConditionId, ConditionIdLib, EventId } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title IDataStore
/// @notice Interface for reading Chainlink Data Streams price data.
interface IDataStore {
    /// @notice Check if a slot has been written by a writer.
    /// @param _writer The writer address.
    /// @param _key The storage key.
    /// @return True if the slot has been written.
    function isWritten(address _writer, bytes32 _key) external view returns (bool);

    /// @notice Read the value at a key written by a writer.
    /// @param _writer The writer address.
    /// @param _key The storage key.
    /// @return The stored value.
    function read(address _writer, bytes32 _key) external view returns (bytes32);
}

/// @title ChainlinkReporterModule
/// @author Polymarket
/// @notice Singleton reporter module for Chainlink candle-based resolution
/// @dev This module is intended only for binary directional markets. It is not used for
/// incremental neg-risk markets, which resolve individual subconditions.
/// @dev Module init data per event: abi.encode(bytes32 assetPair, uint256 duration, uint256
/// startTimestamp)
contract ChainlinkReporterModule is OracleModuleBase, Pausable, IReporterModule {
    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @dev Identifier prefix used when computing question IDs for Chainlink candle-based events
    bytes32 public constant CHAINLINK_CANDLE_IDENTIFIER = "CHAINLINK_CANDLE";

    /// @dev Denominator for payout values. A payout of RESULT_DENOMINATOR represents a full win
    /// (100%).
    uint256 public constant RESULT_DENOMINATOR = 1_000_000;

    /*--------------------------------------------------------------
                                 ERRORS
    --------------------------------------------------------------*/

    /// @notice Thrown when no feed ID is configured for the asset pair.
    error FeedIdNotSet();

    /// @notice Thrown when a stored price is not a canonical sign-extended int192 value.
    error InvalidPriceEncoding();

    /// @notice Thrown when report() is called with a subcondition ID instead of the event ID.
    /// @dev This module only supports binary directional markets; incremental neg-risk subconditions
    /// are not a valid input to report().
    error InvalidRequestId();

    /// @notice Thrown when initialization is attempted for a non-binary event.
    /// @dev report() always returns a one-element YES/NO result, so events with arity != 0
    /// (e.g. neg-risk) are not supported.
    error NotBinaryEvent();

    /// @notice Thrown when the candle window has already closed at init time.
    /// @dev Reverts when startTimestamp + duration <= block.timestamp, which would resolve
    /// the market against a candle that closed before the request was even configured.
    error WindowAlreadyEnded();

    /// @notice Thrown when initialization is attempted with a zero candle duration.
    /// @dev Reverts when duration == 0, which would make the candle start and end reads the
    /// same DataStore observation instead of a directional window.
    error ZeroDuration();

    /*--------------------------------------------------------------
                                 EVENTS
    --------------------------------------------------------------*/

    /// @notice Emitted when a candle event is reported and resolved.
    /// @param requestId The request/event identifier
    /// @param questionId The deterministic question identifier
    /// @param startPrice The price at the candle start
    /// @param endPrice The price at the candle end
    /// @param payout The computed payout value
    event RequestReported(
        EventId indexed requestId, bytes32 indexed questionId, int192 startPrice, int192 endPrice, uint256 payout
    );
    /// @notice Emitted when a feed ID is set for an asset pair.
    /// @param assetPair The asset pair identifier
    /// @param feedId The Chainlink Data Streams feed ID
    event FeedIdUpdated(bytes32 indexed assetPair, bytes32 feedId);
    /// @notice Emitted when the price source address is updated.
    /// @param oldSource The previous price source address
    /// @param newSource The new price source address
    event PriceSourceUpdated(address indexed oldSource, address indexed newSource);

    /*--------------------------------------------------------------
                                STRUCTS
    --------------------------------------------------------------*/

    /// @notice Configuration for a Chainlink candle-based event
    struct EventConfig {
        /// @dev The asset pair identifier (e.g. keccak256("BTC/USD"))
        bytes32 assetPair;
        /// @dev Duration of the candle window in seconds
        uint256 duration;
        /// @dev Unix timestamp marking the start of the candle window
        uint256 startTimestamp;
    }

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The DataStore contract used to read Chainlink Data Streams price data
    IDataStore public immutable DATA_STORE;

    /// @notice The authorized price source address that writes prices to the DataStore
    address public priceSource;

    /// @notice Chainlink Data Streams feed IDs for each asset pair
    mapping(bytes32 => bytes32) public feedIds;

    /// @notice Event config per event ID
    mapping(EventId => EventConfig) public eventConfigs;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Sets the immutable DataStore reference.
    /// @param _dataStore The DataStore contract for reading price data.
    constructor(address _dataStore) {
        DATA_STORE = IDataStore(_dataStore);
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied Chainlink reporter module.
    /// @param _owner The contract owner (can upgrade).
    /// @param _admin The initial admin address.
    /// @param _aggregator The oracle aggregator address.
    /// @param _priceSource The authorized writer address in the DataStore.
    function initialize(address _owner, address _admin, address _aggregator, address _priceSource)
        external
        initializer
    {
        _initializeOwner(_owner);
        _grantRoles(_admin, ADMIN_ROLE);
        aggregator = _aggregator;
        priceSource = _priceSource;
    }

    /*--------------------------------------------------------------
                     IREPORTERMODULE IMPLEMENTATION
    --------------------------------------------------------------*/

    /// @inheritdoc IReporterModule
    function initializeReporterModule(EventId eventId, bytes calldata data)
        external
        override
        onlyAggregator
        initOnce(eventId.asCondition())
    {
        require(eventId.arity() == 0, NotBinaryEvent());

        (bytes32 assetPair, uint256 duration, uint256 startTimestamp) = abi.decode(data, (bytes32, uint256, uint256));
        require(duration > 0, ZeroDuration());
        require(startTimestamp + duration > block.timestamp, WindowAlreadyEnded());

        eventConfigs[eventId] =
            EventConfig({ assetPair: assetPair, duration: duration, startTimestamp: startTimestamp });

        emit RequestInitialized(eventId.asCondition());
    }

    /// @inheritdoc IReporterModule
    /// @dev Chainlink reporters resolve from deterministic on-chain price data and have no rules
    ///      concept; rule updates are recorded by the aggregator's `MarketDataRegistry`. This hook
    ///      is a no-op gated to the aggregator.
    function updateRules(
        bytes32,
        /*requestId*/
        bytes calldata /*updatedRules*/
    )
        external
        override
        onlyAggregator
    { }

    /*--------------------------------------------------------------
                            REPORT FUNCTION
    --------------------------------------------------------------*/

    /// @notice Resolve and report payouts using Data Streams prices from datastore
    /// @dev Each reporter module can only vote once per request. Since this module reports a
    ///      deterministic result from on-chain price data, a single report is sufficient.
    ///      Price-to-payout conversion logic:
    ///      1. Reads start/end prices from the DataStore.
    ///      2. If endPrice >= startPrice, payout = RESULT_DENOMINATOR.
    ///      3. Otherwise, payout = 0.
    /// @param _requestId Request ID (event ID for binary markets, raw bytes32)
    function report(bytes32 _requestId) external whenUnpaused {
        ConditionId requestId = ConditionIdLib.from(_requestId);
        EventId eventId = requestId.eventId();
        require(requestInitialized[eventId.asCondition()], RequestNotInitialized());
        // This module only supports binary directional markets — the input must be an EventId
        // (i.e. bit-equivalent to its conditionId form), not a neg-risk subcondition.
        require(eventId.asCondition() == requestId, InvalidRequestId());

        (bytes32 assetPair, uint256 duration, uint256 startTimestamp, uint256 endTimestamp) = _getEventWindow(eventId);

        bytes32 feedId = feedIds[assetPair];
        require(feedId != bytes32(0), FeedIdNotSet());

        /// @dev critical: if DataStore slot has not been written, this will revert from the
        ///      DataStore contract with a KeyNotWritten error. We do not check timestamp here.
        int192 startPrice = _getPrice(feedId, startTimestamp);
        int192 endPrice = _getPrice(feedId, endTimestamp);

        uint256 payout = endPrice >= startPrice ? RESULT_DENOMINATOR : 0;

        uint256[] memory result = new uint256[](1);
        result[0] = payout;

        emit RequestReported(
            eventId, computeQuestionId(assetPair, duration, startTimestamp), startPrice, endPrice, payout
        );

        IOracleAggregator(aggregator).reportResult(_requestId, result);
    }

    /*--------------------------------------------------------------
                                 VIEWS
    --------------------------------------------------------------*/

    /// @notice Computes a deterministic question ID for a candle event.
    /// @dev keccak256(abi.encode("CHAINLINK_CANDLE", assetPair, duration, startTimestamp))
    /// @param _assetPair The asset pair identifier
    /// @param _duration The candle duration in seconds
    /// @param _startTimestamp The candle start timestamp
    /// @return The computed question ID
    function computeQuestionId(bytes32 _assetPair, uint256 _duration, uint256 _startTimestamp)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(CHAINLINK_CANDLE_IDENTIFIER, _assetPair, _duration, _startTimestamp));
    }

    /// @notice Get the candle window parameters for an event
    /// @dev Resolves conditionId to eventId internally, then returns the stored config
    /// @param _eventId The event ID or condition ID to look up
    /// @return assetPair The asset pair identifier
    /// @return duration The candle duration in seconds
    /// @return startTimestamp The candle start timestamp
    /// @return endTimestamp The candle end timestamp (startTimestamp + duration)
    function getEventWindow(ConditionId _eventId)
        external
        view
        returns (bytes32 assetPair, uint256 duration, uint256 startTimestamp, uint256 endTimestamp)
    {
        EventId eventId = _eventId.eventId();
        require(requestInitialized[eventId.asCondition()], RequestNotInitialized());
        return _getEventWindow(eventId);
    }

    /// @notice Check if a valid price exists in the DataStore.
    /// @param _assetPair The asset pair identifier
    /// @param _timestamp The timestamp to check
    /// @return True if the price slot has been written and contains a canonical int192 value
    function isPriceAvailable(bytes32 _assetPair, uint256 _timestamp) external view returns (bool) {
        bytes32 feedId = feedIds[_assetPair];
        if (feedId == bytes32(0)) return false;
        bytes32 key = keccak256(abi.encode(feedId, _timestamp));
        if (!DATA_STORE.isWritten(priceSource, key)) return false;

        (bool isValid,) = _tryDecodePrice(DATA_STORE.read(priceSource, key));
        return isValid;
    }

    /// @notice Get the price from the DataStore for a given asset pair and timestamp
    /// @dev Reverts with FeedIdNotSet if no feed ID is configured for the asset pair
    /// @param _assetPair The asset pair identifier
    /// @param _timestamp The timestamp to read the price for
    /// @return The price as a signed int192
    function getPrice(bytes32 _assetPair, uint256 _timestamp) external view returns (int192) {
        bytes32 feedId = feedIds[_assetPair];
        if (feedId == bytes32(0)) revert FeedIdNotSet();
        return _getPrice(feedId, _timestamp);
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @notice Retrieves the event window configuration from storage
    /// @dev endTimestamp is computed as startTimestamp + duration
    /// @param _eventId The event ID to look up
    /// @return assetPair The asset pair identifier
    /// @return duration The candle duration in seconds
    /// @return startTimestamp The candle start timestamp
    /// @return endTimestamp The computed candle end timestamp
    function _getEventWindow(EventId _eventId)
        internal
        view
        returns (bytes32 assetPair, uint256 duration, uint256 startTimestamp, uint256 endTimestamp)
    {
        EventConfig storage cfg = eventConfigs[_eventId];

        duration = cfg.duration;
        assetPair = cfg.assetPair;
        startTimestamp = cfg.startTimestamp;
        endTimestamp = startTimestamp + duration;
    }

    /// @notice Reads a price from the DataStore for a given feed ID and timestamp
    /// @dev The DataStore key is keccak256(abi.encode(feedId, timestamp)). Reverts via
    ///      the DataStore if the slot has not been written.
    /// @param _feedId The Chainlink Data Streams feed ID
    /// @param _timestamp The timestamp to read
    /// @return price The price as a signed int192
    function _getPrice(bytes32 _feedId, uint256 _timestamp) internal view returns (int192 price) {
        bytes32 key = keccak256(abi.encode(_feedId, _timestamp));
        /// @dev DataStore is expected to validate that the slot has been written.
        bytes32 rawPrice = DATA_STORE.read(priceSource, key);

        /// @dev The writer stores int192 prices as bytes32(uint256(int256(price))), so signed
        ///      values must first be recovered from the full sign-extended 256-bit word.
        (bool isValid, int192 decodedPrice) = _tryDecodePrice(rawPrice);
        if (!isValid) revert InvalidPriceEncoding();

        price = decodedPrice;
    }

    /// @notice Attempts to decode a canonical sign-extended int192 value.
    /// @param _rawPrice The full DataStore word to decode
    /// @return isValid Whether the word is a canonical int192 encoding
    /// @return price The decoded price, or zero when the encoding is invalid
    function _tryDecodePrice(bytes32 _rawPrice) internal pure returns (bool isValid, int192 price) {
        int256 decodedPrice = int256(uint256(_rawPrice));
        if (decodedPrice < int256(type(int192).min) || decodedPrice > int256(type(int192).max)) return (false, 0);

        return (true, int192(decodedPrice));
    }

    /*--------------------------------------------------------------
                               ONLY OWNER
    --------------------------------------------------------------*/

    /// @notice Pause the module, preventing new reports
    /// @dev Only callable by admin
    function pause() external onlyAdmin {
        _pause();
    }

    /// @notice Unpause the module, allowing reports to resume
    /// @dev Only callable by admin
    function unpause() external onlyAdmin {
        _unpause();
    }

    /// @notice Update the authorized price source address
    /// @dev Only callable by admin. Emits PriceSourceUpdated.
    /// @param _priceSource The new price source address
    function setPriceSource(address _priceSource) external onlyAdmin {
        address oldSource = priceSource;
        priceSource = _priceSource;
        emit PriceSourceUpdated(oldSource, _priceSource);
    }

    /// @notice Set or update the Chainlink Data Streams feed ID for an asset pair
    /// @dev Only callable by admin. Emits FeedIdUpdated.
    /// @param _assetPair The asset pair identifier
    /// @param _feedId The Chainlink Data Streams feed ID
    function setFeedId(bytes32 _assetPair, bytes32 _feedId) external onlyAdmin {
        feedIds[_assetPair] = _feedId;
        emit FeedIdUpdated(_assetPair, _feedId);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { EnumerableSetLib } from "@solady/src/utils/EnumerableSetLib.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";
import { Auth } from "./mixins/Auth.sol";
import { Pausable } from "./mixins/Pausable.sol";
import { MarketDataRegistry } from "./mixins/MarketDataRegistry.sol";

import { IReporterModule } from "./interfaces/IReporterModule.sol";
import { IDisputerModule } from "./interfaces/IDisputerModule.sol";
import { IArbitratorModule } from "./interfaces/IArbitratorModule.sol";
import { IBinaryReporter } from "./interfaces/IBinaryReporter.sol";

import { ConditionId, ConditionIdLib, EventId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { OptimisticOraclePayoutLib } from "./libraries/OptimisticOraclePayoutLib.sol";

import { OracleAggregatorErrors } from "./abstract/OracleAggregatorErrors.sol";
import { OracleAggregatorEvents } from "./abstract/OracleAggregatorEvents.sol";

/// @title OracleAggregator
/// @author Polymarket
/// @notice Singleton oracle with modular reporter/disputer/arbitrator architecture
/// @dev As used in this contract, _requestId is synonymous with _conditionId for
///      binary and incremental negrisk markets.
///      For atomic negrisk markets, _requestId is the eventId.
contract OracleAggregator is
    UUPSUpgradeable,
    Initializable,
    Auth,
    Pausable,
    MarketDataRegistry,
    OracleAggregatorErrors,
    OracleAggregatorEvents
{
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /*--------------------------------------------------------------
                                 ENUMS
    --------------------------------------------------------------*/

    /// @notice Resolution status in the resolution lifecycle.
    /// @dev `None` means no lifecycle state has been persisted. It is interpreted as `Active`
    ///      only after the request has been proven to exist and its request ID has been validated.
    enum ResolutionStatus {
        None, // No persisted lifecycle state
        Active, // Accepting reports and disputes
        ArbitrationRequested, // Dispute threshold reached, arbitration triggered
        Resolved // Final outcome reported to target
    }

    /// @notice Market type for a request.
    /// @dev Incremental Negrisk markets have conditions that act as separate subconditions,
    ///      and can resolve independently. Atomic Negrisk markets have a single request that
    ///      resolves all subconditions at once.
    ///      Example of incremental negrisk: the 2024 US presidential election market, where
    ///      several candidates "early-resolve" to NO when they do not win the primary.
    ///      Example of atomic negrisk: a sports game where the conditions refer to Team A winning,
    ///      Team B winning, and a draw -- the outcomes of all three conditions are known at once.
    enum MarketType {
        BINARY,
        INCREMENTAL_NEGRISK,
        ATOMIC_NEGRISK
    }

    /*--------------------------------------------------------------
                                STRUCTS
    --------------------------------------------------------------*/

    /// @notice Configuration for a module (reporter or disputer) in a request.
    struct ModuleConfig {
        /// @dev Module address.
        address module;
        /// @dev Module initialization payload.
        bytes initData;
    }

    /// @notice Parameters for initializing a request.
    struct InitParams {
        /// @dev Encoded event ID per the Ids.sol ID scheme.
        EventId eventId;
        /// @dev Explicit request shape.
        MarketType marketType;
        /// @dev Target contract that will receive final reports.
        address targetContract;
        /// @dev Expected result array length per condition report.
        ///      For binary markets, this is 1.
        ///      For incremental negrisk markets, this is 1.
        ///      For atomic negrisk markets, this is 1: the winning condition index.
        uint16 resultLength;
        /// @dev Reporter modules that can submit proposals.
        ModuleConfig[] reporterModules;
        /// @dev Votes required to propose an outcome; each reporter module casts at most one vote,
        ///      so this many distinct modules must agree (see `initializeRequest`).
        uint16 reporterThreshold;
        /// @dev Disputer modules that can challenge proposals.
        ModuleConfig[] disputerModules;
        /// @dev Disputes required to request arbitration.
        uint16 disputerThreshold;
        /// @dev Arbitrator module for dispute escalation.
        address arbitratorModule;
        /// @dev Optional arbitrator module initialization payload.
        bytes arbitratorInitData;
        /// @dev Seconds to wait for disputes after proposal. Must not exceed `MAX_LIVENESS_WINDOW`.
        uint32 livenessWindow;
        /// @dev Address allowed to call `finalize`. Zero means permissionless finalize.
        address finalizer;
    }

    /// @notice Shared config for a request.
    /// @dev Packed into 3 storage slots:
    ///      Slot 0 (31 bytes): targetContract(20) | marketType(1) | resultLength(2) |
    ///                         livenessWindow(4) | reporterThreshold(2) | disputerThreshold(2)
    ///      Slot 1 (20 bytes): arbitratorModule(20)
    ///      Slot 2 (20 bytes): finalizer(20)
    struct RequestConfig {
        /// @dev Target reporter contract.
        address targetContract;
        /// @dev Explicit request shape.
        MarketType marketType;
        /// @dev Number of result elements expected per report.
        uint16 resultLength;
        /// @dev Seconds to wait after proposal before finalizing. Never exceeds `MAX_LIVENESS_WINDOW`.
        uint32 livenessWindow;
        /// @dev Votes required for a proposal to trigger.
        uint16 reporterThreshold;
        /// @dev Disputes required to trigger arbitration.
        uint16 disputerThreshold;
        /// @dev Module invoked when arbitration is needed.
        address arbitratorModule;
        /// @dev Address allowed to call `finalize`. Zero means permissionless finalize.
        address finalizer;
    }

    /// @notice Resolution state for the minimal unit of resolution.
    /// @dev Per condition for binary/incremental negrisk, per event
    ///      for atomic negrisk.
    struct ResolutionState {
        /// @dev Current resolution status.
        ResolutionStatus status;
        /// @dev Disputes received for the proposed outcome.
        uint16 disputeCount;
        /// @dev Timestamp when the dispute window closes.
        uint40 disputeWindowEnd;
        /// @dev Hash of the proposed result array.
        bytes32 proposedResultHash;
    }

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice Position manager whose module registry defines valid request targets.
    PositionManager public immutable POSITION_MANAGER;

    /// @notice Request configurations.
    /// @dev Typed `EventId` key: writes structurally restricted to canonical event IDs.
    mapping(EventId eventId => RequestConfig config) public requestConfigs;

    /// @notice Resolution state keyed by minimum resolution unit id.
    /// @dev This mapping is sparse: a valid configured request with no persisted lifecycle state
    ///      returns `ResolutionStatus.None` from the generated getter. Use `getRequestState` to
    ///      obtain the effective status, which derives `Active` for such requests.
    ///      For binary and incremental negrisk markets, the minimum resolution unit is a condition.
    ///      For atomic negrisk markets, the minimum resolution unit is the full request — looked up
    ///      at `eventId.asCondition()`.
    mapping(bytes32 requestId => ResolutionState state) public resolutionStates;

    /// @notice Registered reporter modules per event, tracked as an enumerable set so the
    ///         aggregator can both check membership and iterate all reporters tied to a request.
    /// @dev Replaces the previous `mapping(EventId => mapping(address => bool))`. External
    ///      callers should use `isReporterModule(EventId, address)` and `getReporterModules(EventId)`
    ///      below; this storage is private because Solidity cannot auto-generate a getter for a
    ///      mapping into a Solady `EnumerableSetLib.AddressSet`.
    mapping(EventId eventId => EnumerableSetLib.AddressSet modules) private _reporterModules;

    /// @notice Registered disputer modules per event, tracked as an enumerable set.
    /// @dev See `_reporterModules` for the rationale. Use `isDisputerModule(EventId, address)`
    ///      and `getDisputerModules(EventId)` for external reads.
    mapping(EventId eventId => EnumerableSetLib.AddressSet modules) private _disputerModules;

    /// @notice Vote counts per result.
    /// @dev voteKey = keccak256(abi.encode(conditionId, resultHash))
    mapping(bytes32 voteKey => uint256 count) public voteCount;

    /// @notice Whether a reporter module has voted on a request.
    mapping(bytes32 requestId => mapping(address module => bool hasVoted)) public hasReporterVoted;

    /// @notice Per-event pause flag.
    /// @dev Independent of `globalPaused`. A paused event only blocks `finalize`; the arbitrator
    ///      and admin can still resolve via `resolveResult`, and reports/disputes continue.
    mapping(EventId eventId => bool isPaused) public marketPaused;

    /// @notice Whether a disputer module has voted on a request.
    mapping(bytes32 requestId => mapping(address module => bool hasVoted)) public hasDisputerVoted;

    /// @notice First threshold-supported result that conflicts with the proposed result.
    mapping(bytes32 requestId => bytes32 resultHash) public conflictingResultHash;

    /*--------------------------------------------------------------
                               CONSTANTS
    --------------------------------------------------------------*/

    /// @notice Maximum dispute liveness permitted for a request.
    uint32 public constant MAX_LIVENESS_WINDOW = 7 days;

    /// @dev Role flag for the rule manager. Can add/edit product specifications via the
    ///      MarketDataRegistry mixin (`setProductSpecification`). Per-request rule updates
    ///      are operator-gated via `updateRequestRules`, not part of this role.
    uint256 internal constant RULE_MANAGER_ROLE = _ROLE_2;

    /*--------------------------------------------------------------
                               MODIFIERS
    --------------------------------------------------------------*/

    /// @dev Restricts to operator or admin role holders. The operator role covers request
    ///      initialization and per-market configuration management.
    modifier onlyOperatorOrAdmin() {
        _checkRoles(OPERATOR_ROLE | ADMIN_ROLE);
        _;
    }

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploys the aggregator implementation for a position manager.
    /// @param _positionManager The position manager that owns the target module registry.
    constructor(address _positionManager) {
        POSITION_MANAGER = PositionManager(_positionManager);
        _disableInitializers();
    }

    /*--------------------------------------------------------------
                              INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the aggregator with an owner and admin.
    /// @param _owner The contract owner.
    /// @param _admin The initial admin address.
    function initialize(address _owner, address _admin) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, ADMIN_ROLE);
    }

    /// @notice Pauses the aggregator, blocking reports, disputes, and finalization.
    /// @dev Dispute windows run in wall-clock time and are not extended by a pause; a window that
    ///      elapses while paused simply lets the proposal be finalized once unpaused.
    function pauseOracle() external onlyAdmin {
        _pause();
    }

    /// @notice Unpauses the aggregator.
    function unpauseOracle() external onlyAdmin {
        _unpause();
    }

    /*--------------------------------------------------------------
                        REQUEST INITIALIZATION
    --------------------------------------------------------------*/

    /// @notice Initialize a request and register reporter/disputer modules.
    /// @dev Event ID is synonymous with Condition ID for binary markets.
    /// @dev Every request must register at least one reporter and at least one disputer module,
    ///      with both thresholds at least one and enough distinct modules to satisfy each. Votes
    ///      are tallied per module (deduped by `hasReporterVoted` / `hasDisputerVoted`), so a
    ///      result or dispute only crosses its threshold when that many distinct modules act. An
    ///      arbitrator is always required. A zero liveness window intentionally makes a proposal
    ///      finalizable in the same block and leaves no opportunity to dispute it.
    /// @param _params Request initialization parameters.
    function initializeRequest(InitParams calldata _params) external onlyOperator {
        EventId eventId = _params.eventId;
        RequestConfig storage cfg = requestConfigs[eventId];
        require(cfg.targetContract == address(0), RequestAlreadyExists());

        require(_params.resultLength == 1, InvalidResultLength());
        require(_params.targetContract != address(0), InvalidConfig());
        _validateRequestRoute(eventId, _params.marketType, _params.targetContract);
        _validateLivenessWindow(_params.livenessWindow);
        require(_params.reporterThreshold >= 1, InvalidConfig());
        require(_params.disputerThreshold >= 1, InvalidConfig());
        require(_params.arbitratorModule != address(0), InvalidConfig());

        cfg.targetContract = _params.targetContract;
        cfg.marketType = _params.marketType;
        cfg.resultLength = _params.resultLength;
        cfg.livenessWindow = _params.livenessWindow;
        cfg.reporterThreshold = _params.reporterThreshold;
        cfg.disputerThreshold = _params.disputerThreshold;
        cfg.arbitratorModule = _params.arbitratorModule;
        cfg.finalizer = _params.finalizer;

        _registerReporterModules(eventId, _params.reporterModules);
        _registerDisputerModules(eventId, _params.disputerModules);

        // Enough distinct modules to satisfy each threshold. Sets dedupe, so this also rejects
        // arrays padded with duplicates that could never meet the threshold.
        require(_reporterModules[eventId].length() >= _params.reporterThreshold, InvalidConfig());
        require(_disputerModules[eventId].length() >= _params.disputerThreshold, InvalidConfig());

        if (_params.arbitratorInitData.length > 0) {
            IArbitratorModule(_params.arbitratorModule).initializeArbitratorModule(eventId, _params.arbitratorInitData);
        }

        emit RequestInitialized(
            eventId,
            _params.targetContract,
            _params.reporterThreshold,
            _params.disputerThreshold,
            _params.resultLength,
            uint8(_params.marketType),
            _params.arbitratorModule,
            _params.livenessWindow,
            _params.finalizer
        );
    }

    /// @dev Validates the request shape and its target against the position manager registry.
    /// @param _eventId The event ID whose encoded route is validated.
    /// @param _marketType The configured request market type.
    /// @param _targetContract The target that will receive the final report.
    function _validateRequestRoute(EventId _eventId, MarketType _marketType, address _targetContract) internal view {
        uint256 arity = _eventId.arity();
        uint256 expectedModuleId;

        if (_marketType == MarketType.BINARY) {
            require(arity == 0, InvalidEventId());
            expectedModuleId = ModuleIds.BINARY;
        } else if (_marketType == MarketType.INCREMENTAL_NEGRISK || _marketType == MarketType.ATOMIC_NEGRISK) {
            require(arity >= 2, InvalidEventId());
            expectedModuleId = ModuleIds.NEGRISK;
        } else {
            revert InvalidConfig();
        }

        require(_eventId.moduleId() == expectedModuleId, InvalidEventId());
        require(POSITION_MANAGER.moduleById(expectedModuleId) == _targetContract, InvalidTargetContract());
    }

    /// @dev Rejects liveness windows that could make normal finalization impractically distant.
    /// @param _livenessWindow The proposed liveness window in seconds.
    function _validateLivenessWindow(uint32 _livenessWindow) internal pure {
        require(_livenessWindow <= MAX_LIVENESS_WINDOW, LivenessWindowTooLong());
    }

    /// @dev Registers reporter modules and calls their initializers.
    /// @dev Skips modules already registered for the event (their `initData` is ignored, since
    ///      reporter modules guard `initializeReporterModule` with `initOnce` and would revert
    ///      on a re-initialization attempt). Only emits `ReporterModuleAdded` on first add.
    /// @param _eventId The event ID to register modules for.
    /// @param _reporters Array of reporter module configurations.
    function _registerReporterModules(EventId _eventId, ModuleConfig[] calldata _reporters) internal {
        EnumerableSetLib.AddressSet storage modules = _reporterModules[_eventId];
        for (uint256 i = 0; i < _reporters.length; ++i) {
            ModuleConfig calldata config = _reporters[i];
            if (!modules.add(config.module)) continue;

            if (config.initData.length > 0) {
                IReporterModule(config.module).initializeReporterModule(_eventId, config.initData);
            }

            emit ReporterModuleAdded(_eventId, config.module);
        }
    }

    /// @dev Registers disputer modules and calls their initializers.
    /// @dev Skips modules already registered for the event; see `_registerReporterModules`.
    /// @param _eventId The event ID to register modules for.
    /// @param _disputers Array of disputer module configurations.
    function _registerDisputerModules(EventId _eventId, ModuleConfig[] calldata _disputers) internal {
        EnumerableSetLib.AddressSet storage modules = _disputerModules[_eventId];
        for (uint256 i = 0; i < _disputers.length; ++i) {
            ModuleConfig calldata config = _disputers[i];
            if (!modules.add(config.module)) continue;

            if (config.initData.length > 0) {
                IDisputerModule(config.module).initializeDisputerModule(_eventId, config.initData);
            }

            emit DisputerModuleAdded(_eventId, config.module);
        }
    }

    /*--------------------------------------------------------------
                        REQUEST UPDATE
    --------------------------------------------------------------*/

    /// @notice Update the rules for an active request and forward the update to every reporter
    ///         module registered for the event.
    /// @dev The canonical write path for per-request rules. Two-step: (1) appends the new rules
    ///      to the on-chain history via the `MarketDataRegistry` mixin's internal `_pushRule`
    ///      helper (which emits `RuleAdded`), then (2) iterates the enumerable set of reporters
    ///      and calls `IReporterModule.updateRules` on each so modules that mirror rules to
    ///      external systems (e.g. UMA's OOReporter) can pick up the change. Rejects unknown or
    ///      already-resolved requests via `_requireRuleEligible`. Disputer modules are not
    ///      notified — `IDisputerModule` does not declare `updateRules`.
    /// @param _requestId The request ID whose rules are being updated.
    /// @param _updatedRules The new rule blob (forwarded verbatim).
    function updateRequestRules(bytes32 _requestId, bytes calldata _updatedRules) external onlyOperatorOrAdmin {
        (EventId eventId,) = _getRequestConfigForRequestId(_requestId);
        _requireRuleEligible(_requestId);

        _pushRule(_requestId, _updatedRules);

        EnumerableSetLib.AddressSet storage modules = _reporterModules[eventId];
        uint256 len = modules.length();
        for (uint256 i; i < len; ++i) {
            IReporterModule(modules.at(i)).updateRules(_requestId, _updatedRules);
        }

        emit RequestRulesUpdated(_requestId, len);
    }

    /*--------------------------------------------------------------
                  UNIFIED REPORT / DISPUTE / FINALIZE
    --------------------------------------------------------------*/

    /// @notice Submit a result report from a registered reporter module.
    /// @param _requestId The request ID to report on (conditionId or eventId).
    /// @param _result The result to propose: `[yesPayout]`, or `[winnerIndex]` for atomic.
    function reportResult(bytes32 _requestId, uint256[] calldata _result) external whenUnpaused {
        (EventId eventId, RequestConfig storage cfg) = _getRequestConfigForRequestId(_requestId);
        require(_reporterModules[eventId].contains(msg.sender), NotRegisteredModule());
        require(!hasReporterVoted[_requestId][msg.sender], AlreadyVoted());

        hasReporterVoted[_requestId][msg.sender] = true;

        ResolutionState storage state = resolutionStates[_requestId];
        require(_isActiveStatus(state.status), RequestNotActive());

        _validateResult(_requestId, cfg.marketType, cfg.resultLength, _result);

        bytes32 resultHash = keccak256(abi.encode(_result));
        bytes32 proposedResultHash = state.proposedResultHash;
        if (proposedResultHash != bytes32(0)) {
            require(block.timestamp < state.disputeWindowEnd, DisputeWindowExpired());
        }

        bytes32 voteKey = keccak256(abi.encode(_requestId, resultHash));
        uint256 newCount = voteCount[voteKey] + 1;
        voteCount[voteKey] = newCount;

        emit ResultReported(_requestId, msg.sender, resultHash, newCount);

        if (newCount < cfg.reporterThreshold) return;

        if (proposedResultHash == bytes32(0)) {
            state.proposedResultHash = resultHash;
            state.disputeWindowEnd = uint40(block.timestamp + cfg.livenessWindow);

            emit OutcomeProposed(_requestId, resultHash, _result);
        } else if (resultHash != proposedResultHash) {
            conflictingResultHash[_requestId] = resultHash;

            emit ReporterConflict(_requestId, proposedResultHash, resultHash, _result);

            _triggerArbitration(_requestId, cfg, state);
        }
    }

    /// @notice Dispute the current proposal from a registered disputer.
    /// @param _requestId The request ID to dispute.
    function disputeResult(bytes32 _requestId) external whenUnpaused {
        (EventId eventId, RequestConfig storage cfg) = _getRequestConfigForRequestId(_requestId);

        ResolutionState storage state = resolutionStates[_requestId];
        require(_isActiveStatus(state.status), RequestNotActive());
        require(state.proposedResultHash != bytes32(0), NoProposalToChallenge());
        require(block.timestamp < state.disputeWindowEnd, DisputeWindowExpired());

        require(_disputerModules[eventId].contains(msg.sender), NotRegisteredModule());
        require(!hasDisputerVoted[_requestId][msg.sender], AlreadyVoted());

        hasDisputerVoted[_requestId][msg.sender] = true;

        state.disputeCount++;

        emit ResultDisputed(_requestId, msg.sender);

        if (state.disputeCount == cfg.disputerThreshold) _triggerArbitration(_requestId, cfg, state);
    }

    /// @notice Resolve a request via arbitrator or admin override.
    /// @dev Callable by the configured arbitrator or an admin at any point before resolution —
    ///      there is no requirement that arbitration was triggered first. The arbitrator has
    ///      absolute authority over its markets; operators are trusted accordingly since they
    ///      can swap the arbitrator via `setArbitratorModule`. No-ops if already resolved.
    /// @param _requestId The request ID to resolve.
    /// @param _result The final result: `[yesPayout]`, or `[winnerIndex]` for atomic.
    function resolveResult(bytes32 _requestId, uint256[] calldata _result) external whenUnpaused {
        (, RequestConfig storage cfg) = _getRequestConfigForRequestId(_requestId);

        ResolutionState storage state = resolutionStates[_requestId];
        if (state.status == ResolutionStatus.Resolved) return;

        bool isArb = msg.sender == cfg.arbitratorModule;
        bool isAdmin = hasAllRoles(msg.sender, _ROLE_0);
        require(isArb || isAdmin, NotAuthorized());

        _validateResult(_requestId, cfg.marketType, cfg.resultLength, _result);

        // Admin override during arbitration: notify the arbitrator so it can clear its local
        // `isActive` flag. Best-effort via a low-level call: a codeless opt-out address or a
        // revert from the hook (paused arbitrator, buggy implementation, etc.) must not block
        // emergency admin resolution. A codeless target returns success and no-ops; a deployed
        // revert surfaces via the event.
        if (!isArb && state.status == ResolutionStatus.ArbitrationRequested) {
            (bool ok,) =
                cfg.arbitratorModule.call(abi.encodeCall(IArbitratorModule.onArbitrationResolved, (_requestId)));
            if (!ok) emit ArbitratorHookFailed(_requestId, cfg.arbitratorModule);
        }

        bytes32 resultHash = keccak256(abi.encode(_result));
        state.proposedResultHash = resultHash;

        _finalizeConditions(_requestId, cfg, _result);

        emit RequestResolved(_requestId, resultHash, msg.sender);
    }

    /// @notice Finalize a proposed result once the dispute window expires.
    /// @dev Blocked while the event is paused at the per-event level. When a `finalizer` is
    ///      configured for the request, only that address may call this; a zero finalizer keeps
    ///      finalization permissionless. A zero liveness window sets the deadline to the proposal
    ///      timestamp, so the proposal can be finalized in the same block.
    /// @param _requestId The request ID to finalize.
    /// @param _result The proposed result array (must match the stored proposal hash).
    function finalize(bytes32 _requestId, uint256[] calldata _result) external whenUnpaused {
        (EventId eventId, RequestConfig storage cfg) = _getRequestConfigForRequestId(_requestId);

        require(!marketPaused[eventId], MarketPaused());
        require(cfg.finalizer == address(0) || msg.sender == cfg.finalizer, NotAuthorized());

        ResolutionState storage state = resolutionStates[_requestId];
        require(_isActiveStatus(state.status), RequestNotActive());
        require(state.proposedResultHash != bytes32(0), ThresholdNotMet());
        require(block.timestamp >= state.disputeWindowEnd, DisputeWindowActive());
        require(keccak256(abi.encode(_result)) == state.proposedResultHash, InvalidResultHash());

        _finalizeConditions(_requestId, cfg, _result);

        emit RequestResolved(_requestId, state.proposedResultHash, address(this));
    }

    /*--------------------------------------------------------------
                            RULE MANAGER ROLE
    --------------------------------------------------------------*/

    /// @notice Grant the rule manager role to an address.
    /// @dev Only callable by an admin. The rule manager can add/edit product specifications
    ///      (`setProductSpecification`). It cannot update request rules — `updateRequestRules`
    ///      is operator-or-admin only.
    /// @param _manager Address to receive the rule manager role.
    function addRuleManager(address _manager) external onlyAdmin {
        _grantRoles(_manager, RULE_MANAGER_ROLE);
    }

    /// @notice Revoke the rule manager role from an address.
    /// @dev Only callable by an admin.
    /// @param _manager Address to lose the rule manager role.
    function removeRuleManager(address _manager) external onlyAdmin {
        _removeRoles(_manager, RULE_MANAGER_ROLE);
    }

    /*--------------------------------------------------------------
                        OPERATOR — PAUSE CONTROL
    --------------------------------------------------------------*/

    /// @notice Pause a batch of markets, blocking `finalize` on each.
    /// @dev Independent of the global pause. While paused, only the arbitrator or an admin can
    ///      finish the market via `resolveResult`; reports and disputes are unaffected.
    /// @param _eventIds The events to pause.
    function pauseMarkets(EventId[] calldata _eventIds) external onlyOperatorOrAdmin {
        _setMarketPause(_eventIds, true);
    }

    /// @notice Unpause a batch of markets, re-enabling `finalize` on each.
    /// @param _eventIds The events to unpause.
    function unpauseMarkets(EventId[] calldata _eventIds) external onlyOperatorOrAdmin {
        _setMarketPause(_eventIds, false);
    }

    /// @dev Sets the per-event pause flag for each event after asserting it exists.
    /// @param _eventIds The events to update.
    /// @param _paused The new pause state.
    function _setMarketPause(EventId[] calldata _eventIds, bool _paused) internal {
        for (uint256 i; i < _eventIds.length; ++i) {
            EventId eventId = _eventIds[i];
            _requireRequestConfig(eventId);
            marketPaused[eventId] = _paused;
            emit MarketPauseSet(eventId, _paused);
        }
    }

    /*--------------------------------------------------------------
                      OPERATOR — CONFIG MUTATION
    --------------------------------------------------------------*/

    /// @notice Register additional reporter modules for an unresolved request's event.
    /// @dev New modules are initialized via their `initData` (existing modules cannot be
    ///      re-initialized due to their own `initOnce` guard). Prior votes are not affected.
    /// @param _requestId An unresolved request whose event will be updated.
    /// @param _modules Reporter module configurations to add.
    function addReporterModules(bytes32 _requestId, ModuleConfig[] calldata _modules) external onlyOperatorOrAdmin {
        (EventId eventId,) = _requireMutableRequestConfig(_requestId);
        _registerReporterModules(eventId, _modules);
    }

    /// @notice Deregister reporter modules from an unresolved request's event.
    /// @dev Already-counted votes from removed modules are not purged. Reverts if the removal
    ///      would leave fewer reporters than `reporterThreshold`, preserving the init invariant
    ///      that a request always has enough distinct modules to meet its threshold.
    /// @param _requestId An unresolved request whose event will be updated.
    /// @param _modules Reporter module addresses to remove.
    function removeReporterModules(bytes32 _requestId, address[] calldata _modules) external onlyOperatorOrAdmin {
        (EventId eventId, RequestConfig storage cfg) = _requireMutableRequestConfig(_requestId);
        EnumerableSetLib.AddressSet storage modules = _reporterModules[eventId];
        for (uint256 i; i < _modules.length; ++i) {
            if (modules.remove(_modules[i])) emit ReporterModuleRemoved(eventId, _modules[i]);
        }
        require(modules.length() >= cfg.reporterThreshold, InvalidConfig());
    }

    /// @notice Register additional disputer modules for an unresolved request's event.
    /// @dev New modules are initialized via their `initData` (existing modules cannot be
    ///      re-initialized due to their own `initOnce` guard). Every request is initialized with a
    ///      non-zero disputer threshold and arbitrator, and the threshold cannot change post-init.
    /// @param _requestId An unresolved request whose event will be updated.
    /// @param _modules Disputer module configurations to add.
    function addDisputerModules(bytes32 _requestId, ModuleConfig[] calldata _modules) external onlyOperatorOrAdmin {
        (EventId eventId,) = _requireMutableRequestConfig(_requestId);
        _registerDisputerModules(eventId, _modules);
    }

    /// @notice Deregister disputer modules from an unresolved request's event.
    /// @dev Reverts if the removal would leave fewer disputers than `disputerThreshold`,
    ///      preserving the init invariant that a request always has enough distinct modules to
    ///      meet its threshold.
    /// @param _requestId An unresolved request whose event will be updated.
    /// @param _modules Disputer module addresses to remove.
    function removeDisputerModules(bytes32 _requestId, address[] calldata _modules) external onlyOperatorOrAdmin {
        (EventId eventId, RequestConfig storage cfg) = _requireMutableRequestConfig(_requestId);
        EnumerableSetLib.AddressSet storage modules = _disputerModules[eventId];
        for (uint256 i; i < _modules.length; ++i) {
            if (modules.remove(_modules[i])) emit DisputerModuleRemoved(eventId, _modules[i]);
        }
        require(modules.length() >= cfg.disputerThreshold, InvalidConfig());
    }

    /// @notice Change the arbitrator module for an unresolved request's event.
    /// @dev Swapping the arbitrator while a condition is already in `ArbitrationRequested` leaves
    ///      the new module un-notified; such a condition must be finished via admin `resolveResult`.
    ///      Every request is disputable, so the arbitrator cannot be zeroed; doing so would disable
    ///      dispute escalation.
    /// @param _requestId An unresolved request whose event will be updated.
    /// @param _arbitratorModule The new arbitrator module address.
    /// @param _initData Optional initialization payload for the new arbitrator module.
    function setArbitratorModule(bytes32 _requestId, address _arbitratorModule, bytes calldata _initData)
        external
        onlyOperatorOrAdmin
    {
        (EventId eventId, RequestConfig storage cfg) = _requireMutableRequestConfig(_requestId);
        require(_arbitratorModule != address(0), InvalidConfig());
        cfg.arbitratorModule = _arbitratorModule;

        if (_initData.length > 0) {
            IArbitratorModule(_arbitratorModule).initializeArbitratorModule(eventId, _initData);
        }

        emit ArbitratorModuleSet(eventId, _arbitratorModule);
    }

    /// @notice Set or clear the finalizer for an unresolved request's event.
    /// @dev A zero finalizer makes `finalize` permissionless again.
    /// @param _requestId An unresolved request whose event will be updated.
    /// @param _finalizer The new finalizer address (zero for permissionless).
    function setFinalizer(bytes32 _requestId, address _finalizer) external onlyOperatorOrAdmin {
        (EventId eventId, RequestConfig storage cfg) = _requireMutableRequestConfig(_requestId);
        cfg.finalizer = _finalizer;
        emit FinalizerSet(eventId, _finalizer);
    }

    /// @notice Change the liveness window for an unresolved request's event.
    /// @dev Only affects proposals created after this call; an existing proposal's dispute window
    ///      end is fixed at proposal time. Setting zero makes future proposals finalizable in the
    ///      same block and leaves no opportunity to dispute them.
    /// @param _requestId An unresolved request whose event will be updated.
    /// @param _livenessWindow The new liveness window in seconds, capped at `MAX_LIVENESS_WINDOW`.
    function setLivenessWindow(bytes32 _requestId, uint32 _livenessWindow) external onlyOperatorOrAdmin {
        (EventId eventId, RequestConfig storage cfg) = _requireMutableRequestConfig(_requestId);
        _validateLivenessWindow(_livenessWindow);
        cfg.livenessWindow = _livenessWindow;
        emit LivenessWindowSet(eventId, _livenessWindow);
    }

    /*--------------------------------------------------------------
                          INTERNAL RESOLUTION LOGIC
    --------------------------------------------------------------*/

    /// @dev Moves a request into arbitration and notifies its arbitrator when configured.
    ///      A request without an arbitrator remains safely blocked for admin resolution.
    function _triggerArbitration(bytes32 _requestId, RequestConfig storage _cfg, ResolutionState storage _state)
        internal
    {
        _state.status = ResolutionStatus.ArbitrationRequested;

        emit ArbitrationTriggered(_requestId);

        address arbitratorModule = _cfg.arbitratorModule;
        if (arbitratorModule != address(0)) {
            // Low-level call so a non-responsive arbitrator — a codeless opt-out address or a
            // reverting/paused deployed module — cannot brick conflict/dispute handling. The
            // request still parks in `ArbitrationRequested` for admin `resolveResult`. A codeless
            // target returns success and no-ops; a deployed revert surfaces via the event.
            (bool ok,) = arbitratorModule.call(
                abi.encodeCall(IArbitratorModule.onArbitrationTriggered, (_requestId, _state.proposedResultHash))
            );
            if (!ok) emit ArbitratorHookFailed(_requestId, arbitratorModule);
        }
    }

    /// @dev Marks as resolved and reports the binary condition result to the target.
    ///      Atomic neg-risk stores `[winningIndex]`; other markets store `[yesPayout]`.
    /// @param _requestId The request ID being finalized.
    /// @param _cfg The request config.
    /// @param _result The final result: `[yesPayout]`, or `[winnerIndex]` for atomic.
    function _finalizeConditions(bytes32 _requestId, RequestConfig storage _cfg, uint256[] calldata _result) internal {
        resolutionStates[_requestId].status = ResolutionStatus.Resolved;

        ConditionId cid = ConditionIdLib.from(_requestId);
        uint256[] memory binaryResult = new uint256[](2);
        ConditionId reportConditionId;
        if (_cfg.marketType == MarketType.ATOMIC_NEGRISK) {
            binaryResult[0] = OptimisticOraclePayoutLib.RESULT_DENOMINATOR;
            reportConditionId = cid.eventId().computeConditionId(_result[0]);
        } else {
            uint256 value = _result[0];
            binaryResult[0] = value;
            binaryResult[1] = OptimisticOraclePayoutLib.RESULT_DENOMINATOR - value;
            reportConditionId = cid;
        }

        try IBinaryReporter(_cfg.targetContract).reportResult(reportConditionId, binaryResult) { }
        catch (bytes memory returnData) {
            if (returnData.length >= 4) {
                // A matching replay means the target was already resolved. Treat it as
                // successful so UMA/other settlement callers are not bricked by prior
                // permissionless resolution; mismatched payouts still bubble below.
                if (bytes4(returnData) == ModuleErrors.ConditionAlreadyResolved.selector) return;
            }

            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /// @dev Validates result length and sum constraints.
    /// @dev Atomic neg-risk stores `[winningIndex]` for a real condition. Incremental neg-risk
    ///      stores binary payouts and rejects fractional values. Binary markets may resolve to
    ///      fractional payouts.
    /// @param _requestId The request ID being validated.
    /// @param _marketType The request market type.
    /// @param _resultLength The configured result length for the request's event.
    /// @param _result The result array to validate.
    function _validateResult(
        bytes32 _requestId,
        MarketType _marketType,
        uint16 _resultLength,
        uint256[] calldata _result
    ) internal pure {
        require(_result.length == _resultLength, InvalidResultLength());

        uint256 value = _result[0];

        if (_marketType == MarketType.ATOMIC_NEGRISK) {
            require(value < ConditionIdLib.from(_requestId).eventId().arity(), InvalidResult());
            return;
        }

        if (_marketType == MarketType.BINARY) {
            require(value <= OptimisticOraclePayoutLib.RESULT_DENOMINATOR, InvalidResultSum());
        } else {
            require(value == 0 || value == OptimisticOraclePayoutLib.RESULT_DENOMINATOR, InvalidResult());
        }
    }

    /// @dev Returns true if the status permits active-request operations. Must only be called after
    ///      `_getRequestConfigForRequestId` has proven that the request exists and its ID is valid;
    ///      only in that context does an unpersisted `None` status mean implicitly `Active`.
    /// @param _status The resolution status to check.
    /// @return True if None or Active.
    function _isActiveStatus(ResolutionStatus _status) internal pure returns (bool) {
        return _status == ResolutionStatus.None || _status == ResolutionStatus.Active;
    }

    /// @dev Returns the config for an event, reverting if the request does not exist.
    /// @param _eventId The event ID to look up.
    /// @return cfg The request configuration.
    function _requireRequestConfig(EventId _eventId) internal view returns (RequestConfig storage cfg) {
        cfg = requestConfigs[_eventId];
        require(cfg.targetContract != address(0), RequestNotFound());
    }

    /// @dev Returns the shared event config only when the supplied request is unresolved.
    ///      The existence check intentionally precedes the lifecycle check so an unknown request
    ///      remains distinguishable from a terminal request.
    /// @param _requestId The request whose state gates the mutation.
    /// @return eventId The event whose shared configuration will be mutated.
    /// @return cfg The mutable request configuration.
    function _requireMutableRequestConfig(bytes32 _requestId)
        internal
        view
        returns (EventId eventId, RequestConfig storage cfg)
    {
        (eventId, cfg) = _getRequestConfigForRequestId(_requestId);
        require(resolutionStates[_requestId].status != ResolutionStatus.Resolved, RequestAlreadyResolved());
    }

    /// @dev Resolves the event ID and config for a given request ID. Also enforces conditionId canonicality.
    /// @param _requestId The raw request ID.
    /// @return eventId The parent event ID.
    /// @return cfg The request configuration.
    function _getRequestConfigForRequestId(bytes32 _requestId)
        internal
        view
        returns (EventId eventId, RequestConfig storage cfg)
    {
        ConditionId requestIdAsCondition = ConditionIdLib.from(_requestId);
        eventId = requestIdAsCondition.eventId();
        cfg = requestConfigs[eventId];
        require(cfg.targetContract != address(0), RequestNotFound());

        // Binary and atomic markets resolve at the event level, so only the eventId is valid
        if (cfg.marketType != MarketType.INCREMENTAL_NEGRISK) {
            require(requestIdAsCondition.isValidEventId(), InvalidRequestId());
            return (eventId, cfg);
        }

        // Incremental neg-risk resolves per subcondition, so any in-range conditionId is valid
        uint256 conditionIndex = requestIdAsCondition.conditionIndex();
        uint256 conditionCount = eventId.arity();
        require(conditionIndex < conditionCount, InvalidConditionIndex());
    }

    /*--------------------------------------------------------------
                                 VIEWS
    --------------------------------------------------------------*/

    /// @notice Returns the current effective resolution state for a request.
    /// @dev Derives `Active` for a valid configured request whose sparse `resolutionStates` entry
    ///      remains `None`. Invalid or unconfigured request IDs remain `None`.
    /// @param _requestId The request ID.
    /// @return status The resolution status.
    /// @return proposedResultHash Hash of the proposed result.
    /// @return disputeWindowEnd Dispute window end timestamp.
    /// @return disputeCount Number of disputes received.
    function getRequestState(bytes32 _requestId)
        external
        view
        returns (ResolutionStatus status, bytes32 proposedResultHash, uint256 disputeWindowEnd, uint256 disputeCount)
    {
        ConditionId cid = ConditionIdLib.from(_requestId);
        ResolutionState storage state = resolutionStates[_requestId];
        proposedResultHash = state.proposedResultHash;
        status = state.status;
        disputeWindowEnd = state.disputeWindowEnd;
        disputeCount = state.disputeCount;

        // If in persisted state, return it
        if (status != ResolutionStatus.None) return (status, proposedResultHash, disputeWindowEnd, disputeCount);

        EventId eventId = cid.eventId();
        RequestConfig storage cfg = requestConfigs[eventId];
        if (cfg.targetContract == address(0)) {
            return (ResolutionStatus.None, proposedResultHash, disputeWindowEnd, disputeCount);
        }

        bool isEventRequest = cid.isValidEventId();

        // Binary and atomic markets are active only at the eventId
        if (cfg.marketType != MarketType.INCREMENTAL_NEGRISK) {
            if (isEventRequest) status = ResolutionStatus.Active;
            return (status, proposedResultHash, disputeWindowEnd, disputeCount);
        }

        // Incremental neg-risk is active for any in-range subcondition
        uint256 conditionIndex = cid.conditionIndex();
        uint256 conditionCount = eventId.arity();
        if (conditionIndex < conditionCount) status = ResolutionStatus.Active;

        return (status, proposedResultHash, disputeWindowEnd, disputeCount);
    }

    /// @notice Returns the vote count for a specific result on a request.
    /// @param _requestId The request ID.
    /// @param _result The result array to query votes for.
    /// @return count The number of votes.
    function getReportVotes(bytes32 _requestId, uint256[] calldata _result) external view returns (uint256 count) {
        ConditionIdLib.from(_requestId);
        bytes32 resultHash = keccak256(abi.encode(_result));
        bytes32 voteKey = keccak256(abi.encode(_requestId, resultHash));
        return voteCount[voteKey];
    }

    /// @notice Returns the expected result length for a request.
    /// @param _requestId The request ID.
    /// @return The expected result array length.
    function getResultLength(bytes32 _requestId) external view returns (uint256) {
        (, RequestConfig storage cfg) = _getRequestConfigForRequestId(_requestId);
        return cfg.resultLength;
    }

    /// @notice Returns the authoritative market type and result length for a request.
    /// @param _requestId The request ID.
    /// @return marketType The configured market type.
    /// @return resultLength The expected number of result elements.
    function getRequestShape(bytes32 _requestId) external view returns (uint8 marketType, uint16 resultLength) {
        (, RequestConfig storage cfg) = _getRequestConfigForRequestId(_requestId);
        return (uint8(cfg.marketType), cfg.resultLength);
    }

    /// @notice Returns whether a module is a registered reporter for an event.
    /// @dev Replaces the previous auto-generated getter; same external signature.
    /// @param _eventId The event ID.
    /// @param _module The module address.
    /// @return True if the module is registered as a reporter for the event.
    function isReporterModule(EventId _eventId, address _module) public view returns (bool) {
        return _reporterModules[_eventId].contains(_module);
    }

    /// @notice Returns whether a module is a registered disputer for an event.
    /// @dev Replaces the previous auto-generated getter; same external signature.
    /// @param _eventId The event ID.
    /// @param _module The module address.
    /// @return True if the module is registered as a disputer for the event.
    function isDisputerModule(EventId _eventId, address _module) public view returns (bool) {
        return _disputerModules[_eventId].contains(_module);
    }

    /// @notice Returns the full list of registered reporter modules for an event.
    /// @dev Order is the Solady `EnumerableSetLib.AddressSet` enumeration order (insertion order
    ///      with swap-and-pop on removal). Empty when no reporters are registered.
    /// @param _eventId The event ID.
    /// @return The list of reporter module addresses.
    function getReporterModules(EventId _eventId) external view returns (address[] memory) {
        return _reporterModules[_eventId].values();
    }

    /// @notice Returns the full list of registered disputer modules for an event.
    /// @dev Order matches `getReporterModules` semantics.
    /// @param _eventId The event ID.
    /// @return The list of disputer module addresses.
    function getDisputerModules(EventId _eventId) external view returns (address[] memory) {
        return _disputerModules[_eventId].values();
    }

    /*--------------------------------------------------------------
                      MARKET DATA REGISTRY HOOKS
    --------------------------------------------------------------*/

    /// @dev Restricts product-spec writes to rule manager or admin role holders. Rule writes
    ///      do not pass through this hook — they flow through the operator-or-admin gated
    ///      `updateRequestRules`, which calls the mixin's internal `_pushRule` directly.
    function _authorizeMarketDataWrite() internal view override {
        _checkRoles(RULE_MANAGER_ROLE | ADMIN_ROLE);
    }

    /// @dev Allows rules only for requests that are not yet resolved. The caller must first use
    ///      `_getRequestConfigForRequestId` to prove the request exists and its ID is valid.
    function _requireRuleEligible(bytes32 _requestId) internal view override {
        require(resolutionStates[_requestId].status != ResolutionStatus.Resolved, RequestAlreadyResolved());
    }

    /*--------------------------------------------------------------
                           UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the owner and preserves the position manager dependency.
    /// @param newImplementation The proposed implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        OracleAggregator newImpl = OracleAggregator(newImplementation);
        require(address(newImpl.POSITION_MANAGER()) == address(POSITION_MANAGER), IncompatibleImplementation());
    }
}

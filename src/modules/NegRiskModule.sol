// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { ConditionId, EventId, EventIdLib, PositionId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

import { BaseModule } from "./abstract/BaseModule.sol";
import { NegRiskMigrationMixin } from "./migration/NegRiskMigrationMixin.sol";

/// @title NegRiskModuleEvents
/// @notice Events emitted by NegRiskModule.
abstract contract NegRiskModuleEvents {
    /// @notice Emitted when collateral is split into YES positions across every condition in an
    ///         event.
    /// @param initiator The address that initiated the horizontal split.
    /// @param eventId The neg-risk event that was split.
    /// @param recipient Recipient of the minted YES positions.
    /// @param amount Amount of collateral split.
    event HorizontalSplit(
        address indexed initiator, EventId indexed eventId, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when YES positions across every condition in an event are merged back
    ///         into collateral.
    /// @param initiator The address that initiated the horizontal merge.
    /// @param eventId The neg-risk event that was merged.
    /// @param recipient Recipient of the minted collateral.
    /// @param amount Amount per condition merged.
    event HorizontalMerge(
        address indexed initiator, EventId indexed eventId, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when a NO position is converted into YES positions for every other
    ///         condition in the event.
    /// @param initiator The address that initiated the conversion.
    /// @param eventId The neg-risk event.
    /// @param recipient Recipient of the minted YES positions.
    /// @param conditionIndex Index of the condition whose NO was burned.
    /// @param amount Amount converted.
    event PositionConverted(
        address indexed initiator,
        EventId indexed eventId,
        address indexed recipient,
        uint256 conditionIndex,
        uint256 amount
    );

    /// @notice Emitted when a YES result makes every unresolved sibling condition derivable as NO.
    /// @param eventId The neg-risk event whose remaining unresolved real conditions derive to NO.
    event RemainingConditionsDerivableAsNo(EventId indexed eventId);

    /// @notice Emitted when every real condition has resolved NO, making the synthetic Other
    ///         condition derivable as YES.
    /// @param eventId The neg-risk event whose synthetic Other condition derives to YES.
    /// @param conditionId The synthetic Other condition that derives to YES.
    event SyntheticConditionDerivableAsYes(EventId indexed eventId, ConditionId indexed conditionId);
}

/// @title NegRiskModule
/// @author Polymarket
/// @notice Unified module for neg-risk markets and legacy neg-risk migration
/// @dev Registered at moduleId=2 (NEGRISK)
///      ConditionId encodes:
///      [moduleId(8) | baseHash(128) | arity(16) | reserved(64) | resolutionChain(16) |
///      conditionIndex(16) | outcomeIndex(8)]
///      Neg-risk events use real condition indexes [0, arity) and a synthetic Other condition at
///      index arity.
contract NegRiskModule is UUPSUpgradeable, Initializable, BaseModule, NegRiskMigrationMixin, NegRiskModuleEvents {
    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice Event ID to aggregate YES payout: zero until a YES result is stored,
    ///         then `RESULT_DENOMINATOR` (at most one YES per event).
    /// @dev Typed `EventId` key: writes are structurally restricted to canonical event IDs.
    mapping(EventId => uint256) public resultsSum;

    /// @notice Event ID to number of real conditions with directly stored results.
    /// @dev Synthetic Other and lazily derived sibling results are not counted.
    mapping(EventId => uint256) public conditionsResolved;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Initialize the NegRiskModule contract
    /// @param _positionManager The PositionManager contract address
    /// @param _conditionalTokens The legacy CTF contract address
    /// @param _usdceToken The USDC.e token address
    /// @param _negRiskAdapter The legacy NegRisk adapter address
    /// @param _moduleResolutionChain Chain enum allowed to resolve module conditions
    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        address _negRiskAdapter,
        ResolutionChain _moduleResolutionChain
    )
        BaseModule(_positionManager, _moduleResolutionChain)
        NegRiskMigrationMixin(_conditionalTokens, _usdceToken, _negRiskAdapter)
    {
        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied module owner and admin.
    /// @param _owner The owner address.
    /// @param _admin The initial admin address.
    function initialize(address _owner, address _admin) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, _ROLE_0);
    }

    /*--------------------------------------------------------------
                              ONLY RESOLVER
    --------------------------------------------------------------*/

    /// @notice Report result for a neg-risk condition.
    /// @dev Resolver callers may report real condition indexes only. Bridge callers may also
    ///      report the synthetic Other condition at index `eventId.arity()`.
    /// @param _conditionId The condition ID.
    /// @param _result The result array [yesValue, noValue] summing to RESULT_DENOMINATOR.
    function reportResult(ConditionId _conditionId, uint256[] calldata _result)
        external
        override
        onlyResolver(_conditionId)
    {
        require(_conditionId.moduleId() == ModuleIds.NEGRISK, InvalidEventId());

        bool isMigrationCondition_ = _isMigrationCondition(_conditionId);
        // Resolver roles cannot resolve migration conditions.
        if (isMigrationCondition_ && hasAllRoles(msg.sender, RESOLVER_ROLE)) revert MigrationNotSupported();

        uint256[] storage storedResult = result[_conditionId];
        if (storedResult.length > 0) {
            // If the result being proposed by the resolver or bridge is different from the stored result, revert.
            // This is catastrophic and should never happen.
            if (_result.length != 2 || _result[0] != storedResult[0] || _result[1] != storedResult[1]) {
                revert ExistingPayoutMismatch();
            }

            // The condition is already resolved; if the caller is a resolver role, revert.
            // Resolvers that are calling should handle possible reverts.
            if (hasAllRoles(msg.sender, RESOLVER_ROLE)) revert ConditionAlreadyResolved();

            // The condition is already resolved; if the caller is a bridge role, return silently.
            return;
        }

        // If the condition is a migration condition, resolve it and return.
        if (isMigrationCondition_) {
            _resolveMigrationCondition(_conditionId);

            // Verify that the result being proposed by the bridge is equal to the result we just got from the CTF.
            // Something is wrong if this is not the case.
            uint256[] storage resolvedResult = result[_conditionId];
            if (_result.length != 2 || _result[0] != resolvedResult[0] || _result[1] != resolvedResult[1]) {
                revert ExistingPayoutMismatch();
            }

            return;
        }

        // The condition is not a migration condition, and has not been resolved yet.
        // (It is a native condition being resolved by a resolver or bridge).
        _finalizeNegriskResolution(_conditionId, _result);
    }

    /*--------------------------------------------------------------
                        NEGRISK HORIZONTAL OPERATIONS
    --------------------------------------------------------------*/

    /// @notice Mint one YES position per real condition plus the synthetic Other, burn collateral.
    ///         Collateral must be pre-transferred to the module before calling.
    /// @param _to Recipient of the minted YES positions.
    /// @param _eventId The neg-risk event ID.
    /// @param _amount Amount of collateral to split.
    function horizontalSplit(address _to, EventId _eventId, uint256 _amount) external {
        (PositionId[] memory positionIds, uint256[] memory amounts) = _buildEventArrays(_eventId, _amount);

        POSITION_MANAGER.batchMint(_to, positionIds, amounts);

        COLLATERAL_TOKEN.burn(_amount);

        emit HorizontalSplit(msg.sender, _eventId, _to, _amount);
    }

    /// @notice Burn one YES position per real condition plus the synthetic Other, mint collateral.
    ///         Positions must be pre-transferred to the module before calling.
    /// @param _to Recipient of the minted collateral.
    /// @param _eventId The neg-risk event ID.
    /// @param _amount Amount per condition to merge.
    function horizontalMerge(address _to, EventId _eventId, uint256 _amount) external {
        (PositionId[] memory positionIds, uint256[] memory amounts) = _buildEventArrays(_eventId, _amount);

        COLLATERAL_TOKEN.mint(_to, _amount);

        POSITION_MANAGER.batchBurn(positionIds, amounts);

        emit HorizontalMerge(msg.sender, _eventId, _to, _amount);
    }

    /// @notice Convert a NO position into YES positions for all other conditions.
    /// @dev 1 NO(i) = all YES(j) for j != i, including the synthetic Other at index
    ///      `eventId.arity()`. NO position must be pre-transferred to the module before calling.
    /// @param _to Recipient for the YES positions.
    /// @param _eventId The event ID.
    /// @param _conditionIndex Real condition index in `[0, arity]` (Other at `arity`).
    /// @param _amount Amount to convert.
    function convert(address _to, EventId _eventId, uint256 _conditionIndex, uint256 _amount) external {
        uint256 conditionCount_ = _validateEventId(_eventId);
        // Including the synthetic fallback condition
        require(_conditionIndex <= conditionCount_, InvalidConditionIndex());

        ConditionId sourceConditionId = _eventId.computeConditionId(_conditionIndex);
        PositionId noPositionId = sourceConditionId.computePositionId(1);

        // Mint YES positions for all other conditions
        for (uint256 i = 0; i <= conditionCount_; ++i) {
            if (i == _conditionIndex) continue;
            PositionId yesPositionId = _eventId.computeConditionId(i).computePositionId(0);
            POSITION_MANAGER.mint(_to, yesPositionId, _amount);
        }

        POSITION_MANAGER.burn(noPositionId, _amount);

        emit PositionConverted(msg.sender, _eventId, _to, _conditionIndex, _amount);
    }

    /*--------------------------------------------------------------
                             MODULE IDENTITY
    --------------------------------------------------------------*/

    /// @notice Returns the module identifier for neg-risk markets
    /// @return The NEGRISK module ID constant
    function moduleId() external pure override returns (uint256) {
        return ModuleIds.NEGRISK;
    }

    /*--------------------------------------------------------------
                                 PUBLIC
    --------------------------------------------------------------*/

    /// @notice Get event ID from data
    /// @dev Uses conditionIndex=0 for the event root
    /// @param _conditionCount Number of conditions in the event
    /// @param _data Data used to derive the event ID
    /// @return The derived event ID
    function getEventId(uint256 _conditionCount, bytes calldata _data) public view returns (EventId) {
        require(_conditionCount >= 2 && _conditionCount <= type(uint16).max, InvalidConditionCount());
        return EventIdLib.encodeFromData(ModuleIds.NEGRISK, _conditionCount, _data, RESOLUTION_CHAIN);
    }

    /// @notice Get condition count from a neg-risk event ID
    /// @param _eventId The event ID
    /// @return The decoded condition count, or 0 if the event ID is not a valid neg-risk event
    function conditionCount(EventId _eventId) public pure returns (uint256) {
        if (_eventId.moduleId() != ModuleIds.NEGRISK) return 0;

        uint256 conditionCount_ = _eventId.arity();
        if (conditionCount_ < 2 || conditionCount_ > type(uint16).max) return 0;

        return conditionCount_;
    }

    /// @inheritdoc BaseModule
    function getResult(ConditionId _conditionId) public view override returns (uint256[] memory) {
        uint256[] memory result_ = result[_conditionId];
        if (result_.length > 0) return result_;

        EventId eventId_ = _conditionId.eventId();
        uint256 conditionCount_ = conditionCount(eventId_);
        uint256 conditionIndex_ = _conditionId.conditionIndex();

        // result_ is known to be [] at this point, so return it if:
        // - event ID is invalid
        // - condition index is out of range
        // - condition is a migration condition
        if (conditionCount_ == 0 || conditionIndex_ > conditionCount_ || _isMigrationCondition(_conditionId)) {
            return result_;
        }

        if (resultsSum[eventId_] == RESULT_DENOMINATOR) {
            // One condition in the event has resolved YES, so we can return NO for all other conditions
            result_ = new uint256[](2);
            result_[1] = RESULT_DENOMINATOR;
            return result_;
        }

        if (conditionIndex_ == conditionCount_ && conditionsResolved[eventId_] == conditionCount_) {
            // We're requesting the synthetic Other condition and all real conditions have resolved to NO, so we can
            // return YES for the synthetic Other
            result_ = new uint256[](2);
            result_[0] = RESULT_DENOMINATOR;
            return result_;
        }

        // We can't derive a result yet, so return []
        return result_;
    }

    /// @inheritdoc BaseModule
    /// @dev A YES result from a migrated event cannot be exported until every real condition has
    ///      a directly stored result. Spokes do not have migration metadata, so exporting it sooner
    ///      would let them lazily derive unresolved legacy siblings as NO.
    function getResultForBridge(ConditionId _conditionId) external view override returns (uint256[] memory result_) {
        result_ = getResult(_conditionId);

        if (result_.length != 2 || result_[0] != RESULT_DENOMINATOR) return result_;
        EventId eventId_ = _conditionId.eventId();
        if (!_isMigrationEvent(eventId_)) return result_;

        uint256 conditionCount_ = eventId_.arity();

        for (uint256 i; i < conditionCount_; ++i) {
            if (result[eventId_.computeConditionId(i)].length != 2) revert MigrationEventNotFullyResolved();
        }
    }

    /// @inheritdoc BaseModule
    function getPayout(PositionId _positionId, uint256 _amount) public view override returns (uint256) {
        uint256 outcomeIndex = _positionId.outcomeIndex();
        require(outcomeIndex < 2, InvalidOutcomeIndex());

        uint256[] memory result_ = getResult(_positionId.conditionId());
        if (result_.length == 0) revert ConditionNotResolved();

        return _amount * result_[outcomeIndex] / RESULT_DENOMINATOR;
    }

    /// @inheritdoc BaseModule
    function hasResult(ConditionId _conditionId) external view override returns (bool) {
        return getResult(_conditionId).length > 0;
    }

    /*--------------------------------------------------------------
                                INTERNAL
    --------------------------------------------------------------*/

    /// @dev Builds the positionIds and amounts arrays shared by horizontalSplit and
    /// horizontalMerge.
    function _buildEventArrays(EventId _eventId, uint256 _amount)
        private
        pure
        returns (PositionId[] memory positionIds, uint256[] memory amounts)
    {
        // Increment by 1 to include the synthetic fallback condition
        uint256 conditionCount_ = _validateEventId(_eventId) + 1;

        positionIds = new PositionId[](conditionCount_);
        amounts = new uint256[](conditionCount_);

        for (uint256 i = 0; i < conditionCount_; ++i) {
            positionIds[i] = _eventId.computeConditionId(i).computePositionId(0);
            amounts[i] = _amount;
        }
    }

    function _validateEventId(EventId _eventId) private pure returns (uint256 conditionCount_) {
        conditionCount_ = conditionCount(_eventId);
        require(conditionCount_ != 0, InvalidEventId());
    }

    /// @dev Delegates to `_finalizeNegriskResolution`, overrides behavior from `BaseMigrationMixin`.
    function _finalizeMigrationResolution(ConditionId _conditionId, uint256[] memory _result) internal override {
        _finalizeNegriskResolution(_conditionId, _result);
    }

    /// @dev Shared resolution finalizer for oracle and migration paths. Neg-risk results are
    ///      binary, so at most one condition can resolve YES. Synthetic Other is derived by
    ///      `getResult` unless it is reported directly by a bridge.
    ///      Bridge callers may report the synthetic Other condition directly.
    /// @param _conditionId The structured condition being resolved.
    /// @param _result The normalised payout vector (length 2, summing to RESULT_DENOMINATOR).
    function _finalizeNegriskResolution(ConditionId _conditionId, uint256[] memory _result) internal {
        EventId eventId_ = _conditionId.eventId();
        uint256 conditionCount_ = _validateEventId(eventId_);
        uint256 conditionIndex_ = _conditionId.conditionIndex();

        require(
            conditionIndex_ < conditionCount_
                || (conditionIndex_ == conditionCount_ && hasAllRoles(msg.sender, BRIDGE_ROLE)),
            InvalidConditionIndex()
        );

        // Store and validate result
        _storeResult(_conditionId, _result);

        // Synthetic Other cannot be NO after every real condition has directly resolved NO.
        // This check is intentionally on the synthetic path because synthetic Other is excluded
        // from conditionsResolved below.
        if (conditionIndex_ == conditionCount_ && _result[0] == 0) {
            require(
                conditionsResolved[eventId_] < conditionCount_ || resultsSum[eventId_] == RESULT_DENOMINATOR,
                InvalidResults()
            );
        }

        // Once one condition is YES, every unresolved sibling is derivable as NO.
        if (_result[0] == RESULT_DENOMINATOR) {
            require(resultsSum[eventId_] == 0, InvalidResults());
            resultsSum[eventId_] = RESULT_DENOMINATOR;

            emit RemainingConditionsDerivableAsNo(eventId_);
        }

        // Track directly stored real conditions only. Synthetic Other may be reported by a bridge,
        // but it is not one of the event's real conditions.
        if (conditionIndex_ < conditionCount_) {
            uint256 conditionsResolved_ = conditionsResolved[eventId_];
            if (conditionsResolved_ < conditionCount_) {
                conditionsResolved_ += 1;
                conditionsResolved[eventId_] = conditionsResolved_;
            } else {
                // A pre-upgrade counter may already include a directly stored synthetic result.
                // Let such an in-flight event finish without incrementing past arity.
                ConditionId syntheticConditionId_ = eventId_.computeConditionId(conditionCount_);
                require(
                    conditionsResolved_ == conditionCount_ && result[syntheticConditionId_].length != 0,
                    InvalidResults()
                );
            }

            // If this was the last unresolved real condition and no condition resolved YES, the
            // synthetic Other condition is now derivable as YES.
            if (conditionsResolved_ == conditionCount_ && resultsSum[eventId_] == 0) {
                ConditionId syntheticConditionId_ = eventId_.computeConditionId(conditionCount_);
                if (result[syntheticConditionId_].length == 0) {
                    emit SyntheticConditionDerivableAsYes(eventId_, syntheticConditionId_);
                } else {
                    // A pre-upgrade count may reach arity before its last real result. Preserve that
                    // ordering while still rejecting a final state where every condition is NO.
                    require(!_allRealResultsStored(eventId_, conditionCount_), InvalidResults());
                }
            }
        }

        emit ResultReported(msg.sender, _conditionId, _result);
    }

    /// @dev True when every real condition has a directly stored result. Used to reject
    ///      an all-NO final state, which the counter alone cannot detect.
    function _allRealResultsStored(EventId _eventId, uint256 _conditionCount) private view returns (bool) {
        for (uint256 i; i < _conditionCount; ++i) {
            if (result[_eventId.computeConditionId(i)].length == 0) return false;
        }
        return true;
    }

    /// @dev Neg-risk conditions are binary: every condition resolves fully YES or fully NO.
    function _storeResult(ConditionId _conditionId, uint256[] memory _result) internal override {
        super._storeResult(_conditionId, _result);

        uint256 result0 = _result[0];
        require(result0 == 0 || result0 == RESULT_DENOMINATOR, InvalidResults());
    }

    /*--------------------------------------------------------------
                          UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the owner and enforces immutable config compatibility.
    /// @param newImplementation The proposed implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        NegRiskModule newImpl = NegRiskModule(newImplementation);

        if (
            newImpl.moduleId() != ModuleIds.NEGRISK || address(newImpl.POSITION_MANAGER()) != address(POSITION_MANAGER)
                || address(newImpl.COLLATERAL_TOKEN()) != address(COLLATERAL_TOKEN)
                || address(newImpl.CONDITIONAL_TOKENS()) != address(CONDITIONAL_TOKENS) || newImpl.USDCE() != USDCE
                || address(newImpl.NEG_RISK_ADAPTER()) != address(NEG_RISK_ADAPTER)
                || newImpl.RESOLUTION_CHAIN() != RESOLUTION_CHAIN
        ) revert IncompatibleImplementation();
    }
}

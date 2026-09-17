// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { OracleAggregator as OracleAggregatorBase } from "@polymarket-v2/src/oracle/OracleAggregator.sol";
import { ConditionId, ConditionIdLib, EventId, OUTCOME_MASK } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title OracleAggregator verification harness
/// @notice Extends the production `OracleAggregator` with read-only views the aggregator specs
///         need but CVL cannot express. Named `OracleAggregator` (rename-import of the base) so
///         specs, `using` aliases, UDVT qualifiers and `parametric_contracts` written against the
///         production name keep resolving when this harness replaces it in the scene.
contract OracleAggregator is OracleAggregatorBase {
    constructor(address _positionManager) OracleAggregatorBase(_positionManager) { }

    /*--------------------------------------------------------------
                    REQUEST CONFIG, KEYED ON RAW BYTES32
    --------------------------------------------------------------*/

    function _cfgKey(bytes32 _rawEventId) private pure returns (EventId) {
        return EventId.wrap(bytes29(_rawEventId));
    }

    /// @notice `requestConfigs[e].targetContract`. Zero means "no request registered".
    function cfgTarget(bytes32 _rawEventId) external view returns (address) {
        return requestConfigs[_cfgKey(_rawEventId)].targetContract;
    }

    /// @notice `requestConfigs[e].marketType`.
    function cfgMarketType(bytes32 _rawEventId) external view returns (MarketType) {
        return requestConfigs[_cfgKey(_rawEventId)].marketType;
    }

    /// @notice `requestConfigs[e].resultLength`.
    function cfgResultLength(bytes32 _rawEventId) external view returns (uint16) {
        return requestConfigs[_cfgKey(_rawEventId)].resultLength;
    }

    /// @notice `requestConfigs[e].resultLength`.
    function cfgResultLengthOf(EventId _eventId) external view returns (uint16) {
        return requestConfigs[_eventId].resultLength;
    }

    /// @notice `requestConfigs[e].livenessWindow`.
    function cfgLivenessWindow(bytes32 _rawEventId) external view returns (uint32) {
        return requestConfigs[_cfgKey(_rawEventId)].livenessWindow;
    }

    /// @notice `requestConfigs[e].reporterThreshold`.
    function cfgReporterThreshold(bytes32 _rawEventId) external view returns (uint16) {
        return requestConfigs[_cfgKey(_rawEventId)].reporterThreshold;
    }

    /// @notice `requestConfigs[e].disputerThreshold`.
    function cfgDisputerThreshold(bytes32 _rawEventId) external view returns (uint16) {
        return requestConfigs[_cfgKey(_rawEventId)].disputerThreshold;
    }

    /// @notice `requestConfigs[e].arbitratorModule`.
    function cfgArbitrator(bytes32 _rawEventId) external view returns (address) {
        return requestConfigs[_cfgKey(_rawEventId)].arbitratorModule;
    }

    /// @notice `requestConfigs[e].finalizer`. Zero means permissionless `finalize`.
    function cfgFinalizer(bytes32 _rawEventId) external view returns (address) {
        return requestConfigs[_cfgKey(_rawEventId)].finalizer;
    }

    /// @notice `marketPaused[e]`, keyed on a raw `bytes32`.
    function marketPausedRaw(bytes32 _rawEventId) external view returns (bool) {
        return marketPaused[_cfgKey(_rawEventId)];
    }

    /*--------------------------------------------------------------
                REQUEST CONFIG, KEYED ON A RAW REQUEST ID
    --------------------------------------------------------------*/

    /// @dev The production lookup path: raw request id -> `ConditionId` -> parent `EventId`. Does
    ///      not revert on a dirty outcome byte so parametric rules
    ///      can quantify over arbitrary request ids; canonicality stays a separate, visible
    ///      predicate (`isCanonicalRequestId`).
    function _eventKeyOfRequest(bytes32 _requestId) private pure returns (EventId) {
        return ConditionId.wrap(bytes31(_requestId)).eventId();
    }

    /// @notice Parent event id of a request id, as a raw `bytes32`.
    function eventIdOfRequest(bytes32 _requestId) external pure returns (bytes32) {
        return bytes32(EventId.unwrap(_eventKeyOfRequest(_requestId)));
    }

    /// @notice `targetContract` of the request's config.
    function targetOfRequest(bytes32 _requestId) external view returns (address) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].targetContract;
    }

    /// @notice `marketType` of the request's config.
    function marketTypeOfRequest(bytes32 _requestId) external view returns (MarketType) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].marketType;
    }

    /// @notice `reporterThreshold` of the request's config — `T_r` in the threshold properties.
    function reporterThresholdOfRequest(bytes32 _requestId) external view returns (uint16) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].reporterThreshold;
    }

    /// @notice `disputerThreshold` of the request's config — `T_d` in the dispute properties.
    function disputerThresholdOfRequest(bytes32 _requestId) external view returns (uint16) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].disputerThreshold;
    }

    /// @notice `livenessWindow` of the request's config.
    function livenessWindowOfRequest(bytes32 _requestId) external view returns (uint32) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].livenessWindow;
    }

    /// @notice `arbitratorModule` of the request's config.
    function arbitratorOfRequest(bytes32 _requestId) external view returns (address) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].arbitratorModule;
    }

    /// @notice `finalizer` of the request's config.
    function finalizerOfRequest(bytes32 _requestId) external view returns (address) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].finalizer;
    }

    /// @notice `resultLength` of the request's config — the length `_validateResult` holds
    ///         every reported and resolved array to.
    function resultLengthOfRequest(bytes32 _requestId) external view returns (uint16) {
        return requestConfigs[_eventKeyOfRequest(_requestId)].resultLength;
    }

    /// @notice `marketPaused` of the request's parent event.
    function marketPausedOfRequest(bytes32 _requestId) external view returns (bool) {
        return marketPaused[_eventKeyOfRequest(_requestId)];
    }

    /*--------------------------------------------------------------
                    RESOLUTION STATE, PROJECTED TO SCALARS
    --------------------------------------------------------------*/

    /// @notice Persisted `status` as its underlying `uint8` (None 0, Active 1,
    ///         ArbitrationRequested 2, Resolved 3).
    function statusOf(bytes32 _requestId) external view returns (uint8) {
        return uint8(resolutionStates[_requestId].status);
    }

    /// @notice Persisted `disputeCount`.
    function disputeCountOf(bytes32 _requestId) external view returns (uint16) {
        return resolutionStates[_requestId].disputeCount;
    }

    /// @notice Persisted `disputeWindowEnd`.
    function windowEndOf(bytes32 _requestId) external view returns (uint40) {
        return resolutionStates[_requestId].disputeWindowEnd;
    }

    /// @notice Persisted `proposedResultHash`. Zero means "no standing proposal".
    function proposedHashOf(bytes32 _requestId) external view returns (bytes32) {
        return resolutionStates[_requestId].proposedResultHash;
    }

    /*--------------------------------------------------------------
                    MODULE SETS (PRIVATE STORAGE, PUBLIC API)
    --------------------------------------------------------------*/

    /// @notice Number of reporter modules registered for an event.
    function reporterModuleCount(bytes32 _rawEventId) external view returns (uint256) {
        return this.getReporterModules(_cfgKey(_rawEventId)).length;
    }

    /// @notice Number of disputer modules registered for an event. See `reporterModuleCount`.
    function disputerModuleCount(bytes32 _rawEventId) external view returns (uint256) {
        return this.getDisputerModules(_cfgKey(_rawEventId)).length;
    }

    /// @notice `isReporterModule`, keyed on a raw `bytes32` event id.
    function isReporterModuleRaw(bytes32 _rawEventId, address _module) external view returns (bool) {
        return isReporterModule(_cfgKey(_rawEventId), _module);
    }

    /// @notice `isDisputerModule`, keyed on a raw `bytes32` event id.
    function isDisputerModuleRaw(bytes32 _rawEventId, address _module) external view returns (bool) {
        return isDisputerModule(_cfgKey(_rawEventId), _module);
    }

    /// @notice Reporter-set membership for a request id's parent event.
    function isReporterOfRequest(bytes32 _requestId, address _module) external view returns (bool) {
        return isReporterModule(_eventKeyOfRequest(_requestId), _module);
    }

    /// @notice Disputer-set membership for a request id's parent event.
    function isDisputerOfRequest(bytes32 _requestId, address _module) external view returns (bool) {
        return isDisputerModule(_eventKeyOfRequest(_requestId), _module);
    }

    /*--------------------------------------------------------------
                        HASH PROJECTIONS (PURE)
    --------------------------------------------------------------*/

    /// @notice `keccak256(abi.encode([_value]))` — the hash `reportResult`, `resolveResult` and
    ///         `finalize` compute for a length-1 result array.
    function resultHashFor(uint256 _value) external pure returns (bytes32) {
        uint256[] memory result = new uint256[](1);
        result[0] = _value;
        return keccak256(abi.encode(result));
    }

    /// @notice The per-result vote key: `keccak256(abi.encode(requestId, resultHash))`. Both
    ///         operands are `bytes32`, so this pre-image is a fixed 64 bytes.
    function voteKeyFor(bytes32 _requestId, bytes32 _resultHash) external pure returns (bytes32) {
        return keccak256(abi.encode(_requestId, _resultHash));
    }

    /// @notice The vote key of the singleton result `[_value]` under `_requestId`.
    function voteKeyForValue(bytes32 _requestId, uint256 _value) external pure returns (bytes32) {
        uint256[] memory result = new uint256[](1);
        result[0] = _value;
        return keccak256(abi.encode(_requestId, keccak256(abi.encode(result))));
    }

    /*--------------------------------------------------------------
                        ID BIT FIELDS (PURE)
    --------------------------------------------------------------*/

    /// @notice True iff the raw request id has a clear outcome byte, i.e. `ConditionIdLib.from`
    ///         accepts it. Every aggregator entry point requires this.
    function isCanonicalRequestId(bytes32 _requestId) external pure returns (bool) {
        return uint256(_requestId) & OUTCOME_MASK == 0;
    }

    /// @notice True iff the request id is a canonical *event* id (condition-index and outcome
    ///         bytes clear) — the `isValidEventId` gate binary and atomic markets are held to.
    function isValidEventIdRaw(bytes32 _requestId) external pure returns (bool) {
        return ConditionId.wrap(bytes31(_requestId)).isValidEventId();
    }

    /// @notice Condition index encoded in a raw request id.
    function conditionIndexOf(bytes32 _requestId) external pure returns (uint256) {
        return ConditionId.wrap(bytes31(_requestId)).conditionIndex();
    }

    /// @notice Neg-risk condition count (arity) of the request's parent event.
    function arityOfRequest(bytes32 _requestId) external pure returns (uint256) {
        return _eventKeyOfRequest(_requestId).arity();
    }

    /// @notice `eventId(requestId).computeConditionId(_index)` as a raw `bytes32` — the condition
    ///         id `_finalizeConditions` reports to the target: computed from the winner index on
    ///         the atomic branch, and bit-identical to the request's own id (index =
    ///         `conditionIndex(requestId)`) on every other branch. Lets a rule check WHICH
    ///         condition the aggregator picked.
    function conditionIdOfRequestIndex(bytes32 _requestId, uint256 _index) external pure returns (bytes32) {
        return bytes32(ConditionId.unwrap(_eventKeyOfRequest(_requestId).computeConditionId(_index)));
    }

    /*--------------------------------------------------------------
                    INTERNAL PREDICATES (PURE)
    --------------------------------------------------------------*/

    /// @notice `_validateResult` exposed so its acceptance set can be pinned in both directions.
    function validateResultForRequest(
        bytes32 _requestId,
        MarketType _marketType,
        uint16 _resultLength,
        uint256[] calldata _result
    ) external pure {
        _validateResult(_requestId, _marketType, _resultLength, _result);
    }

    /// @notice `_isActiveStatus` over the raw `uint8` status encoding.
    function isActiveStatusExt(uint8 _status) external pure returns (bool) {
        return _isActiveStatus(ResolutionStatus(_status));
    }

    /*--------------------------------------------------------------
                        PROXY / INIT SLOT READS
    --------------------------------------------------------------*/

    /// @notice Current ERC-1967 implementation address, read from the constant proxy slot.
    function implementationSlotValue() external view returns (address impl) {
        assembly {
            impl := sload(_ERC1967_IMPLEMENTATION_SLOT)
        }
    }

    /// @notice Solady Initializable's initializedVersion (bits 1..64 of the init slot).
    function initializedVersion() external view returns (uint64) {
        return _getInitializedVersion();
    }
}

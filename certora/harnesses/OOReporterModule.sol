// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { OOReporterModule as OOReporterModuleBase } from "@polymarket-v2/src/oracle/modules/OOReporterModule.sol";
import { OptimisticOraclePayoutLib } from "@polymarket-v2/src/oracle/libraries/OptimisticOraclePayoutLib.sol";
import { ConditionId, ConditionIdLib, EventId, OUTCOME_MASK } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title OOReporterModule verification harness
/// @notice Extends the production OOReporterModule with read-only views the oracle specs need
///         but CVL cannot express. Named `OOReporterModule` (rename-import of the base) so
///         specs, links and UDVT qualifiers written against the production name keep resolving
///         when this harness replaces it in the scene.
contract OOReporterModule is OOReporterModuleBase {
    constructor(address _ooReporter) OOReporterModuleBase(_ooReporter) { }

    /*--------------------------------------------------------------
                    VALIDATION AND CONVERSION (PURE)
    --------------------------------------------------------------*/

    /// @notice `_isValidBinaryPrice` exposed for the exact-acceptance-set rules.
    function isValidBinaryPriceExt(int256 _price, uint8 _marketType) external pure returns (bool) {
        return _isValidBinaryPrice(_price, _marketType);
    }

    /// @notice Length of the payout vector `OptimisticOraclePayoutLib.priceToPayouts` produces.
    function priceToPayoutsLen(int256 _price, uint16 _n) external pure returns (uint256) {
        return OptimisticOraclePayoutLib.priceToPayouts(_price, _n).length;
    }

    /// @notice Element `_k` of the payout vector. Reverts when `_k` is out of range,
    ///         which is what makes the "no out-of-bounds write" claim observable.
    function priceToPayoutsAt(int256 _price, uint16 _n, uint256 _k) external pure returns (uint256) {
        return OptimisticOraclePayoutLib.priceToPayouts(_price, _n)[_k];
    }

    /*--------------------------------------------------------------
                        REQUEST ID BIT FIELDS (PURE)
    --------------------------------------------------------------*/

    /// @notice Neg-risk condition count of the request's parent event, via the production library.
    function arityOfRequestId(bytes32 _requestId) external pure returns (uint256) {
        return ConditionIdLib.from(_requestId).eventId().arity();
    }

    /// @notice True iff the raw request id has a clear outcome byte (`ConditionIdLib.from` accepts it).
    function isCanonicalRequestId(bytes32 _requestId) external pure returns (bool) {
        return uint256(_requestId) & OUTCOME_MASK == 0;
    }

    /// @notice Numeric reinterpretation of a raw request id, so CVL can restate bit fields
    ///         with integer division instead of pulling in bitvector theory.
    function asUint(bytes32 _requestId) external pure returns (uint256) {
        return uint256(_requestId);
    }

    /// @notice `eventId(requestId).computeConditionId(_index)` as a raw `bytes32`.
    function conditionIdOfEventIndex(bytes32 _requestId, uint256 _index) external pure returns (bytes32) {
        return bytes32(ConditionId.unwrap(ConditionIdLib.from(_requestId).eventId().computeConditionId(_index)));
    }

    /*--------------------------------------------------------------
                    SETTLED RESULT PROJECTIONS (VIEW)
    --------------------------------------------------------------*/

    /// @notice Raw UMA price `_getSettledResult` would relay for `_requestId`.
    function settledPrice(bytes32 _requestId) external view returns (int256 price) {
        (price,) = _getSettledResult(_requestId);
    }

    /// @notice Length of the translated result array `_getSettledResult` would forward.
    function settledResultLen(bytes32 _requestId) external view returns (uint256) {
        (, uint256[] memory result) = _getSettledResult(_requestId);
        return result.length;
    }

    /// @notice Element `_k` of the translated result array `_getSettledResult` would forward.
    function settledResultAt(bytes32 _requestId, uint256 _k) external view returns (uint256) {
        (, uint256[] memory result) = _getSettledResult(_requestId);
        return result[_k];
    }

    /*--------------------------------------------------------------
                    AGGREGATOR-SIDE OBSERVABLES (PURE)
    --------------------------------------------------------------*/

    /// @notice `keccak256(abi.encode([_value]))` — the hash `OracleAggregator.reportResult`
    ///         stores for a length-1 result array.
    function resultHashFor(uint256 _value) external pure returns (bytes32) {
        uint256[] memory result = new uint256[](1);
        result[0] = _value;
        return keccak256(abi.encode(result));
    }

    /// @notice `OracleAggregator`'s per-result vote key: `keccak256(abi.encode(requestId, resultHash))`.
    function voteKeyFor(bytes32 _requestId, bytes32 _resultHash) external pure returns (bytes32) {
        return keccak256(abi.encode(_requestId, _resultHash));
    }

    /*--------------------------------------------------------------
                        MODULE STATE PROJECTIONS (VIEW)
    --------------------------------------------------------------*/

    /// @notice `requestInitialized` keyed by a raw `bytes32`, with no canonicality constraint,
    ///         so parametric rules can quantify over arbitrary scope keys.
    function requestInitializedAt(bytes32 _scopeKey) external view returns (bool) {
        return requestInitialized[ConditionId.wrap(bytes31(_scopeKey))];
    }

    /// @notice Parent event id of a scope key, as a raw `bytes32` (condition index and outcome
    ///         bytes cleared) — the left-hand side of the batch's `scopeId.eventId() == _eventId`
    ///         check.
    function eventIdOfScopeKey(bytes32 _scopeKey) external pure returns (bytes32) {
        return bytes32(EventId.unwrap(ConditionId.wrap(bytes31(_scopeKey)).eventId()));
    }

    /// @notice An `EventId` as a raw `bytes32`, so CVL can compare it with `eventIdOfScopeKey`
    ///         (it cannot construct or destructure a `bytes29` UDVT itself).
    function eventIdAsBytes32(EventId _eventId) external pure returns (bytes32) {
        return bytes32(EventId.unwrap(_eventId));
    }

    /// @notice Current ERC-1967 implementation address, read from the constant proxy slot.
    function implementationSlotValue() external view returns (address impl) {
        assembly {
            impl := sload(_ERC1967_IMPLEMENTATION_SLOT)
        }
    }
}

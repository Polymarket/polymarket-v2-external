// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import {
    ConditionId,
    ConditionIdLib,
    EventId,
    EventIdLib,
    PositionId,
    computeBaseHash
} from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

abstract contract IdsTest is TestHelper {
    uint256 internal constant MODULE_MASK = 0xFF;
    uint256 internal constant ARITY_MASK = 0xFFFF;
    uint256 internal constant CONDITION_INDEX_MASK = 0xFFFF;
    uint256 internal constant RESOLUTION_CHAIN_MASK = 0xFFFF;
    uint256 internal constant OUTCOME_MASK = 0xFF;
    uint256 internal constant EVENT_SUFFIX_MASK = (uint256(1) << 24) - 1;
    uint256 internal constant RESERVED_MASK = type(uint64).max;

    function _maskConditionId(bytes32 _conditionId) internal pure returns (bytes32) {
        return bytes32(uint256(_conditionId) & ~OUTCOME_MASK);
    }

    function _maskEventId(bytes32 _eventId) internal pure returns (bytes32) {
        return bytes32(uint256(_eventId) & ~EVENT_SUFFIX_MASK);
    }

    function _encodePositionId(
        uint256 _moduleId,
        uint256 _arity,
        uint256 _conditionIndex,
        uint256 _outcomeIndex,
        bytes calldata _data
    ) internal pure returns (PositionId) {
        return ConditionIdLib.encode(_moduleId, computeBaseHash(_moduleId, _data), _arity, _conditionIndex)
            .computePositionId(_outcomeIndex);
    }
}

/*--------------------------------------------------------------
                       POSITION ID ROUNDTRIP
--------------------------------------------------------------*/

contract PositionIdLibTest_roundtrip is IdsTest {
    /// @notice Asserts full-position encoding roundtrips through the public decoders with masking.
    /// @dev Verifies `decode(encode(x)) == x & MASK` for module, arity, condition index, and
    /// outcome index.
    function test_positionId(
        uint256 _moduleId,
        uint256 _arity,
        uint256 _conditionIndex,
        uint256 _outcomeIndex,
        bytes calldata _data
    ) external {
        PositionId positionId = _encodePositionId(_moduleId, _arity, _conditionIndex, _outcomeIndex, _data);

        assertEq(positionId.moduleId(), _moduleId & MODULE_MASK);
        assertEq(positionId.conditionId().eventId().arity(), _arity & ARITY_MASK);
        assertEq(positionId.conditionId().conditionIndex(), _conditionIndex & CONDITION_INDEX_MASK);
        assertEq(positionId.outcomeIndex(), _outcomeIndex & OUTCOME_MASK);
    }
}

/*--------------------------------------------------------------
                        PATH EQUIVALENCE
--------------------------------------------------------------*/

contract PositionIdLibTest_pathEquivalence is IdsTest {
    /// @notice Asserts direct condition encoding matches the explicit base-hash encoding path.
    /// @dev Verifies `ConditionIdLib.encodeFromData(moduleId, conditionIndex, data)` equals
    /// `ConditionIdLib.encode(moduleId, computeBaseHash(moduleId, data), 0, conditionIndex)`.
    function test_conditionIdPaths(uint256 _moduleId, uint256 _conditionIndex, bytes calldata _data) external {
        assertEq(
            ConditionId.unwrap(ConditionIdLib.encodeFromData(_moduleId, _conditionIndex, _data)),
            ConditionId.unwrap(ConditionIdLib.encode(_moduleId, computeBaseHash(_moduleId, _data), 0, _conditionIndex))
        );
    }

    /// @notice Asserts the EventId data-encoded path matches its explicit base-hash counterpart.
    /// @dev Verifies `EventIdLib.encodeFromData(moduleId, arity, data)` equals
    /// `EventIdLib.encode(moduleId, computeBaseHash(moduleId, data), arity)`.
    function test_eventIdPaths(uint256 _moduleId, uint256 _arity, bytes calldata _data) external {
        assertEq(
            EventId.unwrap(EventIdLib.encodeFromData(_moduleId, _arity, _data)),
            EventId.unwrap(EventIdLib.encode(_moduleId, computeBaseHash(_moduleId, _data), _arity))
        );
    }
}

/*--------------------------------------------------------------
                      CONDITION -> POSITION
--------------------------------------------------------------*/

contract ConditionIdLibTest_positionId is IdsTest {
    /// @notice Asserts position derivation from a canonical condition ID preserves the condition
    /// bits.
    /// @dev Verifies `ConditionIdLib.positionId` ORs in the masked outcome index.
    function test_conditionToPosition(bytes32 _conditionId, uint256 _outcomeIndex) external {
        // ConditionIdLib.from requires canonical input; mask the outcome byte first.
        ConditionId conditionId = ConditionIdLib.from(_maskConditionId(_conditionId));
        PositionId positionId = conditionId.computePositionId(_outcomeIndex);

        assertEq(ConditionId.unwrap(positionId.conditionId()), _maskConditionId(_conditionId));
        assertEq(positionId.outcomeIndex(), _outcomeIndex & OUTCOME_MASK);
    }
}

/*--------------------------------------------------------------
                       EVENT <-> CONDITION
--------------------------------------------------------------*/

contract EventIdLibTest_conditionRoundtrip is IdsTest {
    /// @notice Asserts event IDs and condition IDs roundtrip once the input event ID is
    /// normalized.
    /// @dev Verifies `eventId.computeConditionId(conditionIndex).eventId()` returns the masked event ID,
    /// preserving reserved event bits, and that the decoded condition index matches
    /// `conditionIndex & 0xFFFF`.
    function test_eventConditionRoundtrip(bytes32 _eventId, uint256 _conditionIndex) external {
        EventId eventId = EventIdLib.from(_maskEventId(_eventId));
        ConditionId conditionId = eventId.computeConditionId(_conditionIndex);

        assertEq(EventId.unwrap(conditionId.eventId()), EventId.unwrap(eventId));
        assertEq(conditionId.conditionIndex(), _conditionIndex & CONDITION_INDEX_MASK);
    }
}

/*--------------------------------------------------------------
                       NEG-RISK ENCODING
--------------------------------------------------------------*/

contract EventIdLibTest_encodeFromData is IdsTest {
    /// @notice Asserts EventIdLib.encodeFromData round-trips via the asCondition() reinterpret.
    function test_negRiskEventId(uint256 _conditionCount, bytes calldata _data) external {
        EventId eventId = EventIdLib.encodeFromData(ModuleIds.NEGRISK, _conditionCount, _data);

        assertEq(eventId.arity(), _conditionCount & ARITY_MASK);
        assertEq(EventId.unwrap(eventId.asCondition().eventId()), EventId.unwrap(eventId));
        assertEq(eventId.asCondition().conditionIndex(), 0);
    }
}

/*--------------------------------------------------------------
                       IS VALID EVENT ID
--------------------------------------------------------------*/

contract ConditionIdLibTest_isValidEventId is IdsTest {
    /// @notice Returns true when the ConditionId is bit-equivalent to an EventId (conditionIndex
    ///         region zero).
    function test_isValidEventId_trueForEvent() external pure {
        EventId eventId = EventIdLib.encodeFromData(ModuleIds.NEGRISK, 3, abi.encode("isValidEventId-true"));
        ConditionId asCondition = eventId.asCondition();

        assertTrue(asCondition.isValidEventId());
    }

    /// @notice Returns false when the ConditionId carries a non-zero conditionIndex (i.e. is a
    ///         neg-risk subcondition rather than the parent event).
    function test_isValidEventId_falseForSubcondition() external pure {
        EventId eventId = EventIdLib.encodeFromData(ModuleIds.NEGRISK, 3, abi.encode("isValidEventId-false"));
        ConditionId subcondition = eventId.computeConditionId(1);

        assertFalse(subcondition.isValidEventId());
    }
}

/*--------------------------------------------------------------
                     STRUCTURAL INVARIANTS
--------------------------------------------------------------*/

contract PositionIdLibTest_structuralInvariants is IdsTest {
    /// @notice Asserts encoded position IDs always leave the reserved 64-bit region zeroed.
    /// @dev Verifies bits 40 through 103 are untouched by condition-to-position encoding, even
    ///      when `_arity` is fuzzed across the full uint256 range (arity lives at bits 104-119
    ///      and must not leak into the reserved region).
    function test_reservedBitsZero(
        uint256 _moduleId,
        uint256 _arity,
        uint256 _conditionIndex,
        uint256 _outcomeIndex,
        bytes calldata _data
    ) external {
        uint256 positionId = PositionId.unwrap(
            _encodePositionId(_moduleId, _arity, _conditionIndex, _outcomeIndex, _data)
        );

        assertEq((positionId >> 40) & RESERVED_MASK, 0);
    }

    /// @notice Asserts the resolution-chain field is right-aligned within the old reserved region.
    function test_resolutionChainBitsAreRightAligned(bytes32 _raw) external {
        uint256 chainMask = RESOLUTION_CHAIN_MASK << 24;
        bytes32 raw = bytes32((uint256(_raw) & ~OUTCOME_MASK & ~chainMask) | (uint256(1) << 24));
        ConditionId conditionId = ConditionIdLib.from(raw);

        assertEq(conditionId.resolutionChain(), 1);
    }

    /// @notice Asserts condition IDs always have a zero outcome byte when re-padded to bytes32.
    /// @dev Structural by type system (`ConditionId` is `bytes31`, no room for an outcome byte),
    ///      this test re-pads to bytes32 and confirms the bottom 8 bits are zero — i.e. the
    ///      conversion roundtrip preserves canonical wire format. Regression guard for any
    ///      future change to the underlying type.
    function test_conditionIdOutcomeByteZero(uint256 _moduleId, uint256 _conditionIndex, bytes calldata _data)
        external
    {
        assertEq(
            uint256(bytes32(ConditionId.unwrap(ConditionIdLib.encodeFromData(_moduleId, _conditionIndex, _data))))
                & OUTCOME_MASK,
            0
        );
    }
}

/*--------------------------------------------------------------
                         CANONICAL WRAPPER
--------------------------------------------------------------*/

/// @notice External wrapper so cheatcode vm.expectRevert catches library-level reverts.
contract IdLibWrapper {
    function wrapCondition(bytes32 _raw) external pure returns (ConditionId) {
        return ConditionIdLib.from(_raw);
    }

    function wrapEvent(bytes32 _raw) external pure returns (EventId) {
        return EventIdLib.from(_raw);
    }
}

contract IdsTest_canonicalization is IdsTest {
    IdLibWrapper internal wrapper;

    function setUp() public {
        wrapper = new IdLibWrapper();
    }

    /// @notice ConditionIdLib.from reverts on any non-zero bit in the outcome byte (bits 0-7).
    /// @dev `_outcomeBits` is bound to a non-zero `uint8` so we sweep the full outcome byte
    ///      rather than only bit 0.
    function test_revert_conditionIdNonCanonical_outcomeByte(bytes32 _conditionId, uint8 _outcomeBits) external {
        vm.assume(_outcomeBits != 0);
        bytes32 cleanCond = bytes32(uint256(_conditionId) & ~uint256(0xFF));
        bytes32 dirty = bytes32(uint256(cleanCond) | uint256(_outcomeBits));
        vm.expectRevert(abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, dirty));
        wrapper.wrapCondition(dirty);
    }

    /// @notice EventIdLib.from reverts when the outcome byte is non-zero.
    function test_revert_eventIdNonCanonical_outcomeByte(bytes32 _eventId, uint8 _outcomeBits) external {
        vm.assume(_outcomeBits != 0);
        bytes32 cleanEv = bytes32(uint256(_eventId) & ~uint256(EVENT_SUFFIX_MASK));
        bytes32 dirty = bytes32(uint256(cleanEv) | uint256(_outcomeBits));
        vm.expectRevert(abi.encodeWithSelector(EventIdLib.NonCanonicalEventId.selector, dirty));
        wrapper.wrapEvent(dirty);
    }

    /// @notice EventIdLib.from reverts when the condition-index region (bits 8-23) is non-zero,
    ///         locking the distinction between OUTCOME_MASK (8 bits) and EVENT_SUFFIX_MASK (24
    ///         bits) against silent regression. ConditionIdLib.from must still accept the same
    ///         input because the outcome byte stays zero.
    function test_revert_eventIdNonCanonical_conditionIndex(bytes32 _eventId, uint16 _conditionIndexBits) external {
        vm.assume(_conditionIndexBits != 0);
        bytes32 cleanEv = bytes32(uint256(_eventId) & ~uint256(EVENT_SUFFIX_MASK));
        // Inject the condition-index region only; leave the outcome byte zero.
        bytes32 dirty = bytes32(uint256(cleanEv) | (uint256(_conditionIndexBits) << 8));

        vm.expectRevert(abi.encodeWithSelector(EventIdLib.NonCanonicalEventId.selector, dirty));
        wrapper.wrapEvent(dirty);

        // ConditionIdLib.from accepts: outcome byte is still zero.
        ConditionId cond = wrapper.wrapCondition(dirty);
        assertEq(ConditionId.unwrap(cond), dirty);
    }

    /// @notice EventIdLib.from reverts when both the outcome byte and the conditionIndex
    ///         region are non-zero simultaneously.
    /// @dev Locks the single-mask `EVENT_SUFFIX_MASK` check against any future refactor that
    ///      splits canonicality into per-region checks with a broken short-circuit. With both
    ///      regions dirty the function must still revert.
    function test_revert_eventIdNonCanonical_bothDirty(bytes32 _eventId, uint8 _outcomeBits, uint16 _conditionIndexBits)
        external
    {
        vm.assume(_outcomeBits != 0);
        vm.assume(_conditionIndexBits != 0);
        bytes32 cleanEv = bytes32(uint256(_eventId) & ~uint256(EVENT_SUFFIX_MASK));
        bytes32 dirty = bytes32(uint256(cleanEv) | uint256(_outcomeBits) | (uint256(_conditionIndexBits) << 8));
        vm.expectRevert(abi.encodeWithSelector(EventIdLib.NonCanonicalEventId.selector, dirty));
        wrapper.wrapEvent(dirty);
    }
}

/*--------------------------------------------------------------
                       CANONICAL BOUNDARIES
--------------------------------------------------------------*/

contract IdsTest_canonicalBoundaries is IdsTest {
    /// @notice ConditionIdLib.from accepts the all-zero bytes32.
    /// @dev Boundary regression guard against any future change that treats bytes32(0) as a
    ///      sentinel rather than a canonical (if uninteresting) value.
    function test_conditionIdFrom_zero() external pure {
        ConditionId id = ConditionIdLib.from(bytes32(0));
        assertEq(ConditionId.unwrap(id), bytes32(0));
    }

    /// @notice ConditionIdLib.from accepts the canonical-maximum bytes32 (every bit set
    ///         except the outcome byte).
    function test_conditionIdFrom_canonicalMax() external pure {
        bytes32 canonicalMax = bytes32(type(uint256).max & ~OUTCOME_MASK);
        ConditionId id = ConditionIdLib.from(canonicalMax);
        assertEq(ConditionId.unwrap(id), canonicalMax);
    }

    /// @notice EventIdLib.from accepts the all-zero bytes32.
    function test_eventIdFrom_zero() external pure {
        EventId id = EventIdLib.from(bytes32(0));
        assertEq(EventId.unwrap(id), bytes32(0));
    }

    /// @notice EventIdLib.from accepts the canonical-maximum bytes32 (every bit set except
    ///         the bottom 24 bits).
    function test_eventIdFrom_canonicalMax() external pure {
        bytes32 canonicalMax = bytes32(type(uint256).max & ~EVENT_SUFFIX_MASK);
        EventId id = EventIdLib.from(canonicalMax);
        assertEq(EventId.unwrap(id), canonicalMax);
    }
}

/*--------------------------------------------------------------
                    ENCODE -> FROM IDEMPOTENCE
--------------------------------------------------------------*/

contract IdsTest_encodeIdempotence is IdsTest {
    /// @notice Every `ConditionIdLib.encode(...)` output is accepted by
    ///         `ConditionIdLib.from(bytes32(unwrap(...)))` without modification.
    /// @dev Locks the canonicality contract: encoders produce canonical-by-construction values
    ///      and the validating constructor accepts every such value. A drift between the two
    ///      would silently make the type lossy. Also exercises the `==` operator on ConditionId.
    function test_conditionIdEncodeFromIdempotent(
        uint256 _moduleId,
        bytes32 _baseHash,
        uint256 _arity,
        uint256 _conditionIndex
    ) external pure {
        ConditionId encoded = ConditionIdLib.encode(_moduleId, _baseHash, _arity, _conditionIndex);
        ConditionId rewrapped = ConditionIdLib.from(bytes32(ConditionId.unwrap(encoded)));
        assertTrue(encoded == rewrapped);
    }

    /// @notice Every `ConditionIdLib.encodeFromData(...)` output is accepted by
    ///         `ConditionIdLib.from(bytes32(unwrap(...)))` without modification.
    function test_conditionIdEncodeFromDataIdempotent(uint256 _moduleId, uint256 _conditionIndex, bytes calldata _data)
        external
        pure
    {
        ConditionId encoded = ConditionIdLib.encodeFromData(_moduleId, _conditionIndex, _data);
        ConditionId rewrapped = ConditionIdLib.from(bytes32(ConditionId.unwrap(encoded)));
        assertTrue(encoded == rewrapped);
    }

    /// @notice Every `EventIdLib.encode(...)` output is accepted by
    ///         `EventIdLib.from(bytes32(unwrap(...)))` without modification.
    function test_eventIdEncodeFromIdempotent(uint256 _moduleId, bytes32 _baseHash, uint256 _arity) external pure {
        EventId encoded = EventIdLib.encode(_moduleId, _baseHash, _arity);
        EventId rewrapped = EventIdLib.from(bytes32(EventId.unwrap(encoded)));
        assertTrue(encoded == rewrapped);
    }

    /// @notice Every `EventIdLib.encodeFromData(...)` output is accepted by
    ///         `EventIdLib.from(bytes32(unwrap(...)))` without modification.
    function test_eventIdEncodeFromDataIdempotent(uint256 _moduleId, uint256 _arity, bytes calldata _data)
        external
        pure
    {
        EventId encoded = EventIdLib.encodeFromData(_moduleId, _arity, _data);
        EventId rewrapped = EventIdLib.from(bytes32(EventId.unwrap(encoded)));
        assertTrue(encoded == rewrapped);
    }
}

/*--------------------------------------------------------------
                     COMPUTE BASE HASH
--------------------------------------------------------------*/

contract IdsTest_computeBaseHash is IdsTest {
    /// @notice `computeBaseHash` is `keccak256(abi.encode(moduleId, data))`.
    /// @dev Pins the protocol-wide ID-derivation formula against silent changes. A switch to
    ///      `abi.encodePacked` or a different argument order would change every condition,
    ///      event, and position ID in the system; this test makes that change loud at unit
    ///      scope instead of waiting for a downstream snapshot to drift.
    function test_computeBaseHash(uint256 _moduleId, bytes calldata _data) external pure {
        assertEq(computeBaseHash(_moduleId, _data), keccak256(abi.encode(_moduleId, _data)));
    }
}

/*--------------------------------------------------------------
                     EQUALITY OPERATORS
--------------------------------------------------------------*/

contract IdsTest_conditionEq is IdsTest {
    /// @notice The `==` operator on ConditionId is reflexive.
    function test_conditionEq_reflexive(bytes32 _raw) external pure {
        ConditionId id = ConditionIdLib.from(_maskConditionId(_raw));
        assertTrue(id == id);
        assertFalse(id != id);
    }

    /// @notice The `==` operator returns false for distinct canonical ConditionIds.
    function test_conditionEq_distinct(bytes32 _a, bytes32 _b) external pure {
        vm.assume(_maskConditionId(_a) != _maskConditionId(_b));
        ConditionId a = ConditionIdLib.from(_maskConditionId(_a));
        ConditionId b = ConditionIdLib.from(_maskConditionId(_b));
        assertFalse(a == b);
        assertTrue(a != b);
    }
}

contract IdsTest_eventEq is IdsTest {
    /// @notice The `==` operator on EventId is reflexive.
    function test_eventEq_reflexive(bytes32 _raw) external pure {
        EventId id = EventIdLib.from(_maskEventId(_raw));
        assertTrue(id == id);
        assertFalse(id != id);
    }

    /// @notice The `==` operator returns false for distinct canonical EventIds.
    function test_eventEq_distinct(bytes32 _a, bytes32 _b) external pure {
        vm.assume(_maskEventId(_a) != _maskEventId(_b));
        EventId a = EventIdLib.from(_maskEventId(_a));
        EventId b = EventIdLib.from(_maskEventId(_b));
        assertFalse(a == b);
        assertTrue(a != b);
    }
}

contract IdsTest_positionEq is IdsTest {
    /// @notice The `==` operator on PositionId is reflexive.
    function test_positionEq_reflexive(uint256 _raw) external pure {
        PositionId id = PositionId.wrap(_raw);
        assertTrue(id == id);
        assertFalse(id != id);
    }

    /// @notice The `==` operator returns false for distinct PositionIds.
    function test_positionEq_distinct(uint256 _a, uint256 _b) external pure {
        vm.assume(_a != _b);
        PositionId a = PositionId.wrap(_a);
        PositionId b = PositionId.wrap(_b);
        assertFalse(a == b);
        assertTrue(a != b);
    }
}

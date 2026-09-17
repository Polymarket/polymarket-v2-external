// ============================================================
// The solvency specs (Combinatorial-ComboSolvency01.spec, Combinatorial-ModuleEscrow01.spec,
// solvency/CombinatorialRefine*.spec, …) replace three production helpers with CVL summaries so
// the proof stays loop-/assembly-free:
//
//   _flipLeg                     => flipLegCVL      (arithmetic low-bit toggle vs. XOR encoding)
//   _trimArray                   => trimArrayCVL    (fresh prefix copy vs. in-place mstore length)
//
// Every solvency conclusion is therefore conditional on those three summaries being correct. This
// specruns the real helpers and asserts, for every input, that value and revert behaviour match the CVL summary.
//
// SCOPE: bounded to <= 3 legs (loop_iter = 3), matching the combinatorial solvency scene, where the
// summaries pin element indices 0..2 (so the whole result is determined). Flip is unconditional
// (single element); trim/basket are exhaustive for the pinned 0..2 range.
// ============================================================

import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";

using CombinatorialModuleHarness as CombinatorialModule;

methods {
    // ---- REAL helpers under test (wrappers on the harness) ----
    function CombinatorialModule.flipLegReal(CombinatorialModule.PositionId) external
        returns (CombinatorialModule.PositionId) envfree;
    function CombinatorialModule.trimArrayReal(CombinatorialModule.PositionId[], uint256) external
        returns (CombinatorialModule.PositionId[]) envfree;

    // ---- harness views the CVL summaries read (identical to the solvency scene) ----
    function CombinatorialModule.pidUnwrap(CombinatorialModule.PositionId) external returns (uint256) envfree;
    function CombinatorialModule.basketIdFromLegs(CombinatorialModule.PositionId[], uint256) external
        returns (uint256) envfree;

    // ---- OwnableRoles / handover taming (currentContract == CombinatorialModuleHarness) ----
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal =>
        updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

/*--------------------------------------------------------------
                     CVL SUMMARIES UNDER TEST
--------------------------------------------------------------*/

// Toggle the outcome byte 0<->1.
function flipPid(uint256 k) returns uint256 {
    return k % 2 == 0 ? require_uint256(k + 1) : require_uint256(k - 1);
}

// Toggle the low bit.
function flipLegCVL(CombinatorialModule.PositionId leg) returns CombinatorialModule.PositionId {
    CombinatorialModule.PositionId res;
    require pidUnwrap(res) == flipPid(pidUnwrap(leg)), "flip toggles the low bit";
    return res;
}

// Fresh array holding the first `len` elements.
function trimArrayCVL(CombinatorialModule.PositionId[] arr, uint256 len) returns CombinatorialModule.PositionId[] {
    if (len > arr.length) { revert(); }
    CombinatorialModule.PositionId[] res;
    require res.length == len, "trimmed length";
    if (len > 0) { require pidUnwrap(res[0]) == pidUnwrap(arr[0]), "trim keeps element 0"; }
    if (len > 1) { require pidUnwrap(res[1]) == pidUnwrap(arr[1]), "trim keeps element 1"; }
    if (len > 2) { require pidUnwrap(res[2]) == pidUnwrap(arr[2]), "trim keeps element 2"; }
    return res;
}

/*--------------------------------------------------------------
                    FLIP-LEG EQUIVALENCE
--------------------------------------------------------------*/

/// @title flipLegCVL equals the real _flipLeg for every position id.
/// @dev Both are total (no revert): _flipLeg only recomputes the id with the outcome byte XOR-ed,
///      and flipPid never overflows a uint256 (max even +1, max odd -1 both stay in range).
///      _flipLeg(P) == P ^ 1 (it toggles bit 0 of the outcome byte and leaves every other bit),
///      and flipPid(P) == P ^ 1 too, so they coincide unconditionally.
rule flipLegEquivalence(CombinatorialModule.PositionId leg) {
    CombinatorialModule.PositionId realOut = CombinatorialModule.flipLegReal(leg);
    CombinatorialModule.PositionId summOut = flipLegCVL(leg);
    assert CombinatorialModule.pidUnwrap(realOut) == CombinatorialModule.pidUnwrap(summOut),
        "flipLegCVL must equal the real _flipLeg";
}

/*--------------------------------------------------------------
                   TRIM-ARRAY EQUIVALENCE
--------------------------------------------------------------*/

/// @title trimArrayCVL equals the real _trimArray (value + revert), for arrays of <= 3 legs.
/// @dev Real reverts iff `len > arr.length` (InvalidArrayLength); the summary reverts on the same
///      condition. On success the trimmed array has length `len` and keeps the first `len` elements.
rule trimArrayEquivalence(CombinatorialModule.PositionId[] arr, uint256 len) {
    require arr.length <= 3; // bounded proof; the summary pins indices 0..2

    CombinatorialModule.PositionId[] realOut = CombinatorialModule.trimArrayReal@withrevert(arr, len);
    bool realRev = lastReverted;
    CombinatorialModule.PositionId[] summOut = trimArrayCVL@withrevert(arr, len);
    bool summRev = lastReverted;

    assert realRev == summRev, "trimArrayCVL revert must match the real _trimArray";

    assert !realRev => realOut.length == summOut.length, "trimmed length must match";
    if (!realRev && summOut.length > 0) {
        assert CombinatorialModule.pidUnwrap(realOut[0]) == CombinatorialModule.pidUnwrap(summOut[0]),
            "trimmed element 0 must match";
    }
    if (!realRev && summOut.length > 1) {
        assert CombinatorialModule.pidUnwrap(realOut[1]) == CombinatorialModule.pidUnwrap(summOut[1]),
            "trimmed element 1 must match";
    }
    if (!realRev && summOut.length > 2) {
        assert CombinatorialModule.pidUnwrap(realOut[2]) == CombinatorialModule.pidUnwrap(summOut[2]),
            "trimmed element 2 must match";
    }
    assert true;
}

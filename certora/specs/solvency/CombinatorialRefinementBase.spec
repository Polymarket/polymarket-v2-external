import "../summaries/CombinatorialModule_base_summaries.spec";
import "../summaries/Solady/OwnableRoles.spec";
import "../summaries/Solady/UUPSUpgradeable.spec";
import "../summaries/CTFHelpers_summaries.spec";
import "../summaries/muldiv.spec";
import "../summaries/CombinatorialPayout_summaries.spec";

// ============================================================
// Shared base for the CombinatorialModule refinement-family solvency specs.
// ============================================================

using CombinatorialModule as CombinatorialModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;

links {
    CombinatorialModule.POSITION_MANAGER => PositionManager;
    CombinatorialModule.COLLATERAL_TOKEN => CollateralToken;
    PositionManager.COLLATERAL_TOKEN => CollateralToken;
    PositionManager.moduleById[_] => [CombinatorialModule];
}

methods {
    // ---- Combinatorial harness views ----
    function CombinatorialModule.isWellFormed(uint256) external returns (bool) envfree;
    function CombinatorialModule.isCanonical(uint256) external returns (bool) envfree;

    function _.moduleId() external => DISPATCHER(true);

    // ---- Payout summaries ----
    function CombinatorialModule._getConditionPayout(CombinatorialModule.PositionId _leg)
        internal returns (bool, uint256) => condPayoutCVL(_leg);
    function CombinatorialModule._getPositionPayout(CombinatorialModule.PositionId _positionId, uint256 _amount)
        internal returns (uint256) with (env e) => positionPayoutCVL(e, _positionId, _amount);
    function CombinatorialModule._trimArray(CombinatorialModule.PositionId[] memory arr, uint256 len)
        internal returns (CombinatorialModule.PositionId[] memory) => trimArrayCVL(arr, len);

    // ---- OwnableRoles ----
    function _.hasAnyRole(address user, uint256 roles) internal =>
        hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal =>
        hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal =>
        rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) =>
        checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal =>
        setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal =>
        updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal =>
        ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// Model of _trimArray: arr truncated to its first `len`.
function trimArrayCVL(CombinatorialModule.PositionId[] arr, uint256 len) returns CombinatorialModule.PositionId[] {
    require len <= arr.length;
    CombinatorialModule.PositionId[] res;
    require res.length == len;
    if (len > 0) { require res[0] == arr[0]; }
    if (len > 1) { require res[1] == arr[1]; }
    return res;
}
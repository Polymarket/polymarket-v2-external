// Burn and balance-read summaries (ERC1155Burn.spec / ERC1155Reads.spec) are
// deliberately NOT imported: burn/batchBurn and balanceOf run their real bodies
// here, which the prover handles fine (proven by the solvency integrity rules).
// `using` aliases for this scene are owned by PositionManager_call_resolution.spec.
import "summaries/Solady/ERC1155.spec";
import "summaries/PositionManager_base_summaries.spec";
import "summaries/PositionManager_call_resolution.spec";
import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";
import "summaries/Solady/SafeTransferLib.spec";
import "summaries/CTFHelpers_summaries.spec";

methods {
    // function OwnableRoles.hasAnyRole(address user, uint256 roles) internal returns bool =>
    //     hasAnyRoleCVL(currentContract, user, roles);
    // function OwnableRoles.hasAllRoles(address user, uint256 roles) internal returns bool =>
    //     hasAllRolesCVL(currentContract, user, roles);
    // function OwnableRoles.rolesOf(address user) internal returns uint256 =>
    //     rolesOfCVL(currentContract, user);
    // function OwnableRoles._checkRoles(uint256 roles) internal with (env e) =>
    //     checkRolesCVL(e, currentContract, roles);
    // function OwnableRoles._setRoles(address user, uint256 roles) internal =>
    //     setRolesCVL(currentContract, user, roles);
    // function OwnableRoles._updateRoles(address user, uint256 roles, bool on) internal =>
    //     updateRolesCVL(currentContract, user, roles, on);
    // function Ownable.ownershipHandoverExpiresAt(address pendingOwner) internal returns uint256 =>
    //     ownershipHandoverExpiresAtCVL(currentContract, pendingOwner);


    function _.hasAnyRole(address user, uint256 roles) internal =>
        hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal =>
        hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal=>
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

//use builtin rule sanity;

// turns out some codes do have an 'f'! e.g. Cork
rule sanity {
    env e;
    calldataarg args;
    method certoraF;
    certoraF(e, args);
    satisfy true, "sanity check failed";
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";
import { Ownable } from "@solady/src/auth/Ownable.sol";

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";
import { InitializableRoles } from "@polymarket-v2/src/auth/InitializableRoles.sol";
import { Collateral, CollateralSetup } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { IPositionManagerModule } from "@polymarket-v2/src/positionManager/IPositionManagerModule.sol";
import {
    PositionManager,
    PositionManagerErrors,
    PositionManagerEvents
} from "@polymarket-v2/src/positionManager/PositionManager.sol";

contract ModuleMock is IPositionManagerModule, ERC1155TokenReceiver {
    PositionManager public immutable positionManager;

    uint256 public constant MODULE_ID = 99; // Test module ID

    constructor(address _positionManager) {
        positionManager = PositionManager(_positionManager);
    }

    function moduleId() external pure returns (uint256) {
        return MODULE_ID;
    }

    /// @notice Convert arbitrary data hash to a structured condition ID with MODULE_ID
    function getConditionId(bytes32 _dataHash) public pure returns (ConditionId) {
        return ConditionIdLib.encode(MODULE_ID, _dataHash, 0, 0);
    }

    function getPositionId(ConditionId _conditionId, uint256 _outcomeIndex) public pure returns (PositionId) {
        return ConditionIdLib.computePositionId(_conditionId, _outcomeIndex);
    }

    function getPayout(
        PositionId,
        /* _positionId */
        uint256 /* _amount */
    )
        public
        pure
        returns (uint256)
    {
        return 0;
    }

    /// @notice Prepare condition - takes arbitrary data hash, creates structured conditionId
    /// @dev No longer calls PM - modules track their own state
    function prepareCondition(bytes32 _dataHash) external returns (ConditionId) {
        return getConditionId(_dataHash);
    }

    function resolveCondition(bytes32 _conditionId, uint256[] calldata _result) external { }

    function split(address[] calldata _to, bytes32 _conditionId, uint256 _amount) external {
        ConditionId conditionId = ConditionId.wrap(bytes31(_conditionId));
        PositionId YesPositionId = getPositionId(conditionId, 0);
        PositionId NoPositionId = getPositionId(conditionId, 1);

        positionManager.mint(_to[0], YesPositionId, _amount);
        positionManager.mint(_to[1], NoPositionId, _amount);
    }

    function merge(address _to, bytes32 _conditionId, uint256 _amount) external {
        ConditionId conditionId = ConditionId.wrap(bytes31(_conditionId));
        PositionId yesPositionId = getPositionId(conditionId, 0);
        PositionId noPositionId = getPositionId(conditionId, 1);

        positionManager.burn(yesPositionId, _amount);
        positionManager.burn(noPositionId, _amount);
    }

    function redeem(address _to, uint256 _positionId, uint256 _amount) external {
        PositionId positionId = PositionId.wrap(_positionId);
        positionManager.burn(positionId, _amount);
    }
}

/// @notice Mock module returning a specific moduleId (used by coverage tests)
contract ModuleMock2 is IPositionManagerModule, ERC1155TokenReceiver {
    PositionManager public immutable positionManager;
    uint256 public constant MODULE_ID = 99;

    constructor(address _positionManager) {
        positionManager = PositionManager(_positionManager);
    }

    function moduleId() external pure returns (uint256) {
        return MODULE_ID;
    }

    function getConditionId(bytes32 _dataHash) public pure returns (ConditionId) {
        return ConditionIdLib.encode(MODULE_ID, _dataHash, 0, 0);
    }

    function getPositionId(ConditionId _conditionId, uint256 _outcomeIndex) public pure returns (uint256) {
        return PositionId.unwrap(ConditionIdLib.computePositionId(_conditionId, _outcomeIndex));
    }

    function getPayout(PositionId, uint256) public pure returns (uint256) {
        return 0;
    }

    function prepareCondition(bytes32 _dataHash) external returns (ConditionId) {
        return getConditionId(_dataHash);
    }

    function mint(address _to, uint256 _positionId, uint256 _amount) external {
        positionManager.mint(_to, PositionId.wrap(_positionId), _amount);
    }

    function batchMint(address _to, uint256[] calldata _positionIds, uint256[] calldata _amounts) external {
        PositionId[] calldata pIds;
        assembly {
            pIds.offset := _positionIds.offset
            pIds.length := _positionIds.length
        }
        positionManager.batchMint(_to, pIds, _amounts);
    }

    function burn(uint256 _positionId, uint256 _amount) external {
        positionManager.burn(PositionId.wrap(_positionId), _amount);
    }

    function batchBurn(uint256[] calldata _positionIds, uint256[] calldata _amounts) external {
        PositionId[] calldata pIds;
        assembly {
            pIds.offset := _positionIds.offset
            pIds.length := _positionIds.length
        }
        positionManager.batchBurn(pIds, _amounts);
    }
}

/// @notice Mock module returning a different ID
contract ModuleMockId0 is IPositionManagerModule, ERC1155TokenReceiver {
    function moduleId() external pure returns (uint256) {
        return 0;
    }

    function getPayout(PositionId, uint256) public pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock contract that inherits InitializableRoles and uses
///         the onlyOperator and onlyCreator modifiers.
///         This is needed because PositionManager inherits InitializableRoles
///         but never gates any function with these two modifiers directly.
contract InitializableRolesMock is InitializableRoles {
    uint256 public operatorCalled;
    uint256 public creatorCalled;

    function init(address _owner, address _admin) external {
        _initializeOwner(_owner);
        _grantRoles(_admin, _ROLE_0);
    }

    /// @dev Gated by onlyOperator modifier
    function operatorAction() external onlyOperator {
        operatorCalled++;
    }

    /// @dev Gated by onlyCreator modifier
    function creatorAction() external onlyCreator {
        creatorCalled++;
    }
}

contract PositionManagerTest is TestHelper {
    error Unauthorized();

    Collateral collateral;
    PositionManager positionManager;
    ModuleMock moduleMock;

    function setUp() public virtual {
        collateral = CollateralSetup._deploy(owner);

        address positionManagerImplementation = address(new PositionManager(address(collateral.token)));
        address positionManagerProxy = LibClone.deployERC1967(positionManagerImplementation);

        vm.label(positionManagerImplementation, "PositionManagerImplementation");
        vm.label(positionManagerProxy, "PositionManager");

        positionManager = PositionManager(positionManagerProxy);
        positionManager.initialize(owner, admin);

        moduleMock = new ModuleMock(address(positionManager));

        vm.startPrank(admin);
        positionManager.addModule(address(moduleMock));
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                         DEPLOYMENT
--------------------------------------------------------------*/

contract PositionManagerTest_deployment is PositionManagerTest {
    function test_deployment() public view {
        assertEq(positionManager.hasAllRoles(admin, 1), true);
        // Module is registered if moduleById returns its address
        assertEq(positionManager.moduleById(moduleMock.MODULE_ID()), address(moduleMock));
    }
}

/*--------------------------------------------------------------
                           MODULE
--------------------------------------------------------------*/

contract PositionManagerTest_module is PositionManagerTest {
    function test_prepareCondition() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        // Module is derivable from conditionId bits
        uint256 modId = ConditionIdLib.moduleId(conditionId);
        assertEq(positionManager.moduleById(modId), address(moduleMock));
    }

    function test_resolveCondition() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        uint256[] memory result = new uint256[](2);
        result[0] = 1;
        result[1] = 0;

        moduleMock.resolveCondition(ConditionId.unwrap(conditionId), result);
    }

    function test_removeModule() public {
        uint256 moduleId_ = moduleMock.MODULE_ID();

        // Verify module is registered
        assertEq(positionManager.moduleById(moduleId_), address(moduleMock));

        // Admin removes the module
        vm.prank(admin);
        positionManager.removeModule(moduleId_);

        // Verify module is no longer registered
        assertEq(positionManager.moduleById(moduleId_), address(0));
    }

    function test_revert_removeModule_unauthorized() public {
        uint256 moduleId_ = moduleMock.MODULE_ID();

        // Alice (non-admin) tries to remove module
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.removeModule(moduleId_);
    }

    function test_revert_split_moduleNotRegistered() public {
        // Try to split on an unprepared condition (no module registered)
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        // Canonical condition ID (outcome byte zero) so the wrap doesn't pre-empt the expected
        // revert.
        bytes32 unpreparedCondition = bytes32(uint256(999) << 8);

        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        moduleMock.split(to, unpreparedCondition, 100);
    }
}

/*--------------------------------------------------------------
                            SPLIT
--------------------------------------------------------------*/

contract PositionManagerTest_split is PositionManagerTest {
    function test_split() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = brian;

        moduleMock.split(to, ConditionId.unwrap(conditionId), 100);

        uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        uint256 positionId1 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        assertEq(positionManager.balanceOf(alice, positionId0), 100);
        assertEq(positionManager.balanceOf(brian, positionId1), 100);
    }
}

/*--------------------------------------------------------------
                            MERGE
--------------------------------------------------------------*/

contract PositionManagerTest_merge is PositionManagerTest {
    function test_merge() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        moduleMock.split(to, ConditionId.unwrap(conditionId), 100);

        uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        uint256 positionId1 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        vm.startPrank(alice);
        positionManager.safeTransferFrom(alice, address(moduleMock), positionId0, 100, "");
        positionManager.safeTransferFrom(alice, address(moduleMock), positionId1, 100, "");
        vm.stopPrank();

        moduleMock.merge(alice, ConditionId.unwrap(conditionId), 100);
    }
}

/*--------------------------------------------------------------
                           REDEEM
--------------------------------------------------------------*/

contract PositionManagerTest_redeem is PositionManagerTest {
    function test_redeem() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        moduleMock.split(to, ConditionId.unwrap(conditionId), 100);

        uint256[] memory result = new uint256[](2);
        result[0] = 1;
        result[1] = 0;

        uint256 positionId0 = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));

        vm.startPrank(alice);
        positionManager.safeTransferFrom(alice, address(moduleMock), positionId0, 100, "");
        vm.stopPrank();

        moduleMock.resolveCondition(ConditionId.unwrap(conditionId), result);
        moduleMock.redeem(alice, positionId0, 100);
    }
}

/*--------------------------------------------------------------
                            VIEW
--------------------------------------------------------------*/

contract PositionManagerTest_view is PositionManagerTest {
    function test_getPositionId() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        uint256 positionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        uint256 expectedPositionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));

        assertEq(positionId, expectedPositionId);
    }

    function test_getPayout() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        PositionId positionId = ConditionIdLib.computePositionId(conditionId, 0);
        uint256 payout = positionManager.getPayout(positionId, 100);
        // ModuleMock always returns 0 for getPayout
        assertEq(payout, 0);
    }

    function test_balanceOf_conditionId() public {
        bytes32 dataHash = bytes32(0);
        ConditionId conditionId = moduleMock.getConditionId(dataHash);

        vm.startPrank(admin);
        moduleMock.prepareCondition(dataHash);
        vm.stopPrank();

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        moduleMock.split(to, ConditionId.unwrap(conditionId), 100);

        uint256 balance = positionManager.balanceOf(alice, conditionId, 0);
        assertEq(balance, 100);
    }
}

/*--------------------------------------------------------------
                           ROLES
--------------------------------------------------------------*/

contract PositionManagerTest_roles is PositionManagerTest {
    // Solady's RolesUpdated event
    event RolesUpdated(address indexed user, uint256 indexed roles);

    // Solady role constants: _ROLE_0 = 1, _ROLE_1 = 2, _ROLE_2 = 4
    uint256 internal constant ADMIN_ROLE = 1 << 0; // _ROLE_0 = 1
    uint256 internal constant OPERATOR_ROLE = 1 << 1; // _ROLE_1 = 2
    uint256 internal constant CREATOR_ROLE = 1 << 2; // _ROLE_2 = 4

    // --- addAdmin ---

    function test_addAdmin() public {
        // Verify alice does not have admin role before granting
        assertFalse(positionManager.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with the new roles bitmap for alice
        vm.expectEmit(true, true, true, true, address(positionManager));
        emit RolesUpdated(alice, ADMIN_ROLE);

        // Owner grants admin role to alice
        vm.prank(owner);
        positionManager.addAdmin(alice);

        // Verify alice now holds the admin role
        assertTrue(positionManager.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(positionManager.rolesOf(alice), ADMIN_ROLE);
    }

    // --- removeAdmin ---

    function test_removeAdmin() public {
        // First grant admin role to alice
        vm.prank(owner);
        positionManager.addAdmin(alice);
        assertTrue(positionManager.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with 0 roles (all roles removed)
        vm.expectEmit(true, true, true, true, address(positionManager));
        emit RolesUpdated(alice, 0);

        // Admin revokes admin role from alice
        vm.prank(admin);
        positionManager.removeAdmin(alice);

        // Verify alice no longer holds the admin role
        assertFalse(positionManager.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(positionManager.rolesOf(alice), 0);
    }

    // --- addOperator ---

    function test_addOperator() public {
        // Verify alice does not have operator role before granting
        assertFalse(positionManager.hasAnyRole(alice, OPERATOR_ROLE));

        // Expect the RolesUpdated event with the operator role bitmap
        vm.expectEmit(true, true, true, true, address(positionManager));
        emit RolesUpdated(alice, OPERATOR_ROLE);

        // Admin grants operator role to alice
        vm.prank(admin);
        positionManager.addOperator(alice);

        // Verify alice now holds the operator role
        assertTrue(positionManager.hasAnyRole(alice, OPERATOR_ROLE));
        assertEq(positionManager.rolesOf(alice), OPERATOR_ROLE);
    }

    // --- removeOperator ---

    function test_removeOperator() public {
        // First grant operator role to alice
        vm.prank(admin);
        positionManager.addOperator(alice);
        assertTrue(positionManager.hasAnyRole(alice, OPERATOR_ROLE));

        // Expect the RolesUpdated event with 0 roles
        vm.expectEmit(true, true, true, true, address(positionManager));
        emit RolesUpdated(alice, 0);

        // Admin revokes operator role from alice
        vm.prank(admin);
        positionManager.removeOperator(alice);

        // Verify alice no longer holds the operator role
        assertFalse(positionManager.hasAnyRole(alice, OPERATOR_ROLE));
        assertEq(positionManager.rolesOf(alice), 0);
    }

    // --- addCreator ---

    function test_addCreator() public {
        // Verify alice does not have creator role before granting
        assertFalse(positionManager.hasAnyRole(alice, CREATOR_ROLE));

        // Expect the RolesUpdated event with the creator role bitmap
        vm.expectEmit(true, true, true, true, address(positionManager));
        emit RolesUpdated(alice, CREATOR_ROLE);

        // Admin grants creator role to alice
        vm.prank(admin);
        positionManager.addCreator(alice);

        // Verify alice now holds the creator role
        assertTrue(positionManager.hasAnyRole(alice, CREATOR_ROLE));
        assertEq(positionManager.rolesOf(alice), CREATOR_ROLE);
    }

    // --- removeCreator ---

    function test_removeCreator() public {
        // First grant creator role to alice
        vm.prank(admin);
        positionManager.addCreator(alice);
        assertTrue(positionManager.hasAnyRole(alice, CREATOR_ROLE));

        // Expect the RolesUpdated event with 0 roles
        vm.expectEmit(true, true, true, true, address(positionManager));
        emit RolesUpdated(alice, 0);

        // Admin revokes creator role from alice
        vm.prank(admin);
        positionManager.removeCreator(alice);

        // Verify alice no longer holds the creator role
        assertFalse(positionManager.hasAnyRole(alice, CREATOR_ROLE));
        assertEq(positionManager.rolesOf(alice), 0);
    }

    // --- revert: unauthorized addAdmin ---

    function test_revert_addAdmin_unauthorized() public {
        // Alice (non-owner) tries to add brian as admin
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.addAdmin(brian);

        // Verify brian was not granted the admin role
        assertFalse(positionManager.hasAnyRole(brian, ADMIN_ROLE));
    }

    // --- revert: existing admin cannot grant admin (owner-only invariant) ---

    function test_revert_addAdmin_byAdmin() public {
        // An existing admin must not be able to propagate the admin role;
        // only the contract owner can grant it.
        vm.prank(admin);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.addAdmin(brian);

        // Verify brian was not granted the admin role
        assertFalse(positionManager.hasAnyRole(brian, ADMIN_ROLE));
    }

    // --- revert: unauthorized addOperator ---

    function test_revert_addOperator_unauthorized() public {
        // Alice (non-admin) tries to add brian as operator
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.addOperator(brian);

        // Verify brian was not granted the operator role
        assertFalse(positionManager.hasAnyRole(brian, OPERATOR_ROLE));
    }

    // --- revert: unauthorized addCreator ---

    function test_revert_addCreator_unauthorized() public {
        // Alice (non-admin) tries to add brian as creator
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.addCreator(brian);

        // Verify brian was not granted the creator role
        assertFalse(positionManager.hasAnyRole(brian, CREATOR_ROLE));
    }
}

/*--------------------------------------------------------------
              MODIFIER BRANCHES - onlyModuleByPositionId
--------------------------------------------------------------*/

contract PositionManagerTest_coverageBase is TestHelper, PositionManagerErrors, PositionManagerEvents {
    error Unauthorized();
    error TransferToZeroAddress();
    error ArrayLengthsMismatch();

    Collateral collateral;
    PositionManager positionManager;
    ModuleMock2 moduleMock;

    function setUp() public virtual {
        collateral = CollateralSetup._deploy(owner);

        address positionManagerImplementation = address(new PositionManager(address(collateral.token)));
        address positionManagerProxy = LibClone.deployERC1967(positionManagerImplementation);

        positionManager = PositionManager(positionManagerProxy);
        positionManager.initialize(owner, admin);

        moduleMock = new ModuleMock2(address(positionManager));

        vm.prank(admin);
        positionManager.addModule(address(moduleMock));
    }
}

/// @notice Tests for onlyModuleByPositionId modifier (Unauthorized branch)
contract PositionManagerTest_moduleAuth is PositionManagerTest_coverageBase {
    // Test mint from non-module address (onlyModuleByPositionId Unauthorized)
    function test_revert_mint_unauthorized() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        PositionId positionId = ConditionIdLib.computePositionId(conditionId, 0);

        // Non-module tries to mint
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.mint(alice, positionId, 100);
    }

    // Test burn from non-module address (onlyModuleByPositionId Unauthorized)
    function test_revert_burn_unauthorized() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        PositionId positionId = ConditionIdLib.computePositionId(conditionId, 0);

        // Non-module tries to burn
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.burn(positionId, 100);
    }

    // Test batchMint from non-module address (onlyModuleByPositionIds Unauthorized)
    function test_revert_batchMint_unauthorized() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        PositionId[] memory ids = new PositionId[](2);
        ids[0] = ConditionIdLib.computePositionId(conditionId, 0);
        ids[1] = ConditionIdLib.computePositionId(conditionId, 1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 100;

        // Non-module tries to batch mint
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.batchMint(alice, ids, amounts);
    }

    // Test batchBurn from non-module address (onlyModuleByPositionIds Unauthorized)
    function test_revert_batchBurn_unauthorized() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        PositionId[] memory ids = new PositionId[](2);
        ids[0] = ConditionIdLib.computePositionId(conditionId, 0);
        ids[1] = ConditionIdLib.computePositionId(conditionId, 1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 100;

        // Non-module tries to batch burn
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        positionManager.batchBurn(ids, amounts);
    }
}

/*--------------------------------------------------------------
              ADD MODULE EDGE CASES
--------------------------------------------------------------*/

/// @notice Tests for addModule edge cases
contract PositionManagerTest_addModule is PositionManagerTest_coverageBase {
    // Test adding a module with moduleId = 0
    function test_revert_addModule_invalidModuleId() public {
        ModuleMockId0 badModule = new ModuleMockId0();

        vm.prank(admin);
        vm.expectRevert(PositionManagerErrors.InvalidModuleId.selector);
        positionManager.addModule(address(badModule));
    }

    // Test adding a module that is already registered
    function test_revert_addModule_alreadyRegistered() public {
        vm.prank(admin);
        vm.expectRevert(PositionManagerErrors.ModuleAlreadyRegistered.selector);
        positionManager.addModule(address(moduleMock));
    }

    // Test removeModule for non-existent module
    function test_revert_removeModule_notRegistered() public {
        vm.prank(admin);
        vm.expectRevert(PositionManagerErrors.ModuleNotRegistered.selector);
        positionManager.removeModule(999);
    }
}

/*--------------------------------------------------------------
              UUPS UPGRADE AUTHORIZATION
--------------------------------------------------------------*/

/// @notice Tests for _authorizeUpgrade (onlyOwner guard)
contract PositionManagerTest_upgrade is PositionManagerTest_coverageBase {
    function test_upgradeToAndCall() public {
        address newImpl = address(new PositionManager(address(collateral.token)));

        vm.prank(owner);
        positionManager.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(new PositionManager(address(collateral.token)));

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        positionManager.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
              GET PAYOUT - MODULE NOT REGISTERED
--------------------------------------------------------------*/

/// @notice Tests for getPayout with unregistered module (ModuleNotRegistered)
contract PositionManagerTest_getPayout is PositionManagerTest_coverageBase {
    function test_revert_getPayout_moduleNotRegistered() public {
        // Create a position ID with a non-registered module ID
        PositionId positionId = ConditionIdLib.encode(200, bytes32(0), 0, 0).computePositionId(0);

        vm.expectRevert(PositionManagerErrors.ModuleNotRegistered.selector);
        positionManager.getPayout(positionId, 100);
    }
}

/*--------------------------------------------------------------
              URI VIEW FUNCTION
--------------------------------------------------------------*/

/// @notice Tests for uri() view function
contract PositionManagerTest_uri is PositionManagerTest_coverageBase {
    string internal constant _EXPECTED_URI = "https://polymarket.com/position/{id}";

    // Returns the ERC-1155 templated URI for a position whose module is registered
    function test_uri_returnsTemplate() public view {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        uint256 positionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        string memory result = positionManager.uri(positionId);
        assertEq(result, _EXPECTED_URI);
    }

    // Reverts when the position ID references a module that is not registered
    function test_revert_uri_moduleNotRegistered() public {
        // Encode a position ID whose top 8 bits point to an unregistered module
        uint256 positionId = PositionId.unwrap(ConditionIdLib.encode(200, bytes32(0), 0, 0).computePositionId(0));

        vm.expectRevert(PositionManagerErrors.ModuleNotRegistered.selector);
        positionManager.uri(positionId);
    }
}

/*--------------------------------------------------------------
         INITIALIZABLE ROLES - onlyOperator / onlyCreator
--------------------------------------------------------------*/

/// @notice Tests that exercise the onlyOperator and onlyCreator modifiers
contract PositionManagerTest_initRoles is TestHelper {
    InitializableRolesMock mock;

    function setUp() public {
        mock = new InitializableRolesMock();
        mock.init(owner, admin);

        // Grant operator and creator roles
        vm.startPrank(admin);
        mock.addOperator(alice);
        mock.addCreator(brian);
        vm.stopPrank();
    }

    // onlyOperator success path
    function test_operatorAction_success() public {
        vm.prank(alice);
        mock.operatorAction();
        assertEq(mock.operatorCalled(), 1);
    }

    // onlyOperator revert path
    function test_revert_operatorAction_unauthorized() public {
        vm.prank(brian); // brian is creator, not operator
        vm.expectRevert(Ownable.Unauthorized.selector);
        mock.operatorAction();
    }

    // onlyCreator success path
    function test_creatorAction_success() public {
        vm.prank(brian);
        mock.creatorAction();
        assertEq(mock.creatorCalled(), 1);
    }

    // onlyCreator revert path
    function test_revert_creatorAction_unauthorized() public {
        vm.prank(alice); // alice is operator, not creator
        vm.expectRevert(Ownable.Unauthorized.selector);
        mock.creatorAction();
    }
}

/*--------------------------------------------------------------
      POSITION MANAGER - BALANCE OVERFLOW (ASSEMBLY BRANCHES)
--------------------------------------------------------------*/

/// @notice Documents that the AccountBalanceOverflow checks in
///         unsafeTransferFrom / unsafeBatchTransferFrom are assembly overflow
///         guards: `if lt(toBalanceAfter, toBalanceBefore)`.
///         These require transferring enough tokens to overflow a uint256 balance,
///         which is infeasible in practice. Forge coverage cannot track
///         assembly branches reliably. These lines are SKIPPED.

/*--------------------------------------------------------------
              CROSS-MODULE AUTHORIZATION
--------------------------------------------------------------*/

/// @notice Mock module with a different ID (100) for cross-module testing
contract CrossModuleMock is IPositionManagerModule, ERC1155TokenReceiver {
    PositionManager public immutable positionManager;
    uint256 public constant MODULE_ID = 100;

    constructor(address _positionManager) {
        positionManager = PositionManager(_positionManager);
    }

    function moduleId() external pure returns (uint256) {
        return MODULE_ID;
    }

    function getPayout(PositionId, uint256) public pure returns (uint256) {
        return 0;
    }

    function mint(address _to, uint256 _positionId, uint256 _amount) external {
        positionManager.mint(_to, PositionId.wrap(_positionId), _amount);
    }

    function batchMint(address _to, uint256[] calldata _positionIds, uint256[] calldata _amounts) external {
        PositionId[] calldata pIds;
        assembly {
            pIds.offset := _positionIds.offset
            pIds.length := _positionIds.length
        }
        positionManager.batchMint(_to, pIds, _amounts);
    }

    function burn(uint256 _positionId, uint256 _amount) external {
        positionManager.burn(PositionId.wrap(_positionId), _amount);
    }

    function batchBurn(uint256[] calldata _positionIds, uint256[] calldata _amounts) external {
        PositionId[] calldata pIds;
        assembly {
            pIds.offset := _positionIds.offset
            pIds.length := _positionIds.length
        }
        positionManager.batchBurn(pIds, _amounts);
    }
}

contract PositionManagerTest_crossModuleBase is TestHelper, PositionManagerErrors, PositionManagerEvents {
    error Unauthorized();

    Collateral collateral;
    PositionManager positionManager;
    ModuleMock2 targetModule; // moduleId = 99
    CrossModuleMock crossModule; // moduleId = 100

    function setUp() public virtual {
        collateral = CollateralSetup._deploy(owner);

        address positionManagerImplementation = address(new PositionManager(address(collateral.token)));
        address positionManagerProxy = LibClone.deployERC1967(positionManagerImplementation);

        positionManager = PositionManager(positionManagerProxy);
        positionManager.initialize(owner, admin);

        targetModule = new ModuleMock2(address(positionManager));
        crossModule = new CrossModuleMock(address(positionManager));

        vm.startPrank(admin);
        positionManager.addModule(address(targetModule));
        positionManager.addModule(address(crossModule));
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
              SET CROSS-MODULE AUTH
--------------------------------------------------------------*/

contract PositionManagerTest_setCrossModuleAuth is PositionManagerTest_crossModuleBase {
    function test_setCrossModuleAuth() public {
        assertFalse(positionManager.crossModuleAuth(address(crossModule)));

        vm.expectEmit(true, true, true, true, address(positionManager));
        emit CrossModuleAuthSet(address(crossModule), true);

        vm.prank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), true);

        assertTrue(positionManager.crossModuleAuth(address(crossModule)));
    }

    function test_setCrossModuleAuth_revoke() public {
        vm.prank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), true);
        assertTrue(positionManager.crossModuleAuth(address(crossModule)));

        vm.expectEmit(true, true, true, true, address(positionManager));
        emit CrossModuleAuthSet(address(crossModule), false);

        vm.prank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), false);

        assertFalse(positionManager.crossModuleAuth(address(crossModule)));
    }

    function test_revert_setCrossModuleAuth_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        positionManager.setCrossModuleAuth(address(crossModule), true);
    }

    function test_revert_setCrossModuleAuth_moduleIdZero() public {
        // A contract that self-reports moduleId 0 is rejected by the registration check:
        // `moduleById[0]` is never written (addModule rejects moduleId 0), so the lookup
        // returns address(0) and fails the `moduleById[moduleId] == _module` invariant.
        ModuleMockId0 zeroModule = new ModuleMockId0();

        vm.prank(admin);
        vm.expectRevert(ModuleNotRegistered.selector);
        positionManager.setCrossModuleAuth(address(zeroModule), true);
    }

    function test_revert_setCrossModuleAuth_notRegistered() public {
        // Fresh instance whose self-reported moduleId points at the already-registered
        // `crossModule`, but whose own address is not `moduleById[100]`. Without the
        // registration check, an admin could authorize this impostor for cross-module
        // mint/burn.
        CrossModuleMock impostor = new CrossModuleMock(address(positionManager));
        assertTrue(address(impostor) != address(crossModule));

        vm.prank(admin);
        vm.expectRevert(ModuleNotRegistered.selector);
        positionManager.setCrossModuleAuth(address(impostor), true);
    }
}

/*--------------------------------------------------------------
              CROSS-MODULE MINT
--------------------------------------------------------------*/

contract PositionManagerTest_crossModuleMint is PositionManagerTest_crossModuleBase {
    function test_crossModuleMint() public {
        // crossModule (moduleId=100) mints a position belonging to targetModule (moduleId=99)
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256 positionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));

        // Verify this position belongs to targetModule, NOT crossModule
        assertEq(PositionId.wrap(positionId).moduleId(), targetModule.MODULE_ID());

        // Authorize crossModule for cross-module minting
        vm.prank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), true);

        // crossModule mints targetModule's position
        crossModule.mint(alice, positionId, 100);

        assertEq(positionManager.balanceOf(alice, positionId), 100);
    }

    function test_crossModuleBatchMint() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        ids[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        // Verify both positions belong to targetModule
        assertEq(PositionId.wrap(ids[0]).moduleId(), targetModule.MODULE_ID());
        assertEq(PositionId.wrap(ids[1]).moduleId(), targetModule.MODULE_ID());

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.prank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), true);

        crossModule.batchMint(alice, ids, amounts);

        assertEq(positionManager.balanceOf(alice, ids[0]), 100);
        assertEq(positionManager.balanceOf(alice, ids[1]), 200);
    }

    function test_revert_crossModuleMint_unauthorized() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256 positionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));

        // crossModule is NOT authorized — should revert
        vm.expectRevert(Unauthorized.selector);
        crossModule.mint(alice, positionId, 100);
    }

    function test_revert_crossModuleBatchMint_unauthorized() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        ids[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 100;

        // crossModule is NOT authorized — should revert
        vm.expectRevert(Unauthorized.selector);
        crossModule.batchMint(alice, ids, amounts);
    }
}

/*--------------------------------------------------------------
              CROSS-MODULE BURN
--------------------------------------------------------------*/

contract PositionManagerTest_crossModuleBurn is PositionManagerTest_crossModuleBase {
    function test_crossModuleBurn() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256 positionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));

        // Mint via targetModule (the owning module) to crossModule
        targetModule.mint(address(crossModule), positionId, 100);
        assertEq(positionManager.balanceOf(address(crossModule), positionId), 100);

        // Authorize crossModule for cross-module burn
        vm.prank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), true);

        // crossModule burns targetModule's position (held by crossModule)
        crossModule.burn(positionId, 100);

        assertEq(positionManager.balanceOf(address(crossModule), positionId), 0);
    }

    function test_crossModuleBatchBurn() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        ids[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        // Mint via targetModule to crossModule
        targetModule.mint(address(crossModule), ids[0], 100);
        targetModule.mint(address(crossModule), ids[1], 200);

        vm.prank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), true);

        crossModule.batchBurn(ids, amounts);

        assertEq(positionManager.balanceOf(address(crossModule), ids[0]), 0);
        assertEq(positionManager.balanceOf(address(crossModule), ids[1]), 0);
    }

    function test_revert_crossModuleBurn_unauthorized() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256 positionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));

        // Mint via targetModule to crossModule
        targetModule.mint(address(crossModule), positionId, 100);

        // crossModule is NOT authorized — should revert
        vm.expectRevert(Unauthorized.selector);
        crossModule.burn(positionId, 100);
    }

    function test_revert_crossModuleBatchBurn_unauthorized() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        ids[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 100;

        targetModule.mint(address(crossModule), ids[0], 100);
        targetModule.mint(address(crossModule), ids[1], 100);

        // crossModule is NOT authorized — should revert
        vm.expectRevert(Unauthorized.selector);
        crossModule.batchBurn(ids, amounts);
    }

    function test_crossModuleMint_revoked() public {
        ConditionId conditionId = targetModule.getConditionId(bytes32(0));
        uint256 positionId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));

        // Authorize then revoke
        vm.startPrank(admin);
        positionManager.setCrossModuleAuth(address(crossModule), true);
        positionManager.setCrossModuleAuth(address(crossModule), false);
        vm.stopPrank();

        // Should revert after revocation
        vm.expectRevert(Unauthorized.selector);
        crossModule.mint(alice, positionId, 100);
    }
}

/*--------------------------------------------------------------
                  UNSAFE MINT (NO RECEIVER CALLBACK)
--------------------------------------------------------------*/

/// @dev A contract that does NOT implement ERC1155TokenReceiver
contract MintNonReceiver { }

contract PositionManagerTest_unsafeMint is PositionManagerTest_coverageBase {
    function test_mintToNonReceiver() public {
        MintNonReceiver nonReceiver = new MintNonReceiver();
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        uint256 positionId = moduleMock.getPositionId(conditionId, 0);

        // Would revert with safeTransferFrom / _mint, succeeds without callback
        moduleMock.mint(address(nonReceiver), positionId, 100);

        assertEq(positionManager.balanceOf(address(nonReceiver), positionId), 100);
    }

    function test_batchMintToNonReceiver() public {
        MintNonReceiver nonReceiver = new MintNonReceiver();
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = moduleMock.getPositionId(conditionId, 0);
        ids[1] = moduleMock.getPositionId(conditionId, 1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        // Would revert with safeBatchTransferFrom / _batchMint, succeeds without callback
        moduleMock.batchMint(address(nonReceiver), ids, amounts);

        assertEq(positionManager.balanceOf(address(nonReceiver), ids[0]), 100);
        assertEq(positionManager.balanceOf(address(nonReceiver), ids[1]), 200);
    }

    function test_revert_mint_toZeroAddress() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        uint256 positionId = moduleMock.getPositionId(conditionId, 0);

        vm.expectRevert(TransferToZeroAddress.selector);
        moduleMock.mint(address(0), positionId, 100);
    }

    function test_revert_batchMint_toZeroAddress() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = moduleMock.getPositionId(conditionId, 0);
        ids[1] = moduleMock.getPositionId(conditionId, 1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;

        vm.expectRevert(TransferToZeroAddress.selector);
        moduleMock.batchMint(address(0), ids, amounts);
    }

    function test_revert_batchMint_lengthMismatch() public {
        ConditionId conditionId = moduleMock.getConditionId(bytes32(0));
        uint256[] memory ids = new uint256[](2);
        ids[0] = moduleMock.getPositionId(conditionId, 0);
        ids[1] = moduleMock.getPositionId(conditionId, 1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;

        vm.expectRevert(ArrayLengthsMismatch.selector);
        moduleMock.batchMint(alice, ids, amounts);
    }
}

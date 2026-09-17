// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { Roles } from "@polymarket-v2/src/auth/Roles.sol";

// Concrete implementation of Roles for testing
contract RolesMock is Roles {
    constructor(address _owner) Roles(_owner) { }

    // Some function that requires admin role
    function adminOnlyFunction() external onlyAdmin returns (bool) {
        return true;
    }

    // Some function that requires operator role
    function operatorOnlyFunction() external onlyOperator returns (bool) {
        return true;
    }

    // Some function that requires creator role
    function creatorOnlyFunction() external onlyCreator returns (bool) {
        return true;
    }

    // Some function that requires bridge role
    function bridgeOnlyFunction() external onlyBridge returns (bool) {
        return true;
    }

    // Some function that requires resolver role
    function resolverOnlyFunction() external onlyResolverRole returns (bool) {
        return true;
    }
}

contract RolesTest is TestHelper {
    error Unauthorized();

    RolesMock rolesMock;

    address bridge = address(0xBBBB);

    function setUp() public virtual {
        rolesMock = new RolesMock(owner);

        vm.startPrank(owner);
        rolesMock.addAdmin(admin);
        vm.stopPrank();

        vm.startPrank(admin);
        rolesMock.addOperator(operator);
        rolesMock.addCreator(creator);
        rolesMock.addBridge(bridge);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                        ADMIN
--------------------------------------------------------------*/

contract RolesTest_admin is RolesTest {
    function test_addAdmin() public {
        address admin2 = address(0x9999);

        vm.prank(owner);
        rolesMock.addAdmin(admin2);

        assertEq(rolesMock.hasAllRoles(admin2, 1), true);
    }

    function test_adminOnlyFunction() public {
        vm.prank(admin);
        assertTrue(rolesMock.adminOnlyFunction());
    }

    function test_removeAdmin() public {
        // Create a second admin
        address admin2 = address(0x9999);
        vm.prank(owner);
        rolesMock.addAdmin(admin2);

        // Verify admin2 has admin role
        assertEq(rolesMock.hasAllRoles(admin2, 1), true);

        // Admin removes admin2
        vm.prank(admin);
        rolesMock.removeAdmin(admin2);

        // Verify admin2 no longer has admin role
        assertEq(rolesMock.hasAllRoles(admin2, 1), false);
    }

    function test_revert_removeAdmin_unauthorized() public {
        // Create a second admin
        address admin2 = address(0x9999);
        vm.prank(owner);
        rolesMock.addAdmin(admin2);

        // Alice (non-admin) tries to remove admin2
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        rolesMock.removeAdmin(admin2);
    }

    function test_revert_addAdmin_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.addAdmin(address(0x9999));
    }

    function test_revert_adminOnlyFunction_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.adminOnlyFunction();
    }
}

/*--------------------------------------------------------------
                        OPERATOR
--------------------------------------------------------------*/

contract RolesTest_operator is RolesTest {
    function test_addOperator() public {
        address newOperator = address(0xCAFE);

        vm.prank(admin);
        rolesMock.addOperator(newOperator);

        assertEq(rolesMock.hasAllRoles(newOperator, 2), true);
    }

    function test_operatorOnlyFunction() public {
        vm.prank(operator);
        assertTrue(rolesMock.operatorOnlyFunction());
    }

    function test_removeOperator() public {
        // Verify operator has the role
        assertEq(rolesMock.hasAllRoles(operator, 2), true);

        // Admin removes operator
        vm.prank(admin);
        rolesMock.removeOperator(operator);

        // Verify operator no longer has the role
        assertEq(rolesMock.hasAllRoles(operator, 2), false);
    }

    function test_revert_addOperator_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.addOperator(address(0xCAFE));
    }

    function test_revert_removeOperator_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.removeOperator(operator);
    }

    function test_revert_operatorOnlyFunction_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.operatorOnlyFunction();
    }
}

/*--------------------------------------------------------------
                        CREATOR
--------------------------------------------------------------*/

contract RolesTest_creator is RolesTest {
    function test_addCreator() public {
        address newCreator = address(0xCAFE);

        vm.prank(admin);
        rolesMock.addCreator(newCreator);

        assertEq(rolesMock.hasAllRoles(newCreator, 4), true);
    }

    function test_creatorOnlyFunction() public {
        vm.prank(creator);
        assertTrue(rolesMock.creatorOnlyFunction());
    }

    function test_removeCreator() public {
        // Verify creator has the role
        assertEq(rolesMock.hasAllRoles(creator, 4), true);

        // Admin removes creator
        vm.prank(admin);
        rolesMock.removeCreator(creator);

        // Verify creator no longer has the role
        assertEq(rolesMock.hasAllRoles(creator, 4), false);
    }

    function test_revert_addCreator_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.addCreator(address(0xCAFE));
    }

    function test_revert_removeCreator_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.removeCreator(creator);
    }

    function test_revert_creatorOnlyFunction_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.creatorOnlyFunction();
    }
}

/*--------------------------------------------------------------
                        BRIDGE
--------------------------------------------------------------*/

contract RolesTest_bridge is RolesTest {
    function test_addBridge() public {
        address newBridge = address(0xCCCC);

        vm.prank(admin);
        rolesMock.addBridge(newBridge);

        // _ROLE_3 = 1 << 3 = 8
        assertEq(rolesMock.hasAllRoles(newBridge, 8), true);
    }

    function test_removeBridge() public {
        // Verify bridge has the role (_ROLE_3 = 8)
        assertEq(rolesMock.hasAllRoles(bridge, 8), true);

        // Admin removes bridge
        vm.prank(admin);
        rolesMock.removeBridge(bridge);

        // Verify bridge no longer has the role
        assertEq(rolesMock.hasAllRoles(bridge, 8), false);
    }

    function test_bridgeOnlyFunction() public {
        vm.prank(bridge);
        assertTrue(rolesMock.bridgeOnlyFunction());
    }

    function test_revert_bridgeOnlyFunction_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.bridgeOnlyFunction();
    }

    function test_revert_addBridge_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.addBridge(address(0xDDDD));
    }

    function test_revert_removeBridge_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.removeBridge(bridge);
    }
}

/*--------------------------------------------------------------
                        RESOLVER
--------------------------------------------------------------*/

contract RolesTest_resolver is RolesTest {
    function test_addRemoveResolver() public {
        address resolver = address(0xCAFE);

        vm.prank(admin);
        rolesMock.addResolver(resolver);
        assertEq(rolesMock.hasAllRoles(resolver, 16), true);

        vm.prank(resolver);
        assertTrue(rolesMock.resolverOnlyFunction());

        vm.prank(admin);
        rolesMock.removeResolver(resolver);
        assertEq(rolesMock.hasAllRoles(resolver, 16), false);

        vm.prank(resolver);
        vm.expectRevert(Unauthorized.selector);
        rolesMock.resolverOnlyFunction();
    }
}

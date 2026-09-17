// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";

import { CollateralErrors } from "@polymarket-v2/src/collateral/abstract/CollateralErrors.sol";
import { Collateral, CollateralSetup, USDC, USDCe } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";

contract CollateralOnrampTest is TestHelper, CollateralErrors {
    error Unauthorized();

    Collateral collateral;
    USDC usdc;
    USDCe usdce;

    function setUp() public virtual {
        collateral = CollateralSetup._deploy(owner);
        usdc = collateral.usdc;
        usdce = collateral.usdce;
    }
}

/*--------------------------------------------------------------
                            WRAP
--------------------------------------------------------------*/

contract CollateralOnrampTest_wrap is CollateralOnrampTest {
    function test_wrapUSDC() public {
        uint256 amount = 100_000_000;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdc), alice, amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(alice), amount);
    }

    function test_wrapUSDCe() public {
        uint256 amount = 100_000_000;
        usdce.mint(alice, amount);

        vm.startPrank(alice);
        usdce.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdce), alice, amount);
        vm.stopPrank();

        assertEq(usdce.balanceOf(alice), 0);
        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(alice), amount);
    }
}

/*--------------------------------------------------------------
                           ADMIN
--------------------------------------------------------------*/

contract CollateralOnrampTest_admin is CollateralOnrampTest {
    // Solady's RolesUpdated event
    event RolesUpdated(address indexed user, uint256 indexed roles);

    uint256 internal constant ADMIN_ROLE = 1 << 0; // _ROLE_0

    function test_revert_pause_unauthorized() public {
        // Try to pause as alice (unauthorized)
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        collateral.onramp.pause(address(usdc));
    }

    // --- addAdmin: admin grants admin role to alice ---

    function test_addAdmin() public {
        // Verify alice does not have admin role
        assertFalse(collateral.onramp.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with alice's new roles bitmap
        vm.expectEmit(true, true, true, true, address(collateral.onramp));
        emit RolesUpdated(alice, ADMIN_ROLE);

        // Owner (who was granted admin at deploy) adds alice as admin
        vm.prank(owner);
        collateral.onramp.addAdmin(alice);

        // Verify alice now holds the admin role
        assertTrue(collateral.onramp.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(collateral.onramp.rolesOf(alice), ADMIN_ROLE);
    }

    // --- removeAdmin: admin removes alice's admin role ---

    function test_removeAdmin() public {
        // First grant admin role to alice
        vm.prank(owner);
        collateral.onramp.addAdmin(alice);
        assertTrue(collateral.onramp.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with 0 (all roles removed)
        vm.expectEmit(true, true, true, true, address(collateral.onramp));
        emit RolesUpdated(alice, 0);

        // Owner revokes admin role from alice
        vm.prank(owner);
        collateral.onramp.removeAdmin(alice);

        // Verify alice no longer holds the admin role
        assertFalse(collateral.onramp.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(collateral.onramp.rolesOf(alice), 0);
    }

    // --- revert: non-admin tries to add admin ---

    function test_revert_addAdmin_unauthorized() public {
        // Alice (non-admin) tries to add brian as admin
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        collateral.onramp.addAdmin(brian);

        // Verify brian was not granted the admin role
        assertFalse(collateral.onramp.hasAnyRole(brian, ADMIN_ROLE));
    }

    // --- revert: non-admin tries to remove admin ---

    function test_revert_removeAdmin_unauthorized() public {
        // Alice (non-admin) tries to remove owner's admin role
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        collateral.onramp.removeAdmin(owner);

        // Verify owner still holds the admin role
        assertTrue(collateral.onramp.hasAnyRole(owner, ADMIN_ROLE));
    }
}

/*--------------------------------------------------------------
                           PAUSE
--------------------------------------------------------------*/

contract CollateralOnrampTest_pause is CollateralOnrampTest {
    // PausableEvents
    event Paused(address indexed asset);
    event Unpaused(address indexed asset);

    function test_revert_wrapUSDC_paused() public {
        vm.prank(owner);
        collateral.onramp.pause(address(usdc));

        uint256 amount = 100_000_000;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(collateral.onramp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.onramp.wrap(address(usdc), alice, amount);
        vm.stopPrank();
    }

    function test_revert_wrapUSDCe_paused() public {
        vm.prank(owner);
        collateral.onramp.pause(address(usdce));

        uint256 amount = 100_000_000;
        usdce.mint(alice, amount);

        vm.startPrank(alice);
        usdce.approve(address(collateral.onramp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.onramp.wrap(address(usdce), alice, amount);
        vm.stopPrank();
    }

    function test_unpause() public {
        // First pause USDC
        vm.prank(owner);
        collateral.onramp.pause(address(usdc));

        uint256 amount = 100_000_000;
        usdc.mint(alice, amount);

        // Verify that wrapping is blocked when paused
        vm.startPrank(alice);
        usdc.approve(address(collateral.onramp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.onramp.wrap(address(usdc), alice, amount);
        vm.stopPrank();

        // Expect the Unpaused event when unpausing
        vm.expectEmit(true, true, true, true, address(collateral.onramp));
        emit Unpaused(address(usdc));

        // Now unpause USDC
        vm.prank(owner);
        collateral.onramp.unpause(address(usdc));

        // Verify paused state is now false
        assertFalse(collateral.onramp.paused(address(usdc)));

        // Wrapping should now work
        vm.startPrank(alice);
        collateral.onramp.wrap(address(usdc), alice, amount);
        vm.stopPrank();

        // Verify successful wrap
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(alice), amount);
    }

    function test_pause_emitsEvent() public {
        // Expect the Paused event
        vm.expectEmit(true, true, true, true, address(collateral.onramp));
        emit Paused(address(usdc));

        vm.prank(owner);
        collateral.onramp.pause(address(usdc));

        // Verify paused state
        assertTrue(collateral.onramp.paused(address(usdc)));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";

import { CollateralErrors } from "@polymarket-v2/src/collateral/abstract/CollateralErrors.sol";
import { Collateral, CollateralSetup, USDC, USDCe } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";

contract CollateralOfframpTest is TestHelper, CollateralErrors {
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
                           UNWRAP
--------------------------------------------------------------*/

contract CollateralOfframpTest_unwrap is CollateralOfframpTest {
    function test_unwrapUSDC() public {
        uint256 amount = 100_000_000;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdc), alice, amount);
        vm.stopPrank();

        vm.startPrank(alice);
        collateral.token.approve(address(collateral.offramp), amount);
        collateral.offramp.unwrap(address(usdc), alice, amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), amount);
        assertEq(usdc.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_unwrapUSDCe() public {
        uint256 amount = 100_000_000;
        usdce.mint(alice, amount);

        vm.startPrank(alice);
        usdce.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdce), alice, amount);
        vm.stopPrank();

        vm.startPrank(alice);
        collateral.token.approve(address(collateral.offramp), amount);
        collateral.offramp.unwrap(address(usdce), alice, amount);
        vm.stopPrank();

        assertEq(usdce.balanceOf(alice), amount);
        assertEq(usdce.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(alice), 0);
    }
}

/*--------------------------------------------------------------
                           ADMIN
--------------------------------------------------------------*/

contract CollateralOfframpTest_admin is CollateralOfframpTest {
    // Solady's RolesUpdated event
    event RolesUpdated(address indexed user, uint256 indexed roles);

    uint256 internal constant ADMIN_ROLE = 1 << 0; // _ROLE_0

    function test_revert_pause_unauthorized() public {
        vm.prank(brian);
        vm.expectRevert(Unauthorized.selector);
        collateral.offramp.pause(address(usdc));
    }

    // --- addAdmin: admin grants admin role to alice ---

    function test_addAdmin() public {
        // Verify alice does not have admin role
        assertFalse(collateral.offramp.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with alice's new roles bitmap
        vm.expectEmit(true, true, true, true, address(collateral.offramp));
        emit RolesUpdated(alice, ADMIN_ROLE);

        // Owner (who was granted admin at deploy) adds alice as admin
        vm.prank(owner);
        collateral.offramp.addAdmin(alice);

        // Verify alice now holds the admin role
        assertTrue(collateral.offramp.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(collateral.offramp.rolesOf(alice), ADMIN_ROLE);
    }

    // --- removeAdmin: admin removes alice's admin role ---

    function test_removeAdmin() public {
        // First grant admin role to alice
        vm.prank(owner);
        collateral.offramp.addAdmin(alice);
        assertTrue(collateral.offramp.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with 0 (all roles removed)
        vm.expectEmit(true, true, true, true, address(collateral.offramp));
        emit RolesUpdated(alice, 0);

        // Owner revokes admin role from alice
        vm.prank(owner);
        collateral.offramp.removeAdmin(alice);

        // Verify alice no longer holds the admin role
        assertFalse(collateral.offramp.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(collateral.offramp.rolesOf(alice), 0);
    }

    // --- revert: non-admin tries to add admin ---

    function test_revert_addAdmin_unauthorized() public {
        // Alice (non-admin) tries to add brian as admin
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        collateral.offramp.addAdmin(brian);

        // Verify brian was not granted the admin role
        assertFalse(collateral.offramp.hasAnyRole(brian, ADMIN_ROLE));
    }

    // --- revert: non-admin tries to remove admin ---

    function test_revert_removeAdmin_unauthorized() public {
        // Alice (non-admin) tries to remove owner's admin role
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        collateral.offramp.removeAdmin(owner);

        // Verify owner still holds the admin role
        assertTrue(collateral.offramp.hasAnyRole(owner, ADMIN_ROLE));
    }
}

/*--------------------------------------------------------------
                           PAUSE
--------------------------------------------------------------*/

contract CollateralOfframpTest_pause is CollateralOfframpTest {
    // PausableEvents
    event Paused(address indexed asset);
    event Unpaused(address indexed asset);

    function test_revert_unwrapUSDC_paused() public {
        uint256 amount = 100_000_000;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdc), alice, amount);
        vm.stopPrank();

        vm.prank(owner);
        collateral.offramp.pause(address(usdc));

        vm.startPrank(alice);
        collateral.token.approve(address(collateral.offramp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.offramp.unwrap(address(usdc), alice, amount);
        vm.stopPrank();
    }

    function test_revert_unwrapUSDCe_paused() public {
        uint256 amount = 100_000_000;
        usdce.mint(alice, amount);

        vm.startPrank(alice);
        usdce.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdce), alice, amount);
        vm.stopPrank();

        vm.prank(owner);
        collateral.offramp.pause(address(usdce));

        vm.startPrank(alice);
        collateral.token.approve(address(collateral.offramp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.offramp.unwrap(address(usdce), alice, amount);
        vm.stopPrank();
    }

    function test_unpause() public {
        uint256 amount = 100_000_000;
        usdc.mint(alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(usdc), alice, amount);
        vm.stopPrank();

        vm.prank(owner);
        collateral.offramp.pause(address(usdc));

        vm.startPrank(alice);
        collateral.token.approve(address(collateral.offramp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.offramp.unwrap(address(usdc), alice, amount);
        vm.stopPrank();

        // Expect the Unpaused event when unpausing
        vm.expectEmit(true, true, true, true, address(collateral.offramp));
        emit Unpaused(address(usdc));

        vm.prank(owner);
        collateral.offramp.unpause(address(usdc));

        // Verify paused state is now false
        assertFalse(collateral.offramp.paused(address(usdc)));

        vm.prank(alice);
        collateral.offramp.unwrap(address(usdc), alice, amount);

        assertEq(usdc.balanceOf(alice), amount);
        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_pause_emitsEvent() public {
        // Expect the Paused event
        vm.expectEmit(true, true, true, true, address(collateral.offramp));
        emit Paused(address(usdc));

        vm.prank(owner);
        collateral.offramp.pause(address(usdc));

        // Verify paused state
        assertTrue(collateral.offramp.paused(address(usdc)));
    }
}

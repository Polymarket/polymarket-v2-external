// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";

import { CollateralErrors } from "@polymarket-v2/src/collateral/abstract/CollateralErrors.sol";
import { Collateral, CollateralSetup, USDC, USDCe } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";

contract PermissionedRampTest is TestHelper, CollateralErrors {
    error Unauthorized();

    uint256 witnessKey = 0xA11CE;
    address witness;

    Collateral collateral;
    USDC usdc;
    USDCe usdce;

    function setUp() public virtual {
        witness = vm.addr(witnessKey);

        collateral = CollateralSetup._deploy(owner);
        usdc = collateral.usdc;
        usdce = collateral.usdce;

        vm.prank(owner);
        collateral.permissionedRamp.addWitness(witness);
    }

    // --- helpers ---

    function _signWrap(address _sender, address _asset, address _to, uint256 _amount, uint256 _nonce, uint256 _deadline)
        internal
        view
        returns (bytes memory)
    {
        return _signWrap(witnessKey, _sender, _asset, _to, _amount, _nonce, _deadline);
    }

    function _signWrap(
        uint256 _key,
        address _sender,
        address _asset,
        address _to,
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Wrap(address sender,address asset,address to,uint256 amount,uint256 nonce,uint256 deadline)"
                ),
                _sender,
                _asset,
                _to,
                _amount,
                _nonce,
                _deadline
            )
        );
        bytes32 digest = _hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signUnwrap(
        address _sender,
        address _asset,
        address _to,
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        return _signUnwrap(witnessKey, _sender, _asset, _to, _amount, _nonce, _deadline);
    }

    function _signUnwrap(
        uint256 _key,
        address _sender,
        address _asset,
        address _to,
        uint256 _amount,
        uint256 _nonce,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Unwrap(address sender,address asset,address to,uint256 amount,uint256 nonce,uint256 deadline)"
                ),
                _sender,
                _asset,
                _to,
                _amount,
                _nonce,
                _deadline
            )
        );
        bytes32 digest = _hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            collateral.permissionedRamp.eip712Domain();

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}

/*--------------------------------------------------------------
                            WRAP
--------------------------------------------------------------*/

contract PermissionedRampTest_wrap is PermissionedRampTest {
    function test_wrapUSDC() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory sig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);
        vm.stopPrank();

        assertEq(usdc.balanceOf(brian), 0);
        assertEq(usdc.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_wrapUSDCe() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdce.mint(brian, amount);

        bytes memory sig = _signWrap(brian, address(usdce), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdce.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdce), brian, amount, 0, deadline, sig);
        vm.stopPrank();

        assertEq(usdce.balanceOf(brian), 0);
        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_incrementsNonce() public {
        uint256 amount = 50_000_000;
        uint256 deadline = block.timestamp + 1 hours;

        usdc.mint(brian, amount * 2);

        bytes memory sig0 = _signWrap(brian, address(usdc), brian, amount, 0, deadline);
        bytes memory sig1 = _signWrap(brian, address(usdc), brian, amount, 1, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount * 2);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig0);
        assertEq(collateral.permissionedRamp.nonces(brian), 1);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 1, deadline, sig1);
        assertEq(collateral.permissionedRamp.nonces(brian), 2);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(brian), amount * 2);
    }
}

/*--------------------------------------------------------------
                           UNWRAP
--------------------------------------------------------------*/

contract PermissionedRampTest_unwrap is PermissionedRampTest {
    function test_unwrapUSDC() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory wrapSig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);
        bytes memory unwrapSig = _signUnwrap(brian, address(usdc), brian, amount, 1, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, wrapSig);

        collateral.token.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.unwrap(address(usdc), brian, amount, 1, deadline, unwrapSig);
        vm.stopPrank();

        assertEq(usdc.balanceOf(brian), amount);
        assertEq(usdc.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    function test_unwrapUSDCe() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdce.mint(brian, amount);

        bytes memory wrapSig = _signWrap(brian, address(usdce), brian, amount, 0, deadline);
        bytes memory unwrapSig = _signUnwrap(brian, address(usdce), brian, amount, 1, deadline);

        vm.startPrank(brian);
        usdce.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdce), brian, amount, 0, deadline, wrapSig);

        collateral.token.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.unwrap(address(usdce), brian, amount, 1, deadline, unwrapSig);
        vm.stopPrank();

        assertEq(usdce.balanceOf(brian), amount);
        assertEq(usdce.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(brian), 0);
    }
}

/*--------------------------------------------------------------
                         SIGNATURE
--------------------------------------------------------------*/

contract PermissionedRampTest_signature is PermissionedRampTest {
    function test_revert_wrap_invalidWitness() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 badKey = 0xBAD;
        usdc.mint(brian, amount);

        bytes memory sig = _signWrap(badKey, brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.InvalidSignature.selector);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);
        vm.stopPrank();
    }

    function test_revert_unwrap_invalidWitness() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 badKey = 0xBAD;
        usdc.mint(brian, amount);

        bytes memory wrapSig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, wrapSig);

        bytes memory unwrapSig = _signUnwrap(badKey, brian, address(usdc), brian, amount, 1, deadline);

        collateral.token.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.InvalidSignature.selector);
        collateral.permissionedRamp.unwrap(address(usdc), brian, amount, 1, deadline, unwrapSig);
        vm.stopPrank();
    }

    function test_revert_wrap_invalidNonce() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory sig = _signWrap(brian, address(usdc), brian, amount, 1, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.InvalidNonce.selector);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 1, deadline, sig);
        vm.stopPrank();
    }

    function test_revert_wrap_replaySignature() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount * 2);

        bytes memory sig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount * 2);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);

        // Replay with same nonce fails
        vm.expectRevert(CollateralErrors.InvalidNonce.selector);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);
        vm.stopPrank();
    }

    function test_revert_wrap_expiredDeadline() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp - 1;
        usdc.mint(brian, amount);

        bytes memory sig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.ExpiredDeadline.selector);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);
        vm.stopPrank();
    }

    function test_revert_unwrap_expiredDeadline() public {
        uint256 amount = 100_000_000;
        uint256 wrapDeadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory wrapSig = _signWrap(brian, address(usdc), brian, amount, 0, wrapDeadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, wrapDeadline, wrapSig);

        uint256 expiredDeadline = block.timestamp - 1;
        bytes memory unwrapSig = _signUnwrap(brian, address(usdc), brian, amount, 1, expiredDeadline);

        collateral.token.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.ExpiredDeadline.selector);
        collateral.permissionedRamp.unwrap(address(usdc), brian, amount, 1, expiredDeadline, unwrapSig);
        vm.stopPrank();
    }

    // --- Covers the branch in _validateSignature where the
    //     recovered signer does not hold the witness role ---

    function test_revert_wrap_signerNotWitness() public {
        // Sign with a valid key that is not a witness (brian's own key)
        uint256 brianKey = 0xB0B;
        address brianAddr = vm.addr(brianKey);

        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brianAddr, amount);

        // Sign with brianKey (not a witness)
        bytes memory sig = _signWrap(brianKey, brianAddr, address(usdc), brianAddr, amount, 0, deadline);

        vm.startPrank(brianAddr);
        usdc.approve(address(collateral.permissionedRamp), amount);
        // The recovered address is brianAddr, who has no witness role
        vm.expectRevert(CollateralErrors.InvalidSignature.selector);
        collateral.permissionedRamp.wrap(address(usdc), brianAddr, amount, 0, deadline, sig);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                           ADMIN
--------------------------------------------------------------*/

contract PermissionedRampTest_admin is PermissionedRampTest {
    // Solady's RolesUpdated event
    event RolesUpdated(address indexed user, uint256 indexed roles);

    uint256 internal constant ADMIN_ROLE = 1 << 0; // _ROLE_0
    uint256 internal constant WITNESS_ROLE = 1 << 1; // _ROLE_1

    function test_addWitness() public {
        uint256 newWitnessKey = 0xBEEF;
        address newWitness = vm.addr(newWitnessKey);

        vm.prank(owner);
        collateral.permissionedRamp.addWitness(newWitness);

        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory sig = _signWrap(newWitnessKey, brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_removeWitness() public {
        vm.prank(owner);
        collateral.permissionedRamp.removeWitness(witness);

        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory sig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.InvalidSignature.selector);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);
        vm.stopPrank();
    }

    // --- addAdmin: admin grants admin role to alice ---

    function test_addAdmin() public {
        // Verify alice does not have admin role
        assertFalse(collateral.permissionedRamp.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with alice's new roles bitmap
        vm.expectEmit(true, true, true, true, address(collateral.permissionedRamp));
        emit RolesUpdated(alice, ADMIN_ROLE);

        // Owner (who was granted admin at deploy) adds alice as admin
        vm.prank(owner);
        collateral.permissionedRamp.addAdmin(alice);

        // Verify alice now holds the admin role
        assertTrue(collateral.permissionedRamp.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(collateral.permissionedRamp.rolesOf(alice), ADMIN_ROLE);
    }

    // --- removeAdmin: admin removes alice's admin role ---

    function test_removeAdmin() public {
        // First grant admin role to alice
        vm.prank(owner);
        collateral.permissionedRamp.addAdmin(alice);
        assertTrue(collateral.permissionedRamp.hasAnyRole(alice, ADMIN_ROLE));

        // Expect the RolesUpdated event with 0 (all roles removed)
        vm.expectEmit(true, true, true, true, address(collateral.permissionedRamp));
        emit RolesUpdated(alice, 0);

        // Owner revokes admin role from alice
        vm.prank(owner);
        collateral.permissionedRamp.removeAdmin(alice);

        // Verify alice no longer holds the admin role
        assertFalse(collateral.permissionedRamp.hasAnyRole(alice, ADMIN_ROLE));
        assertEq(collateral.permissionedRamp.rolesOf(alice), 0);
    }

    // --- revert: non-admin tries to add admin ---

    function test_revert_addAdmin_unauthorized() public {
        // Alice (non-admin) tries to add brian as admin
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        collateral.permissionedRamp.addAdmin(brian);

        // Verify brian was not granted the admin role
        assertFalse(collateral.permissionedRamp.hasAnyRole(brian, ADMIN_ROLE));
    }

    // --- revert: non-admin tries to remove admin ---

    function test_revert_removeAdmin_unauthorized() public {
        // Alice (non-admin) tries to remove owner's admin role
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        collateral.permissionedRamp.removeAdmin(owner);

        // Verify owner still holds the admin role
        assertTrue(collateral.permissionedRamp.hasAnyRole(owner, ADMIN_ROLE));
    }
}

/*--------------------------------------------------------------
                           PAUSE
--------------------------------------------------------------*/

contract PermissionedRampTest_pause is PermissionedRampTest {
    function test_revert_wrap_paused() public {
        vm.prank(owner);
        collateral.permissionedRamp.pause(address(usdc));

        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory sig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, sig);
        vm.stopPrank();
    }

    function test_revert_unwrap_paused() public {
        uint256 amount = 100_000_000;
        uint256 deadline = block.timestamp + 1 hours;
        usdc.mint(brian, amount);

        bytes memory wrapSig = _signWrap(brian, address(usdc), brian, amount, 0, deadline);

        vm.startPrank(brian);
        usdc.approve(address(collateral.permissionedRamp), amount);
        collateral.permissionedRamp.wrap(address(usdc), brian, amount, 0, deadline, wrapSig);
        vm.stopPrank();

        vm.prank(owner);
        collateral.permissionedRamp.pause(address(usdc));

        bytes memory unwrapSig = _signUnwrap(brian, address(usdc), brian, amount, 1, deadline);

        vm.startPrank(brian);
        collateral.token.approve(address(collateral.permissionedRamp), amount);
        vm.expectRevert(CollateralErrors.OnlyUnpaused.selector);
        collateral.permissionedRamp.unwrap(address(usdc), brian, amount, 1, deadline, unwrapSig);
        vm.stopPrank();
    }
}

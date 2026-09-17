// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";
import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { Ownable } from "@solady/src/auth/Ownable.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";

import {
    Collateral,
    CollateralToken,
    USDC,
    USDCe,
    CollateralSetup
} from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { CollateralErrors } from "@polymarket-v2/src/collateral/abstract/CollateralErrors.sol";
import { CollateralTokenEvents } from "@polymarket-v2/src/collateral/CollateralToken.sol";

contract CollateralTokenTest is TestHelper, CollateralTokenEvents, CollateralErrors {
    error Unauthorized();

    Collateral collateral;
    USDC usdc;
    USDCe usdce;

    address wrapper;
    address minter;

    uint256 amount = 100_000_000;

    function setUp() public virtual {
        collateral = CollateralSetup._deploy(owner);
        usdc = collateral.usdc;
        usdce = collateral.usdce;

        wrapper = vm.createWallet("wrapper").addr;
        minter = vm.createWallet("minter").addr;

        vm.startPrank(owner);
        collateral.token.addWrapper(wrapper);
        collateral.token.addMinter(minter);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                         INITIALIZE
--------------------------------------------------------------*/

contract CollateralTokenTest_initialize is CollateralTokenTest {
    function test_initialize() public view {
        assertEq(collateral.token.owner(), owner);
    }

    function test_revert_alreadyInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        collateral.token.initialize(alice);
    }
}

/*--------------------------------------------------------------
                            VIEW
--------------------------------------------------------------*/

contract CollateralTokenTest_view is CollateralTokenTest {
    function test_name() public view {
        assertEq(collateral.token.name(), "Polymarket USD");
    }

    function test_symbol() public view {
        assertEq(collateral.token.symbol(), "pUSD");
    }

    function test_decimals() public view {
        assertEq(collateral.token.decimals(), 6);
    }

    function test_immutables() public view {
        assertEq(collateral.token.USDC(), address(usdc));
        assertEq(collateral.token.USDCE(), address(usdce));
        assertEq(collateral.token.VAULT(), collateral.vault);
    }
}

/*--------------------------------------------------------------
                       ROLE MANAGEMENT
--------------------------------------------------------------*/

contract CollateralTokenTest_roles is CollateralTokenTest {
    function test_addMinter() public {
        vm.prank(owner);
        collateral.token.addMinter(alice);
        assertTrue(collateral.token.hasAllRoles(alice, 1 << 0));
    }

    function test_removeMinter() public {
        vm.prank(owner);
        collateral.token.addMinter(alice);
        assertTrue(collateral.token.hasAllRoles(alice, 1 << 0));

        vm.prank(owner);
        collateral.token.removeMinter(alice);
        assertFalse(collateral.token.hasAllRoles(alice, 1 << 0));
    }

    function test_addWrapper() public {
        vm.prank(owner);
        collateral.token.addWrapper(alice);
        assertTrue(collateral.token.hasAllRoles(alice, 1 << 1));
    }

    function test_removeWrapper() public {
        vm.prank(owner);
        collateral.token.addWrapper(alice);
        assertTrue(collateral.token.hasAllRoles(alice, 1 << 1));

        vm.prank(owner);
        collateral.token.removeWrapper(alice);
        assertFalse(collateral.token.hasAllRoles(alice, 1 << 1));
    }

    function test_revert_addMinter_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.addMinter(brian);
    }

    function test_revert_removeMinter_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.removeMinter(brian);
    }

    function test_revert_addWrapper_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.addWrapper(brian);
    }

    function test_revert_removeWrapper_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.removeWrapper(brian);
    }
}

/*--------------------------------------------------------------
                            MINT
--------------------------------------------------------------*/

contract CollateralTokenTest_mint is CollateralTokenTest {
    function test_mint() public {
        vm.prank(minter);
        collateral.token.mint(alice, amount);
        assertEq(collateral.token.balanceOf(alice), amount);
    }

    function test_revert_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.mint(alice, amount);
    }
}

/*--------------------------------------------------------------
                            BURN
--------------------------------------------------------------*/

contract CollateralTokenTest_burn is CollateralTokenTest {
    function test_burn() public {
        vm.prank(minter);
        collateral.token.mint(minter, amount);
        assertEq(collateral.token.balanceOf(minter), amount);

        vm.prank(minter);
        collateral.token.burn(amount);
        assertEq(collateral.token.balanceOf(minter), 0);
    }

    function test_revert_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.burn(amount);
    }
}

/*--------------------------------------------------------------
                            WRAP
--------------------------------------------------------------*/

contract CollateralTokenTest_wrap is CollateralTokenTest {
    function test_wrapUSDC() public {
        usdc.mint(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Wrapped(wrapper, address(usdc), brian, amount);

        vm.prank(wrapper);
        collateral.token.wrap(address(usdc), brian, amount);

        assertEq(usdc.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_wrapUSDCe() public {
        usdce.mint(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Wrapped(wrapper, address(usdce), brian, amount);

        vm.prank(wrapper);
        collateral.token.wrap(address(usdce), brian, amount);

        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_revert_invalidAsset(address _invalidAsset) public {
        vm.assume(_invalidAsset != address(usdc) && _invalidAsset != address(usdce));

        vm.prank(wrapper);
        vm.expectRevert(CollateralErrors.InvalidAsset.selector);
        collateral.token.wrap(_invalidAsset, brian, amount);
    }

    function test_revert_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.wrap(address(usdc), brian, amount);
    }

    function test_revert_wrap_noPreTransfer() public {
        vm.prank(wrapper);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        collateral.token.wrap(address(usdc), brian, amount);
    }
}

/*--------------------------------------------------------------
                           UNWRAP
--------------------------------------------------------------*/

contract CollateralTokenTest_unwrap is CollateralTokenTest {
    function _wrap(address _asset, address _to, uint256 _amount) internal {
        if (_asset == address(usdc)) usdc.mint(address(collateral.token), _amount);
        else usdce.mint(address(collateral.token), _amount);

        vm.prank(wrapper);
        collateral.token.wrap(_asset, _to, _amount);
    }

    function test_unwrapUSDC() public {
        _wrap(address(usdc), brian, amount);

        vm.prank(brian);
        collateral.token.transfer(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Unwrapped(wrapper, address(usdc), alice, amount);

        vm.prank(wrapper);
        collateral.token.unwrap(address(usdc), alice, amount);

        assertEq(usdc.balanceOf(alice), amount);
        assertEq(usdc.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    function test_unwrapUSDCe() public {
        _wrap(address(usdce), brian, amount);

        vm.prank(brian);
        collateral.token.transfer(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Unwrapped(wrapper, address(usdce), alice, amount);

        vm.prank(wrapper);
        collateral.token.unwrap(address(usdce), alice, amount);

        assertEq(usdce.balanceOf(alice), amount);
        assertEq(usdce.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    function test_unwrapUSDC_pretransfer() public {
        _wrap(address(usdc), alice, amount);

        vm.prank(alice);
        collateral.token.transfer(address(collateral.token), amount);

        vm.prank(wrapper);
        collateral.token.unwrap(address(usdc), brian, amount);

        assertEq(usdc.balanceOf(brian), amount);
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    function test_revert_invalidAsset(address _invalidAsset) public {
        vm.assume(_invalidAsset != address(usdc) && _invalidAsset != address(usdce));

        vm.prank(wrapper);
        vm.expectRevert(CollateralErrors.InvalidAsset.selector);
        collateral.token.unwrap(_invalidAsset, brian, amount);
    }

    function test_revert_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.unwrap(address(usdc), brian, amount);
    }

    function test_revert_unwrap_noPreTransfer() public {
        // Vault needs the asset so unwrap's safeTransferFrom passes; the failure is at the
        // subsequent pUSD `_burn(address(this), _amount)`.
        usdc.mint(collateral.vault, amount);

        vm.prank(wrapper);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        collateral.token.unwrap(address(usdc), alice, amount);
    }
}

/*--------------------------------------------------------------
              WRAP (LEGACY RAMP-COMPATIBLE OVERLOAD)
--------------------------------------------------------------*/

contract CollateralTokenTest_wrapLegacy is CollateralTokenTest {
    function test_wrapUSDC() public {
        // pre-transfer + zero callback receiver: the exact call shape used by the deployed
        // ctf-exchange-v2 ramps and adapters
        usdc.mint(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Wrapped(wrapper, address(usdc), brian, amount);

        vm.prank(wrapper);
        collateral.token.wrap(address(usdc), brian, amount, address(0), "");

        assertEq(usdc.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_wrapUSDCe() public {
        usdce.mint(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Wrapped(wrapper, address(usdce), brian, amount);

        vm.prank(wrapper);
        collateral.token.wrap(address(usdce), brian, amount, address(0), "");

        assertEq(usdce.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_wrap_ignoresCallbackReceiver() public {
        // a non-zero callback receiver is accepted for ABI compatibility but never called
        address receiver = vm.createWallet("callbackReceiver").addr;
        usdc.mint(address(collateral.token), amount);

        // assert that no call of any kind is made to the receiver
        vm.expectCall(receiver, "", 0);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Wrapped(wrapper, address(usdc), brian, amount);

        vm.prank(wrapper);
        collateral.token.wrap(address(usdc), brian, amount, receiver, "some data");

        assertEq(usdc.balanceOf(collateral.vault), amount);
        assertEq(collateral.token.balanceOf(brian), amount);
    }

    function test_revert_notFundedViaCallback() public {
        // the legacy callback-funding flow is gone: without a pre-transfer the wrap reverts
        // even when a callback receiver is supplied
        vm.prank(wrapper);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        collateral.token.wrap(address(usdc), brian, amount, alice, "");
    }

    function test_revert_invalidAsset(address _invalidAsset) public {
        vm.assume(_invalidAsset != address(usdc) && _invalidAsset != address(usdce));

        vm.prank(wrapper);
        vm.expectRevert(CollateralErrors.InvalidAsset.selector);
        collateral.token.wrap(_invalidAsset, brian, amount, address(0), "");
    }

    function test_revert_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.wrap(address(usdc), brian, amount, address(0), "");
    }
}

/*--------------------------------------------------------------
             UNWRAP (LEGACY RAMP-COMPATIBLE OVERLOAD)
--------------------------------------------------------------*/

contract CollateralTokenTest_unwrapLegacy is CollateralTokenTest {
    function _wrapTo(address _asset, address _to, uint256 _amount) internal {
        if (_asset == address(usdc)) usdc.mint(address(collateral.token), _amount);
        else usdce.mint(address(collateral.token), _amount);

        vm.prank(wrapper);
        collateral.token.wrap(_asset, _to, _amount);
    }

    function test_unwrapUSDC() public {
        // pre-transfer + zero callback receiver: the exact call shape used by the deployed
        // ctf-exchange-v2 ramps and adapters
        _wrapTo(address(usdc), brian, amount);

        vm.prank(brian);
        collateral.token.transfer(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Unwrapped(wrapper, address(usdc), alice, amount);

        vm.prank(wrapper);
        collateral.token.unwrap(address(usdc), alice, amount, address(0), "");

        assertEq(usdc.balanceOf(alice), amount);
        assertEq(usdc.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    function test_unwrapUSDCe() public {
        _wrapTo(address(usdce), brian, amount);

        vm.prank(brian);
        collateral.token.transfer(address(collateral.token), amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Unwrapped(wrapper, address(usdce), alice, amount);

        vm.prank(wrapper);
        collateral.token.unwrap(address(usdce), alice, amount, address(0), "");

        assertEq(usdce.balanceOf(alice), amount);
        assertEq(usdce.balanceOf(collateral.vault), 0);
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    function test_unwrap_ignoresCallbackReceiver() public {
        // a non-zero callback receiver is accepted for ABI compatibility but never called
        address receiver = vm.createWallet("callbackReceiver").addr;
        _wrapTo(address(usdc), brian, amount);

        vm.prank(brian);
        collateral.token.transfer(address(collateral.token), amount);

        // assert that no call of any kind is made to the receiver
        vm.expectCall(receiver, "", 0);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Unwrapped(wrapper, address(usdc), alice, amount);

        vm.prank(wrapper);
        collateral.token.unwrap(address(usdc), alice, amount, receiver, "some data");

        assertEq(usdc.balanceOf(alice), amount);
        assertEq(collateral.token.balanceOf(brian), 0);
    }

    function test_revert_notFundedViaCallback() public {
        // the legacy callback-funding flow is gone: without a pre-transfer of the collateral
        // the unwrap reverts at the burn even when a callback receiver is supplied
        usdc.mint(collateral.vault, amount);

        vm.prank(wrapper);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        collateral.token.unwrap(address(usdc), alice, amount, alice, "");
    }

    function test_revert_invalidAsset(address _invalidAsset) public {
        vm.assume(_invalidAsset != address(usdc) && _invalidAsset != address(usdce));

        vm.prank(wrapper);
        vm.expectRevert(CollateralErrors.InvalidAsset.selector);
        collateral.token.unwrap(_invalidAsset, brian, amount, address(0), "");
    }

    function test_revert_unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.unwrap(address(usdc), brian, amount, address(0), "");
    }
}

/*--------------------------------------------------------------
                           RESCUE
--------------------------------------------------------------*/

contract CollateralTokenTest_rescue is CollateralTokenTest {
    /// @dev Builds single-entry batch arrays for the common one-asset case.
    function _single(address _asset, address _to, uint256 _amount)
        internal
        pure
        returns (address[] memory assets, address[] memory tos, uint256[] memory amounts)
    {
        assets = new address[](1);
        tos = new address[](1);
        amounts = new uint256[](1);
        assets[0] = _asset;
        tos[0] = _to;
        amounts[0] = _amount;
    }

    function test_rescue() public {
        usdc.mint(address(collateral.token), amount);
        (address[] memory assets, address[] memory tos, uint256[] memory amounts) =
            _single(address(usdc), alice, amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Rescued(address(usdc), alice, amount);

        vm.prank(owner);
        collateral.token.rescue(assets, tos, amounts);

        assertEq(usdc.balanceOf(alice), amount);
        assertEq(usdc.balanceOf(address(collateral.token)), 0);
    }

    function test_rescue_batch() public {
        // one batch across three assets, including pUSD itself, each to a different recipient,
        // with one Rescued event per entry
        usdc.mint(address(collateral.token), amount);
        usdce.mint(address(collateral.token), amount * 2);

        vm.prank(minter);
        collateral.token.mint(address(collateral.token), amount * 3);

        address[] memory assets = new address[](3);
        address[] memory tos = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        assets[0] = address(usdc);
        tos[0] = alice;
        amounts[0] = amount;
        assets[1] = address(usdce);
        tos[1] = brian;
        amounts[1] = amount * 2;
        assets[2] = address(collateral.token);
        tos[2] = carly;
        amounts[2] = amount * 3;

        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(true, true, true, true, address(collateral.token));
            emit Rescued(assets[i], tos[i], amounts[i]);
        }

        vm.prank(owner);
        collateral.token.rescue(assets, tos, amounts);

        assertEq(usdc.balanceOf(alice), amount);
        assertEq(usdce.balanceOf(brian), amount * 2);
        assertEq(collateral.token.balanceOf(carly), amount * 3);
        assertEq(usdc.balanceOf(address(collateral.token)), 0);
        assertEq(usdce.balanceOf(address(collateral.token)), 0);
        assertEq(collateral.token.balanceOf(address(collateral.token)), 0);
    }

    function test_rescue_collateralToken() public {
        // pUSD accidentally transferred to the token contract without a matching unwrap gets
        // stuck; rescue is not restricted to USDC/USDCe so the owner can recover it
        vm.prank(minter);
        collateral.token.mint(brian, amount);

        vm.prank(brian);
        collateral.token.transfer(address(collateral.token), amount);

        (address[] memory assets, address[] memory tos, uint256[] memory amounts) =
            _single(address(collateral.token), alice, amount);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Rescued(address(collateral.token), alice, amount);

        vm.prank(owner);
        collateral.token.rescue(assets, tos, amounts);

        assertEq(collateral.token.balanceOf(alice), amount);
        assertEq(collateral.token.balanceOf(address(collateral.token)), 0);
    }

    function test_rescue_partialAmount() public {
        usdce.mint(address(collateral.token), amount);
        (address[] memory assets, address[] memory tos, uint256[] memory amounts) =
            _single(address(usdce), alice, amount / 2);

        vm.expectEmit(true, true, true, true, address(collateral.token));
        emit Rescued(address(usdce), alice, amount / 2);

        vm.prank(owner);
        collateral.token.rescue(assets, tos, amounts);

        assertEq(usdce.balanceOf(alice), amount / 2);
        assertEq(usdce.balanceOf(address(collateral.token)), amount - amount / 2);
    }

    function test_rescue_emptyBatch() public {
        vm.prank(owner);
        collateral.token.rescue(new address[](0), new address[](0), new uint256[](0));
    }

    function test_revert_unauthorized() public {
        usdc.mint(address(collateral.token), amount);
        (address[] memory assets, address[] memory tos, uint256[] memory amounts) =
            _single(address(usdc), alice, amount);

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.rescue(assets, tos, amounts);
    }

    function test_revert_lengthMismatch_tos() public {
        vm.prank(owner);
        vm.expectRevert(CollateralErrors.ArrayLengthMismatch.selector);
        collateral.token.rescue(new address[](2), new address[](1), new uint256[](2));
    }

    function test_revert_lengthMismatch_amounts() public {
        vm.prank(owner);
        vm.expectRevert(CollateralErrors.ArrayLengthMismatch.selector);
        collateral.token.rescue(new address[](2), new address[](2), new uint256[](1));
    }

    function test_revert_insufficientBalance() public {
        (address[] memory assets, address[] memory tos, uint256[] memory amounts) =
            _single(address(usdc), alice, amount);

        vm.prank(owner);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        collateral.token.rescue(assets, tos, amounts);
    }

    function test_revert_atomicBatch() public {
        // first entry is funded, second is not: the whole batch reverts and no balances move
        usdc.mint(address(collateral.token), amount);

        address[] memory assets = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        assets[0] = address(usdc);
        tos[0] = alice;
        amounts[0] = amount;
        assets[1] = address(usdce);
        tos[1] = brian;
        amounts[1] = amount;

        vm.prank(owner);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        collateral.token.rescue(assets, tos, amounts);

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(collateral.token)), amount);
    }
}

/*--------------------------------------------------------------
                          PERMIT2
--------------------------------------------------------------*/

contract CollateralTokenTest_permit2 is CollateralTokenTest {
    function test_permit2NoInfiniteAllowance() public view {
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        assertEq(collateral.token.allowance(alice, permit2), 0);
    }
}

/*--------------------------------------------------------------
                        UUPS UPGRADE
--------------------------------------------------------------*/

contract CollateralTokenTest_upgrade is CollateralTokenTest {
    function test_upgradeToAndCall() public {
        address newImpl = address(new CollateralToken(address(usdc), address(usdce), collateral.vault));

        vm.prank(owner);
        collateral.token.upgradeToAndCall(newImpl, "");
    }

    function test_revert_unauthorized() public {
        address newImpl = address(new CollateralToken(address(usdc), address(usdce), collateral.vault));

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        collateral.token.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
           ONLY VALID ASSET MODIFIER - BOTH BRANCHES
--------------------------------------------------------------*/

/// @notice Tests for onlyValidAsset modifier covering both asset branches and the revert path
/// The existing test for wrapUSDCe covers _asset == usdce being true,
/// but the coverage tool may not count both branches of the OR.
/// This test ensures both assets pass and an invalid one fails.
contract CollateralTokenTest_validAsset is CollateralTokenTest {
    // Test that USDC is accepted by the modifier (first branch: _asset == usdc)
    function test_validAsset_usdc() public {
        usdc.mint(address(collateral.token), 100);

        vm.prank(wrapper);
        collateral.token.wrap(address(usdc), alice, 100);

        assertEq(collateral.token.balanceOf(alice), 100);
    }

    // Test that USDCe is accepted by the modifier (second branch: _asset == usdce)
    function test_validAsset_usdce() public {
        usdce.mint(address(collateral.token), 100);

        vm.prank(wrapper);
        collateral.token.wrap(address(usdce), alice, 100);

        assertEq(collateral.token.balanceOf(alice), 100);
    }

    // Test that an invalid asset reverts in the onlyValidAsset modifier
    function test_revert_invalidAsset() public {
        vm.prank(wrapper);
        vm.expectRevert(CollateralErrors.InvalidAsset.selector);
        collateral.token.wrap(address(0xdead), alice, 100);
    }
}

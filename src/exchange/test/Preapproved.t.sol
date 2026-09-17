// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BaseExchangeTest } from "./BaseExchangeTest.sol";
import { ToggleableERC1271Mock } from "./mocks/ToggleableERC1271Mock.sol";
import { Order, Side, SignatureType } from "@polymarket-v2/src/exchange/OrderStructs.sol";

contract PreapprovedTest is BaseExchangeTest {
    ToggleableERC1271Mock public toggleWallet;

    function setUp() public virtual override {
        super.setUp();
        toggleWallet = new ToggleableERC1271Mock(carla);
    }
}

/*--------------------------------------------------------------
                      PREAPPROVED MATCHING
--------------------------------------------------------------*/

contract PreapprovedTest_matching is PreapprovedTest {
    function test_preapprovedMakerComplementary() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        // Preapprove the maker order, then invalidate its signature
        vm.prank(admin);
        exchange.preapproveOrder(makerOrder);
        makerOrder.signature = new bytes(0);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCTFBalance(carla, yes, 0);
        assertCollateralBalance(carla, 50_000_000);
    }

    function test_preapprovedTakerComplementary() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        // Preapprove the taker order, then invalidate its signature
        vm.prank(admin);
        exchange.preapproveOrder(takerOrder);
        takerOrder.signature = new bytes(0);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCTFBalance(carla, yes, 0);
        assertCollateralBalance(carla, 50_000_000);
    }

    function test_respectsFilledStatus() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        vm.startPrank(admin);
        exchange.preapproveOrder(takerOrder);
        exchange.preapproveOrder(makerOrder);
        vm.stopPrank();
        takerOrder.signature = new bytes(0);
        makerOrder.signature = new bytes(0);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        // First match: fill completely
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        // Second match: should revert because taker order is already filled
        vm.expectRevert(OrderAlreadyFilled.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_respectsUserPause() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        vm.prank(admin);
        exchange.preapproveOrder(takerOrder);
        takerOrder.signature = new bytes(0);

        // Bob pauses himself, advance past delay
        vm.prank(bob);
        exchange.pauseUser();
        vm.roll(block.number + exchange.userPauseBlockInterval());

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        // Should revert because bob is paused, even though order is preapproved
        vm.expectRevert(UserIsPaused.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_partialFill() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 25_000_000, Side.SELL);

        vm.prank(admin);
        exchange.preapproveOrder(takerOrder);
        takerOrder.signature = new bytes(0);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        // Fill half
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 25_000_000, fillAmounts, 0, makerFeeAmounts);

        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 25_000_000);

        // Fill the rest with a new maker
        uint256 davePK = 0xDA7E;
        address dave = vm.addr(davePK);
        vm.label(dave, "dave");
        vm.prank(admin);
        exchange.addOperator(dave);
        dealOutcomeTokensAndApprove(dave, address(exchange), 50_000_000);

        Order memory makerOrder2 = _createAndSignOrderWithSalt(davePK, yes, 50_000_000, 25_000_000, Side.SELL, 2);

        makerOrders[0] = makerOrder2;
        fillAmounts[0] = 50_000_000;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 25_000_000, fillAmounts, 0, makerFeeAmounts);

        (filled,) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertTrue(filled);
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
    }
}

/*--------------------------------------------------------------
                      ERC1271 PREAPPROVAL
--------------------------------------------------------------*/

contract PreapprovedTest_erc1271 is PreapprovedTest {
    function test_signerInvalidated() public {
        // Fund the toggleWallet
        dealCollateralAndApprove(address(toggleWallet), address(exchange), 100_000_000);

        // Create two POLY_1271 orders from the same wallet, different salts
        Order memory preapprovedOrder =
            _createAndSign1271Order(carlaPK, address(toggleWallet), yes, 50_000_000, 100_000_000, Side.BUY);

        Order memory notPreapprovedOrder = _createOrder(address(toggleWallet), yes, 50_000_000, 100_000_000, Side.BUY);
        notPreapprovedOrder.salt = 2;
        notPreapprovedOrder.signatureType = SignatureType.POLY_1271;
        notPreapprovedOrder.signature = _signMessage(carlaPK, exchange.hashOrder(notPreapprovedOrder));

        // Preapprove only the first order while the wallet is active
        vm.prank(admin);
        exchange.preapproveOrder(preapprovedOrder);

        // Disable the wallet's signature validation (simulates session signer deauthorization)
        toggleWallet.disable();

        // Non-preapproved order from disabled wallet FAILS
        {
            dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
            Order memory makerForFail = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

            Order[] memory makerOrders = new Order[](1);
            makerOrders[0] = makerForFail;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = 100_000_000;
            uint256[] memory makerFeeAmounts = new uint256[](1);
            makerFeeAmounts[0] = 0;

            vm.expectRevert(InvalidSignature.selector);
            vm.prank(admin);
            _matchOrders(conditionId, notPreapprovedOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
        }

        // Preapproved order from disabled wallet SUCCEEDS (empty sig triggers preapproval check)
        {
            preapprovedOrder.signature = new bytes(0);

            dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);
            Order memory makerForSuccess = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

            Order[] memory makerOrders = new Order[](1);
            makerOrders[0] = makerForSuccess;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = 100_000_000;
            uint256[] memory makerFeeAmounts = new uint256[](1);
            makerFeeAmounts[0] = 0;

            vm.prank(admin);
            _matchOrders(conditionId, preapprovedOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
        }

        // Wallet spent 50 USDC, has 50 left
        assertCollateralBalance(address(toggleWallet), 50_000_000);
        assertCTFBalance(address(toggleWallet), yes, 100_000_000);
    }
}

/*--------------------------------------------------------------
                      PREAPPROVAL OPERATOR CHECK
--------------------------------------------------------------*/

contract PreapprovedTest_preapproval is PreapprovedTest {
    function test_revert_preapproveOrder_notOperator() public {
        Order memory order = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        // Non-operator tries to preapprove
        address nonOp = makeAddr("nonOperator");
        vm.expectRevert(NotOperator.selector);
        vm.prank(nonOp);
        exchange.preapproveOrder(order);
    }

    function test_preapproveOrder_thenMatch() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        // Preapprove both orders
        bytes32 takerHash = exchange.hashOrder(takerOrder);
        bytes32 makerHash = exchange.hashOrder(makerOrder);

        vm.startPrank(admin);
        vm.expectEmit(true, true, true, true, address(exchange));
        emit OrderPreapproved(takerHash);
        exchange.preapproveOrder(takerOrder);

        vm.expectEmit(true, true, true, true, address(exchange));
        emit OrderPreapproved(makerHash);
        exchange.preapproveOrder(makerOrder);
        vm.stopPrank();

        // Verify preapproved
        assertTrue(exchange.preapproved(takerHash));
        assertTrue(exchange.preapproved(makerHash));

        // Now match with empty signatures (preapproval should let them through)
        takerOrder.signature = new bytes(0);
        makerOrder.signature = new bytes(0);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCTFBalance(bob, yes, 100_000_000);
    }

    function test_invalidatePreapprovedOrder() public {
        Order memory order = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        bytes32 orderHash = exchange.hashOrder(order);

        vm.prank(admin);
        exchange.preapproveOrder(order);
        assertTrue(exchange.preapproved(orderHash));

        vm.expectEmit(true, true, true, true, address(exchange));
        emit OrderPreapprovalInvalidated(orderHash);

        vm.prank(admin);
        exchange.invalidatePreapprovedOrder(orderHash);

        assertFalse(exchange.preapproved(orderHash));
    }
}

/*--------------------------------------------------------------
                          REVERTS
--------------------------------------------------------------*/

contract PreapprovedTest_reverts is PreapprovedTest {
    function test_revert_invalidatedPreapproval() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        bytes32 makerOrderHash = exchange.hashOrder(makerOrder);

        // Preapprove the maker order
        vm.expectEmit(true, false, false, false);
        emit OrderPreapproved(makerOrderHash);
        vm.prank(admin);
        exchange.preapproveOrder(makerOrder);

        // Invalidate the ECDSA signature so only preapproval can authorize
        makerOrder.signature = new bytes(0);

        // Now invalidate the preapproval
        vm.expectEmit(true, false, false, false);
        emit OrderPreapprovalInvalidated(makerOrderHash);
        vm.prank(admin);
        exchange.invalidatePreapprovedOrder(makerOrderHash);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        // Should revert: signature is invalid AND preapproval has been invalidated
        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_invalidSignature() public {
        Order memory order = _createOrder(bob, yes, 50_000_000, 100_000_000, Side.BUY);
        // Sign with the wrong key (carla signs bob's order)
        order.signature = _signMessage(carlaPK, exchange.hashOrder(order));

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        exchange.preapproveOrder(order);
    }

    function test_revert_notOperator() public {
        Order memory order = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        address nonOperator = address(0xBEEF);

        vm.expectRevert(NotOperator.selector);
        vm.prank(nonOperator);
        exchange.preapproveOrder(order);
    }

    function test_revert_invalidSignatureNotPreapproved() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        takerOrder.signature = new bytes(0);

        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

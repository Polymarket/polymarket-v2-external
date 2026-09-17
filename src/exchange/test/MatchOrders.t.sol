// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BaseExchangeTest } from "./BaseExchangeTest.sol";
import { ConditionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { Exchange, TakerAmounts } from "@polymarket-v2/src/exchange/Exchange.sol";
import { Order, Side, SignatureType, OrderStatus } from "@polymarket-v2/src/exchange/OrderStructs.sol";

contract MatchOrdersTest is BaseExchangeTest {
    function _expectOrderFilled(
        Order memory order,
        address taker,
        uint256 makerAmountFilled,
        uint256 takerAmountFilled,
        uint256 fee
    ) internal {
        vm.expectEmit(true, true, true, true, address(exchange));
        emit OrderFilled(
            exchange.hashOrder(order),
            order.maker,
            taker,
            order.side,
            order.tokenId,
            makerAmountFilled,
            takerAmountFilled,
            fee,
            order.builder,
            order.metadata
        );
    }
}

/*--------------------------------------------------------------
                        COMPLEMENTARY
--------------------------------------------------------------*/

contract MatchOrdersTest_complementary is MatchOrdersTest {
    function test_revert_matchOrdersAndPrepareCombinatorial_notOperator() public {
        Order memory takerOrder;
        Order[] memory makerOrders = new Order[](0);
        uint256[] memory fillAmounts = new uint256[](0);
        uint256[] memory makerFeeAmounts = new uint256[](0);
        PositionId[] memory legs = new PositionId[](0);
        TakerAmounts memory takerAmounts;

        vm.expectRevert(NotOperator.selector);
        vm.prank(makeAddr("nonOperator"));
        exchange.matchOrdersAndPrepareCombinatorial(
            takerOrder, makerOrders, fillAmounts, makerFeeAmounts, takerAmounts, legs
        );
    }

    function test_revert_matchOrdersAndPrepareCombinatorial_paused() public {
        Order memory takerOrder;
        Order[] memory makerOrders = new Order[](0);
        uint256[] memory fillAmounts = new uint256[](0);
        uint256[] memory makerFeeAmounts = new uint256[](0);
        PositionId[] memory legs = new PositionId[](0);
        TakerAmounts memory takerAmounts;

        vm.prank(admin);
        exchange.pauseTrading();

        vm.expectRevert(Paused.selector);
        vm.prank(admin);
        exchange.matchOrdersAndPrepareCombinatorial(
            takerOrder, makerOrders, fillAmounts, makerFeeAmounts, takerAmounts, legs
        );
    }

    function test_matchOrdersAndPrepareCombinatorial() public {
        // Build combinatorial legs and compute position IDs
        PositionId[] memory legs = new PositionId[](1);
        legs[0] = PositionId.wrap(yes);
        ConditionId comboCondId = combinatorialModule.getConditionId(legs);
        uint256 comboYes = PositionId.unwrap(comboCondId.computePositionId(0));

        // Prepare condition, deal bob collateral, deal carla combo YES tokens
        combinatorialModule.prepareCondition(legs);
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        _dealCombinatorialTokens(carla, address(exchange), comboCondId, 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, comboYes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrder(carlaPK, comboYes, 100_000_000, 50_000_000, Side.SELL);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        TakerAmounts memory takerAmounts =
            TakerAmounts({ takerFillAmount: 50_000_000, takerReceiveAmount: 100_000_000, takerFeeAmount: 0 });

        vm.prank(admin);
        exchange.matchOrdersAndPrepareCombinatorial(
            takerOrder, makerOrders, fillAmounts, new uint256[](1), takerAmounts, legs
        );

        assertTrue(combinatorialModule.isConditionPrepared(comboCondId));
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, comboYes, 100_000_000);
        assertCTFBalance(carla, comboYes, 0);
        assertCollateralBalance(carla, 50_000_000);
    }

    function test_complementary() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        _expectOrderFilled(makerOrder, bob, 100_000_000, 50_000_000, 0);
        _expectOrderFilled(takerOrder, address(exchange), 50_000_000, 100_000_000, 0);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCTFBalance(carla, yes, 0);
        assertCollateralBalance(carla, 50_000_000);
        (bool takerFilled,) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertTrue(takerFilled);
        (bool makerFilled,) = exchange.orderStatus(exchange.hashOrder(makerOrder));
        assertTrue(makerFilled);
    }

    function test_complementaryFees() public {
        dealCollateralAndApprove(bob, address(exchange), 52_500_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        uint256 takerFeeAmount = 2_500_000;
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        uint256 makerFeeAmount = 100_000;
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = makerFeeAmount;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, takerFeeAmount, makerFeeAmounts);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCTFBalance(carla, yes, 0);
        assertCollateralBalance(carla, 49_900_000);
        assertCollateralBalance(feeReceiver, takerFeeAmount + makerFeeAmount);
    }

    function test_noExchangeBalance() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        _expectOrderFilled(makerOrder, bob, 100_000_000, 50_000_000, 0);
        _expectOrderFilled(takerOrder, address(exchange), 50_000_000, 100_000_000, 0);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        // Exchange should hold no tokens after match
        assertCollateralBalance(address(exchange), 0);
        assertCTFBalance(address(exchange), yes, 0);
        assertCTFBalance(address(exchange), no, 0);
    }

    function test_revert_complementaryFillExceedsTakerFill_overspend() public {
        dealCollateralAndApprove(bob, address(exchange), 200_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        // Taker is willing to spend 100 collateral for 50 outcome tokens.
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.BUY);
        // Maker execution would consume 150 collateral from the taker.
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 150_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(ComplementaryFillExceedsTakerFill.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_complementaryTracksCollateralSpent_whenPriceImproves() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 40_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        _expectOrderFilled(makerOrder, bob, 100_000_000, 40_000_000, 0);
        _expectOrderFilled(takerOrder, address(exchange), 40_000_000, 100_000_000, 0);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 40_000_000, fillAmounts, 0, makerFeeAmounts);

        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 10_000_000);
        assertCollateralBalance(bob, 10_000_000);
        assertCTFBalance(bob, yes, 100_000_000);
    }

    function test_complementaryFillsWhenFullBudgetSpentAtBetterPrice() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 125_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 125_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 125_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertTrue(filled);
        assertEq(remaining, 0);
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 125_000_000);
    }

    function test_complementaryTracksCumulativeCollateralSpendAcrossFills() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 108_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 501);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, yes, 40_000_000, 16_000_000, Side.SELL, 502);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 40_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 16_000_000, fillAmounts, 0, makerFeeAmounts);

        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 34_000_000);

        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, yes, 68_000_000, 34_000_000, Side.SELL, 503);
        fillAmounts[0] = 68_000_000;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 34_000_000, fillAmounts, 0, makerFeeAmounts);

        (filled, remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertTrue(filled);
        assertEq(remaining, 0);
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 108_000_000);
    }
}

/*--------------------------------------------------------------
                            MINT
--------------------------------------------------------------*/

contract MatchOrdersTest_mint is MatchOrdersTest {
    function test_mint() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, no, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCollateralBalance(carla, 0);
        assertCTFBalance(carla, no, 100_000_000);
    }

    function test_mintRefundedTakerEventReportsNetFill() public {
        dealCollateralAndApprove(bob, address(exchange), 70_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 70_000_000, 100_000_000, Side.BUY, 201);
        Order memory makerOrder = _createAndSignOrderWithSalt(carlaPK, no, 50_000_000, 100_000_000, Side.BUY, 202);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        _expectOrderFilled(makerOrder, bob, 50_000_000, 100_000_000, 0);
        _expectOrderFilled(takerOrder, address(exchange), 50_000_000, 100_000_000, 0);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 70_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCollateralBalance(bob, 20_000_000);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCollateralBalance(carla, 0);
        assertCTFBalance(carla, no, 100_000_000);

        OrderStatus memory takerStatus = exchange.getOrderStatus(exchange.hashOrder(takerOrder));
        assertFalse(takerStatus.filled);
        assertEq(takerStatus.remaining, 20_000_000);
    }

    function test_mintTracksCollateralSpent_whenFundedAtExecutionPrice() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 70_000_000, 100_000_000, Side.BUY, 301);
        Order memory makerOrder = _createAndSignOrderWithSalt(carlaPK, no, 50_000_000, 100_000_000, Side.BUY, 302);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        OrderStatus memory takerStatus = exchange.getOrderStatus(exchange.hashOrder(takerOrder));
        assertFalse(takerStatus.filled);
        assertEq(takerStatus.remaining, 20_000_000);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCollateralBalance(carla, 0);
        assertCTFBalance(carla, no, 100_000_000);
    }

    function test_mintFillsWhenFullBudgetSpentAtBetterPrice() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealCollateralAndApprove(carla, address(exchange), 75_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 351);
        Order memory makerOrder = _createAndSignOrderWithSalt(carlaPK, no, 75_000_000, 125_000_000, Side.BUY, 352);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 75_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        OrderStatus memory takerStatus = exchange.getOrderStatus(exchange.hashOrder(takerOrder));
        assertTrue(takerStatus.filled);
        assertEq(takerStatus.remaining, 0);
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 125_000_000);
        assertCollateralBalance(carla, 0);
        assertCTFBalance(carla, no, 125_000_000);
    }

    function test_mintFees() public {
        dealCollateralAndApprove(bob, address(exchange), 52_500_000);
        dealCollateralAndApprove(carla, address(exchange), 50_100_000);

        uint256 takerFeeAmount = 2_500_000;
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        uint256 makerFeeAmount = 100_000;
        Order memory makerOrder = _createAndSignOrder(carlaPK, no, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = makerFeeAmount;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, takerFeeAmount, makerFeeAmounts);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCollateralBalance(carla, 0);
        assertCTFBalance(carla, no, 100_000_000);
        assertCollateralBalance(feeReceiver, takerFeeAmount + makerFeeAmount);
    }
}

/*--------------------------------------------------------------
                            MERGE
--------------------------------------------------------------*/

contract MatchOrdersTest_merge is MatchOrdersTest {
    function test_merge() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, no, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000);
        assertCTFBalance(carla, no, 0);
        assertCollateralBalance(carla, 50_000_000);
    }

    function test_mergeFees() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        uint256 takerFeeAmount = 2_500_000;
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

        uint256 makerFeeAmount = 100_000;
        Order memory makerOrder = _createAndSignOrder(carlaPK, no, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = makerFeeAmount;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, takerFeeAmount, makerFeeAmounts);

        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 47_500_000);
        assertCTFBalance(carla, no, 0);
        assertCollateralBalance(carla, 49_900_000);
        assertCollateralBalance(feeReceiver, takerFeeAmount + makerFeeAmount);
    }

    function test_revert_mergeCannotConsumeMoreThanTakerFill() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, no, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert();
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_mixedBatchSellCannotConsumeMoreThanTakerFill() public {
        uint256 davePk = 0xDA7E;
        address dave = vm.addr(davePk);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 3401);

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY, 3402);
        makerOrders[1] = _createAndSignOrderWithSalt(davePk, no, 100_000_000, 50_000_000, Side.SELL, 3403);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 50_000_000;
        fillAmounts[1] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](2);

        // Maker1 consumes 100 YES via same-token BUY takingAmount.
        // Maker2 consumes 100 YES via merge.
        // Total taker-token consumption would be 200 YES > takerFillAmount(100 YES).
        vm.expectRevert();
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
                        PARTIAL FILL
--------------------------------------------------------------*/

contract MatchOrdersTest_partialFill is MatchOrdersTest {
    function test_partialFill() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 25_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        // Fill half the taker order
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 25_000_000, fillAmounts, 0, makerFeeAmounts);

        // Taker order partially filled
        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 25_000_000);

        // Balances
        assertCollateralBalance(bob, 25_000_000);
        assertCTFBalance(bob, yes, 50_000_000);
    }
}

/*--------------------------------------------------------------
                          REVERTS
--------------------------------------------------------------*/

contract MatchOrdersTest_reverts is MatchOrdersTest {
    function test_revert_noMakerOrders() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order[] memory makerOrders = new Order[](0);
        uint256[] memory fillAmounts = new uint256[](0);
        uint256[] memory makerFeeAmounts = new uint256[](0);

        vm.expectRevert(NoMakerOrders.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_mismatchedArrayLengths() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](0);
        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(MismatchedArrayLengths.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_takerReceiveAmountMismatch() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(AssetAccountingMismatch.selector);
        vm.prank(admin);
        exchange.matchOrders(
            takerOrder,
            makerOrders,
            fillAmounts,
            makerFeeAmounts,
            TakerAmounts({ takerFillAmount: 50_000_000, takerReceiveAmount: 99_000_000, takerFeeAmount: 0 })
        );
    }

    function test_revert_orderAlreadyFilled() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        vm.expectRevert(OrderAlreadyFilled.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_makingGtRemaining() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 1_000_000_000);

        Order memory buy = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory sell = _createAndSignOrder(carlaPK, yes, 1_000_000_000, 500_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = sell;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 1_000_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(MakingGtRemaining.selector);
        vm.prank(admin);
        _matchOrders(conditionId, buy, makerOrders, 500_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_zeroMakerAmount() public {
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory zeroMakerOrder = _createAndSignOrder(carlaPK, yes, 0, 0, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = zeroMakerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 0;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(ZeroMakerAmount.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_zeroMakerAmount_taker() public {
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory zeroTakerOrder = _createAndSignOrder(bobPK, yes, 0, 0, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(ZeroMakerAmount.selector);
        vm.prank(admin);
        _matchOrders(conditionId, zeroTakerOrder, makerOrders, 0, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_zeroTakerAmount() public {
        Order memory zeroTakerAmountOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 0, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(ZeroTakerAmount.selector);
        vm.prank(admin);
        _matchOrders(conditionId, zeroTakerAmountOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_invalidTokenId_takerNonBinaryPosition() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        uint256 invalidTokenId = PositionId.unwrap(ConditionIdLib.from(conditionId).computePositionId(2));

        Order memory takerOrder = _createAndSignOrder(bobPK, invalidTokenId, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, invalidTokenId, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(InvalidTokenId.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_invalidComplement_makerWrongCondition() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        vm.prank(creator);
        ConditionId otherConditionId = positions.binaryModule.getConditionId("other question");
        uint256 otherNo = PositionId.unwrap(ConditionIdLib.computePositionId(otherConditionId, 1));

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, otherNo, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(InvalidComplement.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_paused() public {
        vm.prank(admin);
        exchange.pauseTrading();

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(Paused.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_userIsPaused() public {
        vm.prank(bob);
        exchange.pauseUser();
        vm.roll(block.number + exchange.userPauseBlockInterval());

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(UserIsPaused.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_notOperator() public {
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order[] memory makerOrders = new Order[](0);
        uint256[] memory fillAmounts = new uint256[](0);
        uint256[] memory makerFeeAmounts = new uint256[](0);

        address nonOperator = makeAddr("nonOperator");

        vm.expectRevert(NotOperator.selector);
        vm.prank(nonOperator);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_invalidSignature() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        // Sign maker order with wrong key
        Order memory makerOrder = _createOrder(carla, yes, 100_000_000, 50_000_000, Side.SELL);
        makerOrder.signature = _signMessage(bobPK, exchange.hashOrder(makerOrder));

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

    function test_revert_invalidSignature_eoaSignerMakerMismatch() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createOrder(bob, yes, 50_000_000, 100_000_000, Side.BUY);
        takerOrder.signer = carla;
        takerOrder.signatureType = SignatureType.EOA;
        takerOrder.signature = _signMessage(carlaPK, exchange.hashOrder(takerOrder));

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

/*--------------------------------------------------------------
              POLY_PROXY AND POLY_GNOSIS_SAFE SIGNATURES
--------------------------------------------------------------*/

/// @notice Tests for POLY_PROXY and POLY_GNOSIS_SAFE signature types
contract MatchOrdersTest_proxyAndSafeSignatures is MatchOrdersTest {
    function test_polyProxySignature() public {
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);
        address proxyWallet = _deployProxy(bob);
        dealCollateralAndApprove(proxyWallet, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignProxyOrder(bobPK, proxyWallet, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCTFBalance(proxyWallet, yes, 100_000_000);
    }

    function test_polyGnosisSafeSignature() public {
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);
        address safeWallet = _deploySafe(bob);
        dealCollateralAndApprove(safeWallet, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignSafeOrder(bobPK, safeWallet, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCTFBalance(safeWallet, yes, 100_000_000);
    }

    function test_revert_polyProxySignature_unrelatedMaker() public {
        Order memory order =
            _createAndSignProxyOrder(bobPK, _deployProxy(carla), yes, 50_000_000, 100_000_000, Side.BUY);

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        exchange.preapproveOrder(order);
    }

    function test_revert_polyGnosisSafeSignature_unrelatedMaker() public {
        Order memory order = _createAndSignSafeOrder(bobPK, _deploySafe(carla), yes, 50_000_000, 100_000_000, Side.BUY);

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        exchange.preapproveOrder(order);
    }
}

/*--------------------------------------------------------------
              COMPLEMENTARY FAST PATH - TAKER SELL
--------------------------------------------------------------*/

/// @notice Tests for complementary fast path taker SELL side fee branches
contract MatchOrdersTest_complementaryTakerSell is MatchOrdersTest {
    // Test complementary fast path with taker SELL and zero taker fee
    function test_complementaryTakerSell_zeroFee() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        // Taker SELL, maker BUY - complementary
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        // Zero taker fee - exercises the if(ctx.takerFee > 0) false branch
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);

        // Verify: bob sold positions and received collateral
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000);
        // carla bought positions
        assertCTFBalance(carla, yes, 100_000_000);
        assertCollateralBalance(carla, 0);
    }

    // Test complementary fast path with taker SELL and non-zero fees
    function test_complementaryTakerSell_withFees() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_100_000); // Extra for fee

        // Taker SELL, maker BUY - complementary
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256 takerFeeAmount = 2_500_000;
        uint256 makerFeeAmount = 100_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = makerFeeAmount;

        _expectOrderFilled(makerOrder, bob, 50_000_000, 100_000_000, makerFeeAmount);
        _expectOrderFilled(takerOrder, address(exchange), 100_000_000, 50_000_000, takerFeeAmount);

        // Non-zero taker fee exercises the if(ctx.takerFee > 0) true branch
        // Non-zero maker fee exercises the if(fee > 0) true branch
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, takerFeeAmount, makerFeeAmounts);

        // Verify: bob sold positions and received collateral minus taker fee
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000 - takerFeeAmount);
        // Carla bought positions, paid maker fee
        assertCTFBalance(carla, yes, 100_000_000);
        // Fee receiver got both fees
        assertCollateralBalance(feeReceiver, takerFeeAmount + makerFeeAmount);
    }

    // Test complementary fast path with taker SELL and zero maker fee
    function test_complementaryTakerSell_zeroMakerFee() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        // Taker SELL, maker BUY - complementary
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0; // Zero maker fee exercises the if(fee > 0) false branch

        uint256 takerFeeAmount = 2_500_000;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, takerFeeAmount, makerFeeAmounts);

        // Verify
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000 - takerFeeAmount);
        assertCollateralBalance(feeReceiver, takerFeeAmount);
    }

    function test_revert_complementaryTakerSell_makerFeeOnlyNotCrossing() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 40_100_000);

        // First principles: taker is offering to sell YES at 0.5 collateral per token, while the
        // maker is only bidding 0.4. The trade must not execute, even if maker fees force the
        // fee-bearing settlement path.
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 40_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 40_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 100_000;

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_complementaryTakerSell_feePathFillExceedsTakerFill() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        // First principles: the operator declared only 90M YES of taker inventory available for
        // this execution. A complementary buy that would consume 100M YES must revert.
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(ComplementaryFillExceedsTakerFill.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 90_000_000, fillAmounts, 1, makerFeeAmounts);
    }

    function test_revert_complementaryTakerSell_zeroFeeNotCrossing() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 40_000_000);

        // Zero-fee complementary sell should still enforce the same crossing rule.
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 40_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 40_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_complementaryTakerSell_zeroFeeFillExceedsTakerFill() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        // Zero-fee routing must still respect the operator-provided taker fill cap.
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(ComplementaryFillExceedsTakerFill.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 90_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
            COMPLEMENTARY FAST PATH - NOT CROSSING
--------------------------------------------------------------*/

/// @notice Tests for NotCrossing revert in complementary fast path
contract MatchOrdersTest_complementaryNotCrossing is MatchOrdersTest {
    function test_revert_complementaryNotCrossing() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        // Taker BUY at 0.5, maker SELL at 0.6 - prices don't cross
        // takerOrder: makerAmount=50, takerAmount=100 => price = 0.5
        // makerOrder: makerAmount=100, takerAmount=60  => price = 0.6
        // Crossing check: taker.makerAmount * maker.makerAmount < taker.takerAmount *
        // maker.takerAmount 50 * 100 < 100 * 60 => 5000 < 6000 => true => revert
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order memory makerOrder = Order({
            salt: 1,
            maker: carla,
            signer: carla,
            tokenId: PositionId.wrap(yes),
            makerAmount: 100_000_000,
            takerAmount: 60_000_000,
            side: Side.SELL,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        makerOrder.signature = _signMessage(carlaPK, exchange.hashOrder(makerOrder));

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
    BATCH MATCH - _validateTakerBuyMaker NotCrossing
--------------------------------------------------------------*/

/// @notice Tests for NotCrossing reverts in _validateTakerBuyMaker
///         via the batch-match path.
///         The batch path is forced by including a maker with the
///         same side as the taker (breaking _isAllComplementary).
contract MatchOrdersTest_batchMatchTakerBuy is MatchOrdersTest {
    // Taker BUY, maker SELL same tokenId, prices don't cross.
    // Uses two makers: Maker1=SELL YES (bad price), Maker2=BUY NO (breaks complementary).
    function test_revert_batchTakerBuy_makerSell_notCrossing() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        // Also fund a second maker (BUY NO) so _isAllComplementary returns false
        uint256 dummyPK = 0xD00D;
        address dummy = vm.addr(dummyPK);
        dealCollateralAndApprove(dummy, address(exchange), 50_000_000);
        vm.prank(admin);
        exchange.addOperator(dummy);

        // Taker: BUY YES, price = 50/100 = 0.50
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        // Maker1: SELL YES at price = 100/60 => taker wants to pay 0.50 per token,
        // maker wants 0.60 per token -> not crossing.
        // Crossing check: taker.makerAmount * maker.makerAmount < taker.takerAmount *
        // maker.takerAmount: 50M * 100M = 5e15 < 100M * 60M = 6e15 => true => NotCrossing
        Order memory maker1 = Order({
            salt: 1,
            maker: carla,
            signer: carla,
            tokenId: PositionId.wrap(yes),
            makerAmount: 100_000_000,
            takerAmount: 60_000_000,
            side: Side.SELL,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        maker1.signature = _signMessage(carlaPK, exchange.hashOrder(maker1));

        // Maker2: BUY NO (same side as taker -> breaks _isAllComplementary)
        Order memory maker2 = Order({
            salt: 2,
            maker: dummy,
            signer: dummy,
            tokenId: PositionId.wrap(no),
            makerAmount: 50_000_000,
            takerAmount: 100_000_000,
            side: Side.BUY,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        maker2.signature = _signMessage(dummyPK, exchange.hashOrder(maker2));

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = maker1;
        makerOrders[1] = maker2;

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 100_000_000;
        fillAmounts[1] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](2);
        makerFeeAmounts[0] = 0;
        makerFeeAmounts[1] = 0;

        // Should revert on maker1 with NotCrossing (same-token price check)
        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    // Taker BUY, maker BUY complement token, not crossing.
    // _validateTakerBuyMaker complement branch:
    // taker.takerAmount * maker.makerAmount + maker.takerAmount * taker.makerAmount
    //   < taker.takerAmount * maker.takerAmount
    function test_revert_batchTakerBuy_makerBuyComplement_notCrossing() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);

        uint256 dummyPK = 0xD00D;
        address dummy = vm.addr(dummyPK);
        dealCollateralAndApprove(dummy, address(exchange), 50_000_000);
        vm.prank(admin);
        exchange.addOperator(dummy);

        // Also need a SELL maker to break complementary (all same-side = complementary)
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        // Taker: BUY YES at price 0.50
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        // Maker1: BUY NO (complement) at price 0.30 (too cheap complement -> not crossing)
        // For BUY complement crossing:
        // taker.takerAmount * maker.makerAmount + maker.takerAmount * taker.makerAmount
        //   < taker.takerAmount * maker.takerAmount
        // 100M * 30M + 100M * 50M < 100M * 100M
        // 3e15 + 5e15 < 1e16
        // 8e15 < 1e16 => true => NotCrossing (complement price check)
        Order memory maker1 = Order({
            salt: 1,
            maker: dummy,
            signer: dummy,
            tokenId: PositionId.wrap(no),
            makerAmount: 30_000_000,
            takerAmount: 100_000_000,
            side: Side.BUY,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        maker1.signature = _signMessage(dummyPK, exchange.hashOrder(maker1));

        // Maker2: SELL YES (breaks _isAllComplementary since maker has same tokenId
        // but SELL, while BUY NO also exists with different tokenId)
        Order memory maker2 = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = maker1;
        makerOrders[1] = maker2;

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 30_000_000;
        fillAmounts[1] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](2);
        makerFeeAmounts[0] = 0;
        makerFeeAmounts[1] = 0;

        // Should revert on maker1 with NotCrossing (complement price check)
        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
  BATCH MATCH - _validateTakerSellMaker NotCrossing
--------------------------------------------------------------*/

/// @notice Tests for NotCrossing reverts in _validateTakerSellMaker
///         via the batch-match path.
contract MatchOrdersTest_batchMatchTakerSell is MatchOrdersTest {
    // Taker SELL, maker BUY same tokenId, prices don't cross.
    function test_revert_batchTakerSell_makerBuy_notCrossing() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 40_000_000);

        // Need a second maker to break complementary
        uint256 dummyPK = 0xD00D;
        address dummy = vm.addr(dummyPK);
        dealOutcomeTokensAndApprove(dummy, address(exchange), 50_000_000);
        vm.prank(admin);
        exchange.addOperator(dummy);

        // Taker: SELL YES, wants 50M collateral for 100M tokens (price 0.50)
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

        // Maker1: BUY YES at price = 40/100 = 0.40 (too low for taker -> not crossing)
        // Crossing check (taker SELL, maker BUY, same tokenId):
        // taker.makerAmount * maker.makerAmount < taker.takerAmount * maker.takerAmount
        // 100M * 40M = 4e15 < 50M * 100M = 5e15 => true => NotCrossing
        Order memory maker1 = Order({
            salt: 1,
            maker: carla,
            signer: carla,
            tokenId: PositionId.wrap(yes),
            makerAmount: 40_000_000,
            takerAmount: 100_000_000,
            side: Side.BUY,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        maker1.signature = _signMessage(carlaPK, exchange.hashOrder(maker1));

        // Maker2: SELL NO (same side as taker -> breaks complementary)
        Order memory maker2 = Order({
            salt: 2,
            maker: dummy,
            signer: dummy,
            tokenId: PositionId.wrap(no),
            makerAmount: 50_000_000,
            takerAmount: 50_000_000,
            side: Side.SELL,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        maker2.signature = _signMessage(dummyPK, exchange.hashOrder(maker2));

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = maker1;
        makerOrders[1] = maker2;

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](2);
        makerFeeAmounts[0] = 0;
        makerFeeAmounts[1] = 0;

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    // Taker SELL, maker SELL complement token, not crossing.
    // _validateTakerSellMaker complement branch:
    // taker.makerAmount * maker.makerAmount + maker.takerAmount * taker.makerAmount
    //   > taker.makerAmount * maker.makerAmount
    // Actually the formula:
    // if (takerOrder.takerAmount * makerOrder.makerAmount + makerOrder.takerAmount
    //         * takerOrder.makerAmount > takerOrder.makerAmount * makerOrder.makerAmount)
    //   revert NotCrossing();
    function test_revert_batchTakerSell_makerSellComplement_notCrossing() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);

        uint256 dummyPK = 0xD00D;
        address dummy = vm.addr(dummyPK);
        dealOutcomeTokensAndApprove(dummy, address(exchange), 100_000_000);
        vm.prank(admin);
        exchange.addOperator(dummy);

        // Also need a BUY maker to break complementary
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        // Taker: SELL YES, wants 50M for 100M (price = 0.50)
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

        // Maker1: SELL NO complement at price = 100/80 = 1.25 (asking too much)
        // For SELL complement crossing check:
        // taker.takerAmount * maker.makerAmount + maker.takerAmount * taker.makerAmount
        //   > taker.makerAmount * maker.makerAmount
        // 50M * 100M + 80M * 100M > 100M * 100M
        // 5e15 + 8e15 > 1e16
        // 1.3e16 > 1e16 => true => NotCrossing (complement price check)
        Order memory maker1 = Order({
            salt: 1,
            maker: dummy,
            signer: dummy,
            tokenId: PositionId.wrap(no),
            makerAmount: 100_000_000,
            takerAmount: 80_000_000,
            side: Side.SELL,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        maker1.signature = _signMessage(dummyPK, exchange.hashOrder(maker1));

        // Maker2: BUY YES (breaks _isAllComplementary)
        Order memory maker2 = Order({
            salt: 2,
            maker: carla,
            signer: carla,
            tokenId: PositionId.wrap(yes),
            makerAmount: 50_000_000,
            takerAmount: 100_000_000,
            side: Side.BUY,
            signatureType: SignatureType.EOA,
            timestamp: block.timestamp,
            metadata: bytes32(0),
            builder: bytes32(0),
            signature: ""
        });
        maker2.signature = _signMessage(carlaPK, exchange.hashOrder(maker2));

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = maker1;
        makerOrders[1] = maker2;

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 100_000_000;
        fillAmounts[1] = 50_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](2);
        makerFeeAmounts[0] = 0;
        makerFeeAmounts[1] = 0;

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    /// @notice Batch sell reverts when maker fill amounts do not sum to the taker fill amount.
    function test_revert_batchTakerSell_takerFillMismatch() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        uint256 dummyPK = 0xD00D;
        address dummy = vm.addr(dummyPK);
        dealOutcomeTokensAndApprove(dummy, address(exchange), 50_000_000);
        vm.prank(admin);
        exchange.addOperator(dummy);

        // Taker: SELL 100M YES, wants 50M collateral (price 0.50)
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

        // Maker1: BUY YES at price 0.50 — crossing
        Order memory maker1 = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        // Maker2: SELL NO at price 0.40 — complement SELL, crosses (YES 0.50 + NO 0.40 < 1.0)
        Order memory maker2 = _createAndSignOrderWithSalt(dummyPK, no, 50_000_000, 20_000_000, Side.SELL, 2);

        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = maker1;
        makerOrders[1] = maker2;

        // BUY maker: fill=25M, taking = 25M * 100M / 50M = 50M positions
        // SELL maker: fill=25M NO tokens => 25M consumed
        // Total consumed = 50M + 25M = 75M, but takerFillAmount = 100M => mismatch
        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 25_000_000;
        fillAmounts[1] = 25_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](2);

        vm.expectRevert(TakerFillMismatch.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
    _isValidSignature FALLTHROUGH AND _computeStructHash
--------------------------------------------------------------*/

/// @notice Documents that the `return false` fallthrough in _isValidSignature
///         is unreachable because SignatureType is an enum with only 4 variants
///         (EOA, POLY_PROXY, POLY_GNOSIS_SAFE, POLY_1271) and all are handled
///         before the fallthrough. Solidity enforces enum bounds at ABI decoding.
///         Similarly, _computeStructHash is a pure assembly block that
///         forge coverage cannot track into. Both are SKIPPED.

/*--------------------------------------------------------------
                  BRANCH COVERAGE: FEE VALIDATION
--------------------------------------------------------------*/

contract MatchOrdersTest_feeValidation is MatchOrdersTest {
    /// @dev Redeploys the exchange with a custom max fee rate and re-registers operators.
    function _useExchangeWithRate(uint256 _rate) internal {
        exchange = _deployExchange(_rate);
        vm.startPrank(admin);
        exchange.addOperator(admin);
        exchange.addOperator(bob);
        exchange.addOperator(carla);
        vm.stopPrank();
    }

    function test_revert_feeExceedsMaxRate_buyOrder() public {
        // Deploy exchange with a tight fee rate (1%)
        _useExchangeWithRate(100);

        dealCollateralAndApprove(bob, address(exchange), 51_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        // 1% of 50M = 500K max. Try 1M taker fee → should revert
        vm.expectRevert(FeeExceedsMaxRate.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 1_000_000, makerFeeAmounts);
    }

    function test_revert_feeExceedsMaxRate_sellOrder() public {
        _useExchangeWithRate(100);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        // SELL cashValue = 100M * 50M / 100M = 50M. 1% of 50M = 500K. Try 1M.
        vm.expectRevert(FeeExceedsMaxRate.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 1_000_000, makerFeeAmounts);
    }

    function test_revert_makerFeeExceedsMaxRate() public {
        _useExchangeWithRate(200);

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        // Taker BUY fills a SELL maker. Maker's fillAmount is 100M tokens; cashValue for a SELL
        // maker = takingAmount = 50M collateral. Max allowed maker fee at 200 bps = 1M.
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order memory makerOrder = _createAndSignOrderWithSalt(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL, 2);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 1_100_000; // exceeds 200 bps of 50M = 1M

        vm.expectRevert(FeeExceedsMaxRate.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_maxFeeRateZero_disablesEnforcement() public {
        _useExchangeWithRate(0);

        dealCollateralAndApprove(bob, address(exchange), 60_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        // Large fee should pass when maxFeeRate = 0
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 5_000_000, makerFeeAmounts);
    }

    function test_takerSellSurplusFeeValidationUsesActualProceeds() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 40_000);
        dealCollateralAndApprove(carla, address(exchange), 23_600);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 40_000, 400, Side.SELL, 7401);
        Order memory makerOrder = _createAndSignOrderWithSalt(carlaPK, yes, 23_600, 40_000, Side.BUY, 7402);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 23_600;

        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 40_000, fillAmounts, 690, makerFeeAmounts);

        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 22_910);
        assertCTFBalance(carla, yes, 40_000);
        assertCollateralBalance(carla, 0);
        assertCollateralBalance(feeReceiver, 690);
    }

    function test_revert_feeExceedsProceeds_batchSell() public {
        // Disable fee rate check so FeeExceedsProceeds can trigger
        _useExchangeWithRate(0);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 7001);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, no, 100_000_000, 50_000_000, Side.SELL, 7002);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        // takerTaking = 50M. Fee of 60M > 50M → FeeExceedsProceeds
        vm.expectRevert(FeeExceedsProceeds.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 60_000_000, makerFeeAmounts);
    }

    function test_revert_feeExceedsProceeds_complementarySell() public {
        _useExchangeWithRate(0);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        // takerTaking = 50M from one maker. Fee 60M > 50M.
        vm.expectRevert(FeeExceedsProceeds.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 60_000_000, makerFeeAmounts);
    }

    function test_validateFee_externalView() public view {
        // Should not revert: 500 fee on 10000 value at 10% (default) = max 1000
        exchange.validateFee(500, 10_000);
    }

    function test_revert_complementaryTakerFeeValidatedAgainstActualFill() public {
        // maxFeeRate = 5%. Taker requests fill=1000, fee=50 (5% of 1000).
        // But only 100 is actually filled → effective rate is 50%.
        // Must revert because 50 > 5% of 100 = 5.
        _useExchangeWithRate(500);

        dealCollateralAndApprove(bob, address(exchange), 1050);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 1000, 2000, Side.BUY, 9901);
        // Maker only fills 100 positions (small partial fill)
        Order memory makerOrder = _createAndSignOrderWithSalt(carlaPK, yes, 100, 50, Side.SELL, 9902);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        // Fee 50 passes against takerFillAmount=1000 (5%), but fails
        // against actual fill takerMakingAmount=50 (100% > 5%)
        vm.expectRevert(FeeExceedsMaxRate.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 1000, fillAmounts, 50, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
             BRANCH COVERAGE: VALIDATE ORDER VIEW
--------------------------------------------------------------*/

contract MatchOrdersTest_validateOrderBranches is MatchOrdersTest {
    function test_revert_validateOrder_alreadyFilled() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        // Order is now filled, validateOrder should revert
        vm.expectRevert(OrderAlreadyFilled.selector);
        exchange.validateOrder(takerOrder);
    }

    function test_revert_validateOrder_userPaused() public {
        vm.prank(bob);
        exchange.pauseUser();
        vm.roll(block.number + exchange.userPauseBlockInterval());

        Order memory order = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        vm.expectRevert(UserIsPaused.selector);
        exchange.validateOrder(order);
    }
}

/*--------------------------------------------------------------
        BRANCH COVERAGE: COMPLEMENT VALIDATION
--------------------------------------------------------------*/

contract MatchOrdersTest_complementValidation is MatchOrdersTest {
    function test_revert_invalidComplement_sameOutcome() public {
        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        // Both BUY YES → same outcome index, not complement
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 6001);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, yes, 50_000_000, 100_000_000, Side.BUY, 6002);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(InvalidComplement.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_notCrossing_mintPath() public {
        dealCollateralAndApprove(bob, address(exchange), 30_000_000);
        dealCollateralAndApprove(carla, address(exchange), 30_000_000);

        // Taker BUY YES price=0.30, Maker BUY NO price=0.30. Sum=0.60 < 1 → not crossing
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 30_000_000, 100_000_000, Side.BUY, 6101);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, no, 30_000_000, 100_000_000, Side.BUY, 6102);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 30_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 30_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_notCrossing_mergePath() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        // Taker SELL YES price=0.70, Maker SELL NO price=0.70. Sum=1.40 > 1 → not crossing for merge
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 70_000_000, Side.SELL, 6201);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, no, 100_000_000, 70_000_000, Side.SELL, 6202);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_mismatchedTokenIds_batchSellBuyMaker() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 50_000_000);

        // Taker SELL YES, Maker BUY NO → different tokenId for same-side check
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 6301);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, no, 50_000_000, 100_000_000, Side.BUY, 6302);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(MismatchedTokenIds.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_notCrossing_batchBuySellMaker() public {
        dealCollateralAndApprove(bob, address(exchange), 10_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        // Taker BUY YES at 0.10, Maker SELL YES at 0.90 → not crossing
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 10_000_000, 100_000_000, Side.BUY, 6401);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(carlaPK, yes, 100_000_000, 90_000_000, Side.SELL, 6402);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 10_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
   BRANCH COVERAGE: COMPLEMENTARY SELL NOT CROSSING
--------------------------------------------------------------*/

contract MatchOrdersTest_complementarySellNotCrossing is MatchOrdersTest {
    function test_revert_complementarySellNotCrossing_withFees() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 30_000_000);

        // Taker SELL YES at 0.60, Maker BUY YES at 0.30 → not crossing
        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 60_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 30_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 30_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 100_000;

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 100_000, makerFeeAmounts);
    }

    function test_revert_complementarySellNotCrossing_zeroFee() public {
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(carla, address(exchange), 30_000_000);

        Order memory takerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 60_000_000, Side.SELL);
        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 30_000_000, 100_000_000, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 30_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);

        vm.expectRevert(NotCrossing.selector);
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

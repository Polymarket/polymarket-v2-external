// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BaseExchangeTest } from "./BaseExchangeTest.sol";
import { Exchange } from "@polymarket-v2/src/exchange/Exchange.sol";
import { Order, Side } from "@polymarket-v2/src/exchange/OrderStructs.sol";

contract MatchOrdersBalanceFlowsTest is BaseExchangeTest {
    uint256 internal constant DAVE_PK = 0xDA7E;
    uint256 internal constant ERIN_PK = 0xE712;
    uint256 internal constant FRANK_PK = 0xF12A;

    function _runMatch(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory fillAmounts,
        uint256 takerFee,
        uint256[] memory makerFees
    ) internal {
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, takerFillAmount, fillAmounts, takerFee, makerFees);
    }

    function _assertExchangeEmpty() internal view {
        assertCollateralBalance(address(exchange), 0);
        assertCTFBalance(address(exchange), yes, 0);
        assertCTFBalance(address(exchange), no, 0);
    }
}

/*--------------------------------------------------------------
                        COMPLEMENTARY
--------------------------------------------------------------*/

contract MatchOrdersBalanceFlowsTest_complementary is MatchOrdersBalanceFlowsTest {
    function test_takerBuyTwoMakers() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 40_000_000);
        dealOutcomeTokensAndApprove(erin, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 1101);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 40_000_000, 20_000_000, Side.SELL, 1102);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, yes, 60_000_000, 30_000_000, Side.SELL, 1103);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFees);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 20_000_000);
        assertCTFBalance(erin, yes, 0);
        assertCollateralBalance(erin, 30_000_000);
        _assertExchangeEmpty();
    }

    function test_takerSellTwoMakers() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 20_000_000);
        dealCollateralAndApprove(erin, address(exchange), 30_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 1201);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 20_000_000, 40_000_000, Side.BUY, 1202);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, yes, 30_000_000, 60_000_000, Side.BUY, 1203);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 30_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000);
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, yes, 60_000_000);
        _assertExchangeEmpty();
    }

    function test_takerBuyTwoMakersWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 takerFee = 2_000_000;
        uint256 makerFee1 = 1_000_000;
        uint256 makerFee2 = 500_000;

        dealCollateralAndApprove(bob, address(exchange), 52_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 40_000_000);
        dealOutcomeTokensAndApprove(erin, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 2101);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 40_000_000, 20_000_000, Side.SELL, 2102);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, yes, 60_000_000, 30_000_000, Side.SELL, 2103);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = makerFee1;
        makerFees[1] = makerFee2;

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, takerFee, makerFees);

        // Taker: paid 52M collateral (50M fill + fees flow), received 100M YES
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        // Maker1: sold 40M YES, received taking(20M) - fee(1M) = 19M collateral
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 19_000_000);
        // Maker2: sold 60M YES, received taking(30M) - fee(500K) = 29.5M collateral
        assertCTFBalance(erin, yes, 0);
        assertCollateralBalance(erin, 29_500_000);
        // Fee receiver: takerFee(2M) + makerFee1(1M) + makerFee2(500K) = 3.5M
        assertCollateralBalance(feeReceiver, takerFee + makerFee1 + makerFee2);
        _assertExchangeEmpty();
    }

    function test_takerSellTwoMakersWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 takerFee = 2_000_000;
        uint256 makerFee1 = 1_000_000;
        uint256 makerFee2 = 500_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 21_000_000);
        dealCollateralAndApprove(erin, address(exchange), 30_500_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 2201);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 20_000_000, 40_000_000, Side.BUY, 2202);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, yes, 30_000_000, 60_000_000, Side.BUY, 2203);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 30_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = makerFee1;
        makerFees[1] = makerFee2;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, takerFee, makerFees);

        // Taker: sold 100M YES, received takerTaking(50M) - takerFee(2M) = 48M collateral
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 48_000_000);
        // Maker1: paid 20M+1M=21M collateral, received 40M YES
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        // Maker2: paid 30M+500K=30.5M collateral, received 60M YES
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, yes, 60_000_000);
        // Fee receiver: takerFee(2M) + makerFee1(1M) + makerFee2(500K) = 3.5M
        assertCollateralBalance(feeReceiver, takerFee + makerFee1 + makerFee2);
        _assertExchangeEmpty();
    }

    function test_complementaryBuyTakerFeeOnly() public {
        address dave = vm.addr(DAVE_PK);

        uint256 takerFee = 2_000_000;

        dealCollateralAndApprove(bob, address(exchange), 52_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 2901);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 100_000_000, 50_000_000, Side.SELL, 2902);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFees = new uint256[](1);
        makerFees[0] = 0;

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, takerFee, makerFees);

        // Taker: paid 52M (50M taking + 2M taker fee), received 100M YES
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        // Maker: sold 100M YES, received full taking(50M) (zero maker fee)
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 50_000_000);
        // Fee receiver: taker fee only
        assertCollateralBalance(feeReceiver, takerFee);
        _assertExchangeEmpty();
    }

    function test_complementaryBuyMakerFeeOnly() public {
        address dave = vm.addr(DAVE_PK);

        uint256 makerFee = 1_000_000;

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 100_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 2911);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 100_000_000, 50_000_000, Side.SELL, 2912);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFees = new uint256[](1);
        makerFees[0] = makerFee;

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFees);

        // Taker: paid 50M (maker fee deducted from maker proceeds, not taker cost)
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        // Maker: sold 100M YES, received taking(50M) - makerFee(1M) = 49M
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 49_000_000);
        // Fee receiver: maker fee only (totalFees = 0 taker + 1M maker)
        assertCollateralBalance(feeReceiver, makerFee);
        _assertExchangeEmpty();
    }

    function test_complementarySellMakerFeeOnly() public {
        address dave = vm.addr(DAVE_PK);

        uint256 makerFee = 1_000_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 51_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 2921);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 50_000_000, 100_000_000, Side.BUY, 2922);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 50_000_000;

        uint256[] memory makerFees = new uint256[](1);
        makerFees[0] = makerFee;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        // First principles: maker fees are paid on top of maker proceeds, not deducted from the
        // taker's sale proceeds. The taker should still receive the full crossed amount.
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000);
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 100_000_000);
        assertCollateralBalance(feeReceiver, makerFee);
        _assertExchangeEmpty();
    }

    function test_complementarySellMixedMakerFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 makerFee = 500_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 20_000_000);
        dealCollateralAndApprove(erin, address(exchange), 30_500_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 2931);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 20_000_000, 40_000_000, Side.BUY, 2932);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, yes, 30_000_000, 60_000_000, Side.BUY, 2933);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 30_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = 0;
        makerFees[1] = makerFee;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        // The nonzero fee on maker 2 must force the fee-bearing path. The taker still receives
        // the full crossed proceeds, while only maker 2 pays the fee on top.
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000);
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, yes, 60_000_000);
        assertCollateralBalance(feeReceiver, makerFee);
        _assertExchangeEmpty();
    }
}

/*--------------------------------------------------------------
                            MINT
--------------------------------------------------------------*/

contract MatchOrdersBalanceFlowsTest_mint is MatchOrdersBalanceFlowsTest {
    function test_twoMakers() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealCollateralAndApprove(dave, address(exchange), 20_000_000);
        dealCollateralAndApprove(erin, address(exchange), 30_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 1301);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, no, 20_000_000, 40_000_000, Side.BUY, 1302);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 30_000_000, 60_000_000, Side.BUY, 1303);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 30_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFees);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, no, 40_000_000);
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, no, 60_000_000);
        _assertExchangeEmpty();
    }

    function test_twoMakersWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 takerFee = 2_000_000;
        uint256 makerFee1 = 1_000_000;
        uint256 makerFee2 = 500_000;

        dealCollateralAndApprove(bob, address(exchange), 52_000_000);
        dealCollateralAndApprove(dave, address(exchange), 21_000_000);
        dealCollateralAndApprove(erin, address(exchange), 30_500_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 2301);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, no, 20_000_000, 40_000_000, Side.BUY, 2302);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 30_000_000, 60_000_000, Side.BUY, 2303);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 30_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = makerFee1;
        makerFees[1] = makerFee2;

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, takerFee, makerFees);

        // Split 100M collateral → 100M YES + 100M NO
        // Taker: paid 52M collateral (50M + 2M fee), received 100M YES
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        // Maker1: paid 21M collateral (20M + 1M fee), received 40M NO
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, no, 40_000_000);
        // Maker2: paid 30.5M collateral (30M + 500K fee), received 60M NO
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, no, 60_000_000);
        // Fee receiver: 2M + 1M + 500K = 3.5M
        assertCollateralBalance(feeReceiver, takerFee + makerFee1 + makerFee2);
        _assertExchangeEmpty();
    }
}

/*--------------------------------------------------------------
                            MERGE
--------------------------------------------------------------*/

contract MatchOrdersBalanceFlowsTest_merge is MatchOrdersBalanceFlowsTest {
    function test_twoMakers() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 40_000_000);
        dealOutcomeTokensAndApprove(erin, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 1401);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, no, 40_000_000, 20_000_000, Side.SELL, 1402);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 60_000_000, 30_000_000, Side.SELL, 1403);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000);
        assertCTFBalance(dave, no, 0);
        assertCollateralBalance(dave, 20_000_000);
        assertCTFBalance(erin, no, 0);
        assertCollateralBalance(erin, 30_000_000);
        _assertExchangeEmpty();
    }

    function test_twoMakersWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 takerFee = 2_000_000;
        uint256 makerFee1 = 1_000_000;
        uint256 makerFee2 = 500_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 40_000_000);
        dealOutcomeTokensAndApprove(erin, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 2401);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, no, 40_000_000, 20_000_000, Side.SELL, 2402);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 60_000_000, 30_000_000, Side.SELL, 2403);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = makerFee1;
        makerFees[1] = makerFee2;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, takerFee, makerFees);

        // Merge 100M YES + 100M NO → 100M collateral
        // Taker: sold 100M YES, received taking(50M) - takerFee(2M) = 48M
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 48_000_000);
        // Maker1: sold 40M NO, received taking(20M) - fee(1M) = 19M
        assertCTFBalance(dave, no, 0);
        assertCollateralBalance(dave, 19_000_000);
        // Maker2: sold 60M NO, received taking(30M) - fee(500K) = 29.5M
        assertCTFBalance(erin, no, 0);
        assertCollateralBalance(erin, 29_500_000);
        // Fee receiver: makerFees(1.5M) + takerFee(2M) = 3.5M
        assertCollateralBalance(feeReceiver, takerFee + makerFee1 + makerFee2);
        _assertExchangeEmpty();
    }
}

/*--------------------------------------------------------------
                        MIXED PATH
--------------------------------------------------------------*/

contract MatchOrdersBalanceFlowsTest_mixedPath is MatchOrdersBalanceFlowsTest {
    function test_comboComplementaryMintWithFees() public {
        // Redeploy with rate 0 so the fee accounting test is not constrained by it
        exchange = _deployExchange(0);
        vm.startPrank(admin);
        exchange.addOperator(admin);
        exchange.addOperator(bob);
        exchange.addOperator(carla);
        vm.stopPrank();

        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 takerFee = 3_000_000;
        uint256 makerSellFee = 2_000_000;
        uint256 makerBuyFee = 1_000_000;

        dealCollateralAndApprove(bob, address(exchange), 53_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 40_000_000);
        dealCollateralAndApprove(erin, address(exchange), 31_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 1701);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 40_000_000, 20_000_000, Side.SELL, 1702);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 30_000_000, 60_000_000, Side.BUY, 1703);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 30_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = makerSellFee;
        makerFees[1] = makerBuyFee;

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, takerFee, makerFees);

        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 18_000_000);
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, no, 60_000_000);
        assertCollateralBalance(feeReceiver, takerFee + makerSellFee + makerBuyFee);
        _assertExchangeEmpty();
    }

    function test_comboComplementaryMerge() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 20_000_000);
        dealOutcomeTokensAndApprove(erin, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 1601);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 20_000_000, 40_000_000, Side.BUY, 1602);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 60_000_000, 30_000_000, Side.SELL, 1603);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 50_000_000);
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        assertCTFBalance(erin, no, 0);
        assertCollateralBalance(erin, 30_000_000);
        _assertExchangeEmpty();
    }

    function test_comboComplementaryMintNoFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 40_000_000);
        dealCollateralAndApprove(erin, address(exchange), 30_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 2501);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 40_000_000, 20_000_000, Side.SELL, 2502);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 30_000_000, 60_000_000, Side.BUY, 2503);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 30_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFees);

        // Split 60M → 60M YES + 60M NO. Total YES = 40M(comp) + 60M(split) = 100M
        // Taker: paid 50M collateral, received 100M YES
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        // Maker1 (comp SELL): sold 40M YES, received 20M collateral
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 20_000_000);
        // Maker2 (mint BUY): paid 30M collateral, received 60M NO
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, no, 60_000_000);
        _assertExchangeEmpty();
    }

    function test_comboComplementaryMergeWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 takerFee = 2_000_000;
        uint256 makerFee1 = 1_000_000;
        uint256 makerFee2 = 500_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 21_000_000);
        dealOutcomeTokensAndApprove(erin, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 2601);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 20_000_000, 40_000_000, Side.BUY, 2602);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 60_000_000, 30_000_000, Side.SELL, 2603);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = makerFee1;
        makerFees[1] = makerFee2;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, takerFee, makerFees);

        // Merge 60M YES + 60M NO → 60M collateral (non-optimized path)
        // Taker: sold 100M YES, received taking(50M) - takerFee(2M) = 48M
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 48_000_000);
        // Maker1 (comp BUY): paid 21M collateral (20M + 1M fee), received 40M YES
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        // Maker2 (merge SELL): sold 60M NO, received taking(30M) - fee(500K) = 29.5M
        assertCTFBalance(erin, no, 0);
        assertCollateralBalance(erin, 29_500_000);
        // Fee receiver: makerFees(1.5M) + takerFee(2M) = 3.5M
        assertCollateralBalance(feeReceiver, takerFee + makerFee1 + makerFee2);
        _assertExchangeEmpty();
    }

    function test_threeMakersCompMintWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);
        address frank = vm.addr(FRANK_PK);

        uint256 takerFee = 1_000_000;
        uint256 makerFee1 = 500_000;
        uint256 makerFee2 = 300_000;
        uint256 makerFee3 = 200_000;

        dealCollateralAndApprove(bob, address(exchange), 51_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 40_000_000);
        dealCollateralAndApprove(erin, address(exchange), 15_300_000);
        dealCollateralAndApprove(frank, address(exchange), 15_200_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 2701);
        Order[] memory makerOrders = new Order[](3);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 40_000_000, 20_000_000, Side.SELL, 2702);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 15_000_000, 30_000_000, Side.BUY, 2703);
        makerOrders[2] = _createAndSignOrderWithSalt(FRANK_PK, no, 15_000_000, 30_000_000, Side.BUY, 2704);

        uint256[] memory fillAmounts = new uint256[](3);
        fillAmounts[0] = 40_000_000;
        fillAmounts[1] = 15_000_000;
        fillAmounts[2] = 15_000_000;

        uint256[] memory makerFees = new uint256[](3);
        makerFees[0] = makerFee1;
        makerFees[1] = makerFee2;
        makerFees[2] = makerFee3;

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, takerFee, makerFees);

        // Split 60M → 60M YES + 60M NO. Total YES = 40M(comp) + 60M(split) = 100M
        // Taker: paid 51M collateral (50M + 1M fee), received 100M YES
        assertCollateralBalance(bob, 0);
        assertCTFBalance(bob, yes, 100_000_000);
        // Maker1 (comp SELL): sold 40M YES, got taking(20M) - fee(500K) = 19.5M
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 19_500_000);
        // Maker2 (mint BUY): paid 15.3M collateral (15M + 300K fee), received 30M NO
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, no, 30_000_000);
        // Maker3 (mint BUY): paid 15.2M collateral (15M + 200K fee), received 30M NO
        assertCollateralBalance(frank, 0);
        assertCTFBalance(frank, no, 30_000_000);
        // Fee receiver: 1M + 500K + 300K + 200K = 2M
        assertCollateralBalance(feeReceiver, takerFee + makerFee1 + makerFee2 + makerFee3);
        _assertExchangeEmpty();
    }

    function test_threeMakersCompMergeWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);
        address frank = vm.addr(FRANK_PK);

        uint256 takerFee = 1_000_000;
        uint256 makerFee1 = 500_000;
        uint256 makerFee2 = 300_000;
        uint256 makerFee3 = 200_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 20_500_000);
        dealOutcomeTokensAndApprove(erin, address(exchange), 30_000_000);
        dealOutcomeTokensAndApprove(frank, address(exchange), 30_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 2801);
        Order[] memory makerOrders = new Order[](3);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 20_000_000, 40_000_000, Side.BUY, 2802);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 30_000_000, 15_000_000, Side.SELL, 2803);
        makerOrders[2] = _createAndSignOrderWithSalt(FRANK_PK, no, 30_000_000, 15_000_000, Side.SELL, 2804);

        uint256[] memory fillAmounts = new uint256[](3);
        fillAmounts[0] = 20_000_000;
        fillAmounts[1] = 30_000_000;
        fillAmounts[2] = 30_000_000;

        uint256[] memory makerFees = new uint256[](3);
        makerFees[0] = makerFee1;
        makerFees[1] = makerFee2;
        makerFees[2] = makerFee3;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, takerFee, makerFees);

        // Merge 60M YES + 60M NO → 60M collateral (non-optimized path)
        // Taker: sold 100M YES, received taking(50M) - takerFee(1M) = 49M
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 49_000_000);
        // Maker1 (comp BUY): paid 20.5M collateral (20M + 500K fee), received 40M YES
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        // Maker2 (merge SELL): sold 30M NO, got taking(15M) - fee(300K) = 14.7M
        assertCTFBalance(erin, no, 0);
        assertCollateralBalance(erin, 14_700_000);
        // Maker3 (merge SELL): sold 30M NO, got taking(15M) - fee(200K) = 14.8M
        assertCTFBalance(frank, no, 0);
        assertCollateralBalance(frank, 14_800_000);
        // Fee receiver: 1M + 500K + 300K + 200K = 2M
        assertCollateralBalance(feeReceiver, takerFee + makerFee1 + makerFee2 + makerFee3);
        _assertExchangeEmpty();
    }
}

/*--------------------------------------------------------------
                    TAKER POSITION REFUND (SELL BATCH)
--------------------------------------------------------------*/

contract MatchOrdersBalanceFlowsTest_takerPositionRefund is MatchOrdersBalanceFlowsTest {
    /// @dev Taker SELL with BUY maker providing enough collateral.
    ///      takerFillAmount exceeds actual position consumption.
    ///      Excess positions refunded to taker.
    function test_batchSellTakerExcessPositionsRefunded() public {
        address dave = vm.addr(DAVE_PK);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 60_000_000);

        // Taker: SELL 100M YES for 50M collateral (price 0.50)
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 9901);
        // BUY maker: 60M collateral for 100M YES (price 0.60)
        // taking = 60M * 100M / 60M = 100M YES... that's too much
        // Use: 30M collateral for 50M YES → taking = 50M YES consumed
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 30_000_000, 50_000_000, Side.BUY, 9902);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 30_000_000;
        uint256[] memory makerFees = new uint256[](1);

        // BUY maker consumes 50M YES from exchange (taking = 30M*50M/30M = 50M)
        // takerFillAmount = 100M, consumed = 50M → 50M refunded
        // collateral delta: 30M (BUY maker) in, 0 out = 30M
        // minimumTaking = 100M * 50M / 100M = 50M
        // 30M < 50M → TooLittleTokensReceived... still not enough collateral
        // Need BUY maker with more generous price.
        // Use: 60M collateral for 50M YES → taking = 50M YES
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 60_000_000, 50_000_000, Side.BUY, 9902);
        fillAmounts[0] = 60_000_000;

        // BUY maker: sends 60M collateral, takes 50M YES
        // collateral delta: 60M in, 0 out = 60M
        // minimumTaking = 100M * 50M / 100M = 50M
        // 60M >= 50M ✓
        // takerTakingAmount = 60M (delta). Fee=0. Taker gets 60M collateral.
        // Position refund: 100M - 50M = 50M YES refunded.
        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        assertCollateralBalance(bob, 60_000_000);
        assertCTFBalance(bob, yes, 50_000_000);
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 50_000_000);
        _assertExchangeEmpty();
    }
}

/*--------------------------------------------------------------
                   SURPLUS REFUND (AUDIT FINDINGS)
--------------------------------------------------------------*/

/// @notice Tests that surplus collateral and positions are refunded to the
/// taker instead of being stranded in the exchange. Covers H-01, M-01,
/// and M-06 from the Pashov audit.
contract MatchOrdersBalanceFlowsTest_surplusRefund is MatchOrdersBalanceFlowsTest {
    /// @notice H-01: Batch sell with price improvement refunds surplus
    /// collateral to taker.
    /// Taker sells 100 YES at limit 0.50. Maker A buys 40 YES at 0.60.
    /// Maker B sells 60 NO at 0.30. Realized proceeds = 66, not 50.
    function test_batchSellPositiveSlippageRefundedToTaker() public {
        address dave = vm.addr(DAVE_PK);

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 24_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 60_000_000); // 60 NO

        // Taker: sell 100 YES for 50 USDC (limit 0.50)
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 8001);

        Order[] memory makerOrders = new Order[](2);
        // Maker A: buy 40 YES for 24 USDC (price 0.60)
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 24_000_000, 40_000_000, Side.BUY, 8002);
        // Maker B: sell 60 NO for 18 USDC (price 0.30)
        makerOrders[1] = _createAndSignOrderWithSalt(carlaPK, no, 60_000_000, 18_000_000, Side.SELL, 8003);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 24_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        // Maker A: paid 24 USDC, got 40 YES
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        // Maker B: sold 60 NO, got 18 USDC
        assertCTFBalance(carla, no, 0);
        assertCollateralBalance(carla, 18_000_000);
        // Taker: gets 50 (formula) + 16 (surplus) = 66 USDC total
        assertCTFBalance(bob, yes, 0);
        assertCollateralBalance(bob, 66_000_000);
        _assertExchangeEmpty();
    }

    /// @notice M-01: Batch mint where taker+maker prices > 1 refunds
    /// surplus collateral.
    /// Taker bids 0.50 per YES, maker bids 0.60 per NO. Sum = 1.10.
    /// 10M surplus collateral must go to taker, not stay in exchange.
    function test_batchMintOverfundedRefundedToTaker() public {
        address dave = vm.addr(DAVE_PK);

        dealCollateralAndApprove(bob, address(exchange), 50_000_000);
        dealCollateralAndApprove(dave, address(exchange), 60_000_000);

        // Taker: buy 100M YES for 50M USDC (price 0.50)
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 50_000_000, 100_000_000, Side.BUY, 8101);
        // Maker: buy 100M NO for 60M USDC (price 0.60)
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, no, 60_000_000, 100_000_000, Side.BUY, 8102);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 60_000_000;

        uint256[] memory makerFees = new uint256[](1);

        _runMatch(takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFees);

        // Maker: paid 60M, got 100M NO
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, no, 100_000_000);
        // Taker: got 100M YES + 10M collateral refund
        assertCTFBalance(bob, yes, 100_000_000);
        assertCollateralBalance(bob, 10_000_000);
        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 10_000_000);
        _assertExchangeEmpty();
    }

    /// @notice M-06 Gap 1: Batch BUY with BUY maker funding the split
    /// leaves taker collateral unused. Must be refunded.
    /// Taker puts up 1000 collateral. BUY maker funds the entire split.
    /// Taker's 1000 collateral is surplus.
    function test_batchBuyCollateralSurplusRefunded() public {
        address dave = vm.addr(DAVE_PK);

        dealCollateralAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 100_000_000);

        // Taker: buy 100M YES for 100M USDC
        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 100_000_000, Side.BUY, 8201);
        // BUY maker: buy 100M NO for 100M USDC (funds the entire split)
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, no, 100_000_000, 100_000_000, Side.BUY, 8202);

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFees = new uint256[](1);

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        // Maker: paid 100M, got 100M NO
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, no, 100_000_000);
        // Taker: got 100M YES + 100M collateral refund (their entire contribution)
        assertCTFBalance(bob, yes, 100_000_000);
        assertCollateralBalance(bob, 100_000_000);
        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 100_000_000);
        _assertExchangeEmpty();
    }

    /// @notice M-06 Gap 2: Mixed batch BUY with SELL maker contributing
    /// taker-token positions. Surplus positions must be refunded.
    /// SELL maker contributes 80 YES. Split creates 100 YES. Taker formula
    /// takes 100 YES. 80 surplus YES must go to taker.
    function test_batchBuyPositionSurplusRefunded() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        dealCollateralAndApprove(bob, address(exchange), 100_000_000);
        // SELL maker: sells 80 YES for 40 USDC (price 0.50)
        dealOutcomeTokensAndApprove(dave, address(exchange), 80_000_000);
        // BUY maker: buys 100 NO for 45 USDC
        dealCollateralAndApprove(erin, address(exchange), 45_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 180_000_000, Side.BUY, 8301);
        Order[] memory makerOrders = new Order[](2);
        // SELL maker: 80 YES for 40 USDC
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 80_000_000, 40_000_000, Side.SELL, 8302);
        // BUY maker: 45 USDC for 100 NO
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 45_000_000, 100_000_000, Side.BUY, 8303);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 80_000_000;
        fillAmounts[1] = 45_000_000;

        uint256[] memory makerFees = new uint256[](2);

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, 0, makerFees);

        // SELL maker: sold 80 YES, got 40 USDC
        assertCTFBalance(dave, yes, 0);
        assertCollateralBalance(dave, 40_000_000);
        // BUY maker: paid 45 USDC, got 100 NO
        assertCollateralBalance(erin, 0);
        assertCTFBalance(erin, no, 100_000_000);
        // Taker: gets 180 YES via balance delta (100 from split + 80 from SELL maker)
        // Collateral: 100 (taker) + 45 (BUY maker) = 145 in, 100 (split) + 40 (SELL maker) = 140 out
        // 5M is refunded to the taker.
        assertCTFBalance(bob, yes, 180_000_000);
        assertCollateralBalance(bob, 5_000_000);
        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 5_000_000);
        _assertExchangeEmpty();
    }

    /// @notice Same as above but with fees to verify surplus accounting
    /// is correct when fees are present.
    function test_batchBuyPositionSurplusWithFees() public {
        address dave = vm.addr(DAVE_PK);
        address erin = vm.addr(ERIN_PK);

        uint256 takerFee = 2_000_000;
        uint256 sellMakerFee = 1_000_000;

        dealCollateralAndApprove(bob, address(exchange), 102_000_000);
        dealOutcomeTokensAndApprove(dave, address(exchange), 80_000_000);
        dealCollateralAndApprove(erin, address(exchange), 45_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 180_000_000, Side.BUY, 8401);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 80_000_000, 40_000_000, Side.SELL, 8402);
        makerOrders[1] = _createAndSignOrderWithSalt(ERIN_PK, no, 45_000_000, 100_000_000, Side.BUY, 8403);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 80_000_000;
        fillAmounts[1] = 45_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = sellMakerFee;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, takerFee, makerFees);

        // SELL maker: 40 taking - 1 fee = 39 USDC
        assertCollateralBalance(dave, 39_000_000);
        // BUY maker: got 100 NO
        assertCTFBalance(erin, no, 100_000_000);
        // Taker: 180 YES + collateral refund
        // Collateral in: 102 (taker) + 45 (BUY maker)
        // Collateral out: 100 (split) + 39 (SELL maker) + 3 (fees)
        // Surplus: 147 - 142 = 5
        assertCTFBalance(bob, yes, 180_000_000);
        assertCollateralBalance(bob, 5_000_000);
        assertCollateralBalance(feeReceiver, takerFee + sellMakerFee);
        (bool filled, uint248 remaining) = exchange.orderStatus(exchange.hashOrder(takerOrder));
        assertFalse(filled);
        assertEq(remaining, 5_000_000);
        _assertExchangeEmpty();
    }

    /// @notice H-01 with fees: verify fee is deducted from formula amount,
    /// surplus is still fully refunded.
    function test_batchSellPositiveSlippageWithFees() public {
        address dave = vm.addr(DAVE_PK);

        uint256 takerFee = 5_000_000;
        uint256 makerAFee = 2_000_000;

        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);
        dealCollateralAndApprove(dave, address(exchange), 26_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 60_000_000);

        Order memory takerOrder = _createAndSignOrderWithSalt(bobPK, yes, 100_000_000, 50_000_000, Side.SELL, 8501);
        Order[] memory makerOrders = new Order[](2);
        makerOrders[0] = _createAndSignOrderWithSalt(DAVE_PK, yes, 24_000_000, 40_000_000, Side.BUY, 8502);
        makerOrders[1] = _createAndSignOrderWithSalt(carlaPK, no, 60_000_000, 18_000_000, Side.SELL, 8503);

        uint256[] memory fillAmounts = new uint256[](2);
        fillAmounts[0] = 24_000_000;
        fillAmounts[1] = 60_000_000;

        uint256[] memory makerFees = new uint256[](2);
        makerFees[0] = makerAFee;

        _runMatch(takerOrder, makerOrders, 100_000_000, fillAmounts, takerFee, makerFees);

        // Maker A: paid 24+2=26 USDC, got 40 YES
        assertCollateralBalance(dave, 0);
        assertCTFBalance(dave, yes, 40_000_000);
        // Maker B: sold 60 NO, got 18 USDC
        assertCollateralBalance(carla, 18_000_000);
        // Taker: formula=50, fee=5, so 45 from formula. Surplus = 16.
        // Total = 45 + 16 = 61
        assertCollateralBalance(bob, 61_000_000);
        // Fees: 5 (taker) + 2 (maker A) = 7
        assertCollateralBalance(feeReceiver, takerFee + makerAFee);
        _assertExchangeEmpty();
    }
}

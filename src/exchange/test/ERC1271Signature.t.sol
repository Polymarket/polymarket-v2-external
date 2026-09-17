// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BaseExchangeTest } from "./BaseExchangeTest.sol";
import { Order, Side, SignatureType } from "@polymarket-v2/src/exchange/OrderStructs.sol";
import { GriefingERC1271Mock } from "./mocks/GriefingERC1271Mock.sol";

contract ERC1271SignatureTest is BaseExchangeTest { }

/*--------------------------------------------------------------
                        VALID SIGNATURES
--------------------------------------------------------------*/

contract ERC1271SignatureTest_valid is ERC1271SignatureTest {
    function test_validSignature() public {
        dealCollateralAndApprove(address(contractWallet), address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);

        Order memory takerOrder =
            _createAndSign1271Order(carlaPK, address(contractWallet), yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);

        assertCollateralBalance(address(contractWallet), 0);
        assertCTFBalance(address(contractWallet), yes, 100_000_000);
    }
}

/*--------------------------------------------------------------
                          REVERTS
--------------------------------------------------------------*/

contract ERC1271SignatureTest_reverts is ERC1271SignatureTest {
    function test_revert_incorrectSigner() public {
        Order memory order = _createOrder(address(contractWallet), yes, 50_000_000, 100_000_000, Side.BUY);
        order.signatureType = SignatureType.POLY_1271;
        // Sign with bob's key instead of carla's (contractWallet expects carla)
        order.signature = _signMessage(bobPK, exchange.hashOrder(order));

        dealCollateralAndApprove(address(contractWallet), address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(carla, address(exchange), 100_000_000);

        Order memory makerOrder = _createAndSignOrder(carlaPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        _matchOrders(conditionId, order, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_nonContract() public {
        // carla is an EOA, not a contract — POLY_1271 should fail
        Order memory order = _createOrder(carla, yes, 50_000_000, 100_000_000, Side.BUY);
        order.signatureType = SignatureType.POLY_1271;
        order.signature = _signMessage(carlaPK, exchange.hashOrder(order));

        dealCollateralAndApprove(carla, address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);

        Order memory makerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        _matchOrders(conditionId, order, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_revert_invalidSignerMaker() public {
        Order memory order = _createOrder(address(contractWallet), yes, 50_000_000, 100_000_000, Side.BUY);
        order.signer = carla;
        order.signatureType = SignatureType.POLY_1271;
        order.signature = _signMessage(carlaPK, exchange.hashOrder(order));

        dealCollateralAndApprove(address(contractWallet), address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);

        Order memory makerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);
        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;
        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        vm.expectRevert(InvalidSignature.selector);
        vm.prank(admin);
        _matchOrders(conditionId, order, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }
}

/*--------------------------------------------------------------
                      GAS GRIEFING GUARD
--------------------------------------------------------------*/

contract ERC1271SignatureTest_gasGriefing is ERC1271SignatureTest {
    /// @dev Regression test for the ERC-1271 returndata bound. A malicious
    ///      signer returns 1 MB of trailing data. The callee pays ~2.2M gas
    ///      for its own memory expansion regardless — that cost is charged
    ///      to the griefer. Under a naive high-level staticcall the
    ///      Exchange would pay a second ~2.2M to copy the returndata into
    ///      its own memory, roughly doubling the match cost. With
    ///      SignatureCheckerLib's 32-byte cap, the Exchange-side copy is
    ///      constant, so the match gas is dominated by the callee's own
    ///      expansion and stays well below the doubled ceiling.
    function test_validSignature_boundsReturndata() public {
        GriefingERC1271Mock griefWallet = new GriefingERC1271Mock(carla);

        dealCollateralAndApprove(address(griefWallet), address(exchange), 50_000_000);
        dealOutcomeTokensAndApprove(bob, address(exchange), 100_000_000);

        Order memory takerOrder =
            _createAndSign1271Order(carlaPK, address(griefWallet), yes, 50_000_000, 100_000_000, Side.BUY);
        Order memory makerOrder = _createAndSignOrder(bobPK, yes, 100_000_000, 50_000_000, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;

        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = 100_000_000;

        uint256[] memory makerFeeAmounts = new uint256[](1);
        makerFeeAmounts[0] = 0;

        uint256 gasBefore = gasleft();
        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
        uint256 gasUsed = gasBefore - gasleft();

        // Callee-side memory expansion for 1 MB is ~2.2M gas. Unbounded
        // callers would pay another ~2.2M (~4.4M total). The 3M ceiling
        // sits between those two regimes and catches any regression that
        // reintroduces unbounded returndatacopy in the Exchange.
        assertLt(gasUsed, 3_000_000, "ERC-1271 returndata is not bounded");
        assertCollateralBalance(address(griefWallet), 0);
        assertCTFBalance(address(griefWallet), yes, 100_000_000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { BaseExchangeTest } from "./BaseExchangeTest.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { Exchange } from "@polymarket-v2/src/exchange/Exchange.sol";
import { Order, Side } from "@polymarket-v2/src/exchange/OrderStructs.sol";

contract ExchangeAdminTest is BaseExchangeTest { }

/*--------------------------------------------------------------
                          SETUP
--------------------------------------------------------------*/

contract ExchangeAdminTest_setup is ExchangeAdminTest {
    function test_initialState() public view {
        assertTrue(exchange.hasAnyRole(admin, 1 << 0)); // ADMIN_ROLE
        assertTrue(exchange.hasAnyRole(admin, 1 << 1)); // OPERATOR_ROLE
        assertEq(exchange.COMBINATORIAL_MODULE(), address(combinatorialModule));
        assertEq(exchange.FEE_RECEIVER(), feeReceiver);
        assertEq(exchange.MAX_FEE_RATE(), 1000);
        assertEq(exchange.userPauseBlockInterval(), 100);
        assertFalse(exchange.paused());
        assertTrue(exchange.isAdmin(admin));
        assertTrue(exchange.isOperator(admin));
        assertFalse(exchange.isAdmin(bob));
    }

    function test_initializerDefaults() public {
        Exchange freshExchange = _deployExchange(500);

        assertEq(freshExchange.MAX_FEE_RATE(), 500);
        assertEq(freshExchange.userPauseBlockInterval(), 100);
        assertEq(freshExchange.FEE_RECEIVER(), feeReceiver);
        assertTrue(freshExchange.hasAnyRole(admin, 1 << 0)); // ADMIN_ROLE
        assertEq(freshExchange.owner(), owner);
    }

    function test_existingMatchOrderSelectorsAreUnchanged() public pure {
        assertEq(Exchange.matchOrders.selector, bytes4(0x0fb25ba4));
        assertEq(Exchange.matchOrdersAndPrepareCombinatorial.selector, bytes4(0xe75cf6e5));
    }
}

/*--------------------------------------------------------------
                        OPERATORS
--------------------------------------------------------------*/

contract ExchangeAdminTest_operators is ExchangeAdminTest {
    function test_addRemoveOperator() public {
        address newOp = makeAddr("newOp");

        vm.prank(admin);
        exchange.addOperator(newOp);
        assertTrue(exchange.hasAnyRole(newOp, 1 << 1));

        vm.prank(admin);
        exchange.removeOperator(newOp);
        assertFalse(exchange.hasAnyRole(newOp, 1 << 1));
    }
}

/*--------------------------------------------------------------
                          PAUSE
--------------------------------------------------------------*/

contract ExchangeAdminTest_pause is ExchangeAdminTest {
    function test_pauseUnpause() public {
        vm.prank(admin);
        exchange.pauseTrading();
        assertTrue(exchange.paused());

        vm.prank(admin);
        exchange.unpauseTrading();
        assertFalse(exchange.paused());
    }

    function test_pauseThenMatchReverts() public {
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

        // Unpause and verify it works
        vm.prank(admin);
        exchange.unpauseTrading();

        vm.prank(admin);
        _matchOrders(conditionId, takerOrder, makerOrders, 50_000_000, fillAmounts, 0, makerFeeAmounts);
    }

    function test_selfServicePauseUser() public {
        // User pauses themselves
        vm.prank(bob);
        exchange.pauseUser();

        // Not yet effective (block delay)
        assertFalse(exchange.isUserPaused(bob));
        uint256 expectedPauseBlock = block.number + exchange.userPauseBlockInterval();
        assertEq(exchange.userPausedBlockAt(bob), expectedPauseBlock);

        // Advance past the pause block
        vm.roll(expectedPauseBlock);
        assertTrue(exchange.isUserPaused(bob));

        // User unpauses themselves
        vm.prank(bob);
        exchange.unpauseUser();
        assertFalse(exchange.isUserPaused(bob));
        assertEq(exchange.userPausedBlockAt(bob), 0);
    }

    function test_revert_pauseUser_alreadyPaused() public {
        vm.prank(bob);
        exchange.pauseUser();

        vm.expectRevert(UserAlreadyPaused.selector);
        vm.prank(bob);
        exchange.pauseUser();
    }
}

/*--------------------------------------------------------------
                        HASH ORDER
--------------------------------------------------------------*/

contract ExchangeAdminTest_hashOrder is ExchangeAdminTest {
    function test_deterministic() public view {
        Order memory order = _createOrder(bob, yes, 50_000_000, 100_000_000, Side.BUY);
        bytes32 hash1 = exchange.hashOrder(order);
        bytes32 hash2 = exchange.hashOrder(order);
        assertEq(hash1, hash2);
    }

    function test_differentSaltDifferentHash() public view {
        Order memory order1 = _createOrder(bob, yes, 50_000_000, 100_000_000, Side.BUY);
        order1.salt = 1;
        Order memory order2 = _createOrder(bob, yes, 50_000_000, 100_000_000, Side.BUY);
        order2.salt = 2;

        assertNotEq(exchange.hashOrder(order1), exchange.hashOrder(order2));
    }
}

/*--------------------------------------------------------------
                    REMOVE ADMIN / OPERATOR
--------------------------------------------------------------*/

/// @notice Tests for removeAdmin and removeOperator
contract ExchangeAdminTest_removeAdminAndOperator is ExchangeAdminTest {
    // Test that removeAdmin revokes admin role
    function test_removeAdmin() public {
        // Add a new admin
        address newAdmin = makeAddr("newAdmin");
        vm.prank(owner);
        exchange.addAdmin(newAdmin);

        // Verify admin role is granted
        assertTrue(exchange.hasAnyRole(newAdmin, 1 << 0));

        // Remove admin
        vm.prank(owner);
        exchange.removeAdmin(newAdmin);

        // Verify admin role is revoked
        assertFalse(exchange.hasAnyRole(newAdmin, 1 << 0));
    }

    // Test that removeAdmin reverts when called by non-owner
    function test_revert_removeAdmin_unauthorized() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(owner);
        exchange.addAdmin(newAdmin);

        // Non-owner tries to remove admin
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        exchange.removeAdmin(newAdmin);
    }

    // Test that removeOperator reverts when called by non-admin
    function test_revert_removeOperator_unauthorized() public {
        address newOp = makeAddr("newOp");
        vm.prank(admin);
        exchange.addOperator(newOp);

        // Non-admin tries to remove operator
        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector); // Unauthorized()
        exchange.removeOperator(newOp);
    }
}

/*--------------------------------------------------------------
               DOMAIN SEPARATOR VIEW
--------------------------------------------------------------*/

/// @notice Tests for domainSeparator view function
contract ExchangeAdminTest_domainSeparator is ExchangeAdminTest {
    function test_domainSeparator() public view {
        bytes32 ds = exchange.domainSeparator();
        // The domain separator should be non-zero
        assertTrue(ds != bytes32(0));
    }
}

/*--------------------------------------------------------------
                        INITIALIZER
--------------------------------------------------------------*/

contract ExchangeAdminTest_initializer is ExchangeAdminTest {
    function test_revert_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        exchange.initialize(owner, admin);
    }

    function test_revert_initialize_onImplementation() public {
        // forgefmt: disable-next-item
        Exchange implementation = new Exchange(
            address(positions.manager),
            address(combinatorialModule),
            feeReceiver,
            1000,
            address(proxyFactory),
            address(safeFactory),
            proxyFactory.bytecodeHash(),
            safeFactory.bytecodeHash()
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, admin);
    }

    function test_revert_constructor_maxFeeRateExceedsCeiling() public {
        // forgefmt: disable-next-item
        try new Exchange(
            address(positions.manager),
            address(combinatorialModule),
            feeReceiver,
            10_001,
            address(proxyFactory),
            address(safeFactory),
            proxyFactory.bytecodeHash(),
            safeFactory.bytecodeHash()
        ) {
            revert("expected revert");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), MaxFeeRateExceedsCeiling.selector);
        }
    }
}

/*--------------------------------------------------------------
                        UUPS UPGRADE
--------------------------------------------------------------*/

contract ExchangeAdminTest_upgrade is ExchangeAdminTest {
    function test_upgradeToAndCall() public {
        // forgefmt: disable-next-item
        address newImpl = address(new Exchange(
            address(positions.manager),
            address(combinatorialModule),
            feeReceiver,
            1000,
            address(proxyFactory),
            address(safeFactory),
            proxyFactory.bytecodeHash(),
            safeFactory.bytecodeHash()
        ));

        vm.prank(owner);
        exchange.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_unauthorized() public {
        // forgefmt: disable-next-item
        address newImpl = address(new Exchange(
            address(positions.manager),
            address(combinatorialModule),
            feeReceiver,
            1000,
            address(proxyFactory),
            address(safeFactory),
            proxyFactory.bytecodeHash(),
            safeFactory.bytecodeHash()
        ));

        vm.prank(bob);
        vm.expectRevert(Unauthorized.selector);
        exchange.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
                  USER PAUSE BLOCK INTERVAL
--------------------------------------------------------------*/

contract ExchangeAdminTest_userPauseBlockInterval is ExchangeAdminTest {
    function test_setUserPauseBlockInterval() public {
        vm.expectEmit(true, true, true, true, address(exchange));
        emit UserPauseBlockIntervalUpdated(100, 200);

        vm.prank(admin);
        exchange.setUserPauseBlockInterval(200);
        assertEq(exchange.userPauseBlockInterval(), 200);
    }

    function test_revert_exceedsMaxPauseInterval() public {
        vm.expectRevert(ExceedsMaxPauseInterval.selector);
        vm.prank(admin);
        exchange.setUserPauseBlockInterval(302_401);
    }

    function test_setUserPauseBlockInterval_maxAllowed() public {
        vm.prank(admin);
        exchange.setUserPauseBlockInterval(302_400);
        assertEq(exchange.userPauseBlockInterval(), 302_400);
    }
}

/*--------------------------------------------------------------
                   RENOUNCE OPERATOR ROLE
--------------------------------------------------------------*/

contract ExchangeAdminTest_renounceOperatorRole is ExchangeAdminTest {
    function test_renounceOperatorRole() public {
        assertTrue(exchange.isOperator(bob));

        vm.prank(bob);
        exchange.renounceOperatorRole();

        assertFalse(exchange.isOperator(bob));
    }

    function test_revert_renounceOperatorRole_notOperator() public {
        address nobody = makeAddr("nobody");

        vm.expectRevert(NotOperator.selector);
        vm.prank(nobody);
        exchange.renounceOperatorRole();
    }
}

/*--------------------------------------------------------------
                      VALIDATE ORDER
--------------------------------------------------------------*/

contract ExchangeAdminTest_validateOrder is ExchangeAdminTest {
    function test_validateOrder_validOrder() public view {
        Order memory order = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);
        exchange.validateOrder(order);
    }

    function test_revert_validateOrder_invalidSignature() public {
        Order memory order = _createOrder(bob, yes, 50_000_000, 100_000_000, Side.BUY);
        order.signature = new bytes(65); // invalid signature

        vm.expectRevert(InvalidSignature.selector);
        exchange.validateOrder(order);
    }

    function test_revert_validateOrder_userPaused() public {
        // Bob pauses himself
        vm.prank(bob);
        exchange.pauseUser();

        // Advance past the pause block
        vm.roll(block.number + exchange.userPauseBlockInterval());

        Order memory order = _createAndSignOrder(bobPK, yes, 50_000_000, 100_000_000, Side.BUY);

        vm.expectRevert(UserIsPaused.selector);
        exchange.validateOrder(order);
    }
}

/*--------------------------------------------------------------
                   IS ADMIN / IS OPERATOR
--------------------------------------------------------------*/

contract ExchangeAdminTest_roleViews is ExchangeAdminTest {
    function test_isAdmin() public view {
        assertTrue(exchange.isAdmin(admin));
        assertFalse(exchange.isAdmin(bob));
    }

    function test_isOperator() public {
        assertTrue(exchange.isOperator(admin));
        assertTrue(exchange.isOperator(bob));
        assertFalse(exchange.isOperator(makeAddr("nobody")));
    }
}

/*--------------------------------------------------------------
                    TRADING PAUSED EVENTS
--------------------------------------------------------------*/

contract ExchangeAdminTest_tradingPausedEvents is ExchangeAdminTest {
    function test_pauseTrading_emitsEvent() public {
        vm.expectEmit(true, true, true, true, address(exchange));
        emit TradingPaused(admin);

        vm.prank(admin);
        exchange.pauseTrading();
    }

    function test_unpauseTrading_emitsEvent() public {
        vm.prank(admin);
        exchange.pauseTrading();

        vm.expectEmit(true, true, true, true, address(exchange));
        emit TradingUnpaused(admin);

        vm.prank(admin);
        exchange.unpauseTrading();
    }
}

/*--------------------------------------------------------------
                    USER PAUSE EVENTS
--------------------------------------------------------------*/

contract ExchangeAdminTest_userPauseEvents is ExchangeAdminTest {
    function test_pauseUser_emitsEvent() public {
        uint256 expectedBlock = block.number + exchange.userPauseBlockInterval();

        vm.expectEmit(true, true, true, true, address(exchange));
        emit UserPaused(bob, expectedBlock);

        vm.prank(bob);
        exchange.pauseUser();
    }

    function test_unpauseUser_emitsEvent() public {
        vm.prank(bob);
        exchange.pauseUser();

        vm.expectEmit(true, true, true, true, address(exchange));
        emit UserUnpaused(bob);

        vm.prank(bob);
        exchange.unpauseUser();
    }
}

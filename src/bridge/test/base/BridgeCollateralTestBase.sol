// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { BridgeTestBase } from "./BridgeTestBase.sol";

/// @title BridgeCollateralTestBase
/// @notice Abstract base containing all shared collateral bridging test logic.
/// @dev Concrete implementations deploy transport infrastructure, populate state,
///      and override _deliverFromHub/_deliverFromSpokeA/_deliverFromSpokeB.
abstract contract BridgeCollateralTestBase is BridgeTestBase {
    /*--------------------------------------------------------------
                         SHARED STATE
    --------------------------------------------------------------*/

    IBridge public hubBridge;
    IBridge public spokeABridge;
    IBridge public spokeBBridge;

    CollateralToken public hubCollateralToken;
    CollateralToken public spokeACollateralToken;
    CollateralToken public spokeBCollateralToken;

    uint256 public HUB_DST;
    uint256 public SPOKE_A_DST;
    uint256 public SPOKE_B_DST;

    /*--------------------------------------------------------------
                         EVENTS
    --------------------------------------------------------------*/

    event CollateralBridged(
        bytes32 indexed messageId, uint256 indexed dstChain, address indexed sender, bytes32 recipient, uint256 amount
    );
    event CollateralReceived(bytes32 indexed messageId, address indexed recipient, uint256 amount);

    /*--------------------------------------------------------------
                       VIRTUAL FUNCTIONS
    --------------------------------------------------------------*/

    function _deliverFromHub() internal virtual;
    function _deliverFromSpokeA() internal virtual;
    function _deliverFromSpokeB() internal virtual;

    /*--------------------------------------------------------------
                   COLLATERAL BRIDGING TESTS
    --------------------------------------------------------------*/

    function test_bridge_collateral_hubToSpoke() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount);
        assertEq(spokeACollateralToken.balanceOf(recipient), 0, "Recipient should have no collateral on spoke");

        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), amount);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, _toBytes32(recipient), "");

        assertEq(hubCollateralToken.balanceOf(user), 0, "Collateral not burned on hub");

        _deliverFromHub();

        assertEq(spokeACollateralToken.balanceOf(recipient), amount, "Collateral not minted on spoke");
    }

    function test_bridge_collateral_spokeToHub() public {
        uint256 amount = 1e6;

        vm.chainId(SPOKE_A_CHAIN_ID);
        spokeACollateralToken.mint(user, amount);
        vm.prank(user);
        spokeACollateralToken.transfer(address(spokeABridge), amount);

        vm.prank(user);
        spokeABridge.bridgeCollateral{ value: 0.01 ether }(HUB_DST, amount, _toBytes32(recipient), "");

        assertEq(spokeACollateralToken.balanceOf(user), 0, "Collateral not burned on spoke");

        _deliverFromSpokeA();

        assertEq(hubCollateralToken.balanceOf(recipient), amount, "Collateral not minted on hub");
    }

    function test_bridge_collateral_spokeToSpoke() public {
        uint256 amount = 1e6;

        vm.chainId(SPOKE_A_CHAIN_ID);
        spokeACollateralToken.mint(user, amount);
        vm.prank(user);
        spokeACollateralToken.transfer(address(spokeABridge), amount);

        vm.prank(user);
        spokeABridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_B_DST, amount, _toBytes32(recipient), "");

        assertEq(spokeACollateralToken.balanceOf(user), 0, "Collateral not burned on spoke A");

        _deliverFromSpokeA();

        assertEq(spokeBCollateralToken.balanceOf(recipient), amount, "Collateral not minted on spoke B");
    }

    function test_bridge_collateral_roundTrip() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount);
        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), amount);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, _toBytes32(user), "");
        _deliverFromHub();

        assertEq(spokeACollateralToken.balanceOf(user), amount, "Collateral not on spoke A");

        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.prank(user);
        spokeACollateralToken.transfer(address(spokeABridge), amount);

        vm.prank(user);
        spokeABridge.bridgeCollateral{ value: 0.01 ether }(HUB_DST, amount, _toBytes32(user), "");
        _deliverFromSpokeA();

        assertEq(hubCollateralToken.balanceOf(user), amount, "Collateral not back on hub");
        assertEq(spokeACollateralToken.balanceOf(user), 0, "Collateral still on spoke A");
    }

    function test_bridge_collateral_partialAmount() public {
        uint256 totalAmount = 1e6;
        uint256 bridgeAmount = 400_000;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, totalAmount);
        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), bridgeAmount);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, bridgeAmount, _toBytes32(recipient), "");
        _deliverFromHub();

        assertEq(hubCollateralToken.balanceOf(user), totalAmount - bridgeAmount, "Wrong remaining balance on hub");
        assertEq(spokeACollateralToken.balanceOf(recipient), bridgeAmount, "Wrong bridged amount on spoke");
    }

    function test_bridge_collateral_toSelf() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount);
        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), amount);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, _toBytes32(user), "");
        _deliverFromHub();

        assertEq(spokeACollateralToken.balanceOf(user), amount, "User should have collateral on spoke");
    }

    function test_bridge_collateral_multipleBridges() public {
        uint256 amount1 = 1e6;
        uint256 amount2 = 2e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount1 + amount2);
        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), amount1 + amount2);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount1, _toBytes32(recipient), "");
        _deliverFromHub();

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_B_DST, amount2, _toBytes32(recipient), "");
        _deliverFromHub();

        assertEq(spokeACollateralToken.balanceOf(recipient), amount1, "Wrong amount on spoke A");
        assertEq(spokeBCollateralToken.balanceOf(recipient), amount2, "Wrong amount on spoke B");
        assertEq(hubCollateralToken.balanceOf(user), 0, "User should have no collateral left on hub");
    }

    /*--------------------------------------------------------------
                          QUOTE TESTS
    --------------------------------------------------------------*/

    function test_bridge_collateral_quote_hubToSpoke() public view {
        (uint256 nativeFee, uint256 alternativeFee) =
            hubBridge.quoteBridgeCollateral(SPOKE_A_DST, 1e6, _toBytes32(recipient), "");

        assertGt(nativeFee, 0, "Native fee should be non-zero");
        assertEq(alternativeFee, 0, "Alternative fee should be zero");
    }

    function test_bridge_collateral_quote_spokeToHub() public view {
        (uint256 nativeFee, uint256 alternativeFee) =
            spokeABridge.quoteBridgeCollateral(HUB_DST, 1e6, _toBytes32(recipient), "");

        assertGt(nativeFee, 0, "Native fee should be non-zero");
        assertEq(alternativeFee, 0, "Alternative fee should be zero");
    }

    function test_bridge_collateral_quote_amountDoesNotAffectFee() public view {
        (uint256 fee1,) = hubBridge.quoteBridgeCollateral(SPOKE_A_DST, 1, _toBytes32(recipient), "");
        (uint256 fee2,) = hubBridge.quoteBridgeCollateral(SPOKE_A_DST, 1e18, _toBytes32(recipient), "");

        assertEq(fee1, fee2, "Fee should not depend on amount");
    }

    /*--------------------------------------------------------------
                          EVENT TESTS
    --------------------------------------------------------------*/

    function test_bridge_collateral_emitsCollateralBridged() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount);
        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), amount);

        // messageId (topic1) is transport-generated; verify the remaining topics and data.
        vm.expectEmit(false, true, true, true);
        emit CollateralBridged(bytes32(0), SPOKE_A_DST, user, _toBytes32(recipient), amount);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, _toBytes32(recipient), "");
    }

    function test_bridge_collateral_emitsCollateralReceived() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount);
        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), amount);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, _toBytes32(recipient), "");

        vm.expectEmit(false, true, false, true);
        emit CollateralReceived(bytes32(0), recipient, amount);

        _deliverFromHub();
    }

    /*--------------------------------------------------------------
                          REVERT TESTS
    --------------------------------------------------------------*/

    function test_bridge_collateral_insufficientApproval_reverts() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount);

        vm.prank(user);
        vm.expectRevert();
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, _toBytes32(recipient), "");
    }
}

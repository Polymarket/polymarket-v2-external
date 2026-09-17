// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { CcipBridge } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { MockCcipRouter } from "./mocks/MockCcipRouter.sol";
import { CcipBridgeTestBase, CcipChainInfra } from "./base/CcipBridgeTestBase.sol";
import { BridgeCollateralTestBase } from "./base/BridgeCollateralTestBase.sol";
import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";

contract CcipBridgeCollateralTest is CcipBridgeTestBase, BridgeCollateralTestBase {
    MockCcipRouter public hubRouter;
    MockCcipRouter public spokeARouter;
    MockCcipRouter public spokeBRouter;

    CcipBridge public spokeABridgeCcip;

    function setUp() public {
        _initTestAddresses();

        HUB_DST = HUB_SELECTOR;
        SPOKE_A_DST = SPOKE_A_SELECTOR;
        SPOKE_B_DST = SPOKE_B_SELECTOR;

        // Deploy infrastructure
        CcipChainInfra memory hubInfra = _deployChainInfra(HUB_CHAIN_ID, HUB_SELECTOR);
        hubRouter = hubInfra.router;
        hubBridge = IBridge(address(hubInfra.bridge));
        hubCollateralToken = CollateralToken(address(hubInfra.collateral.token));
        hubCollateralToken.addMinter(address(this));

        CcipChainInfra memory spokeAInfra = _deployChainInfra(SPOKE_A_CHAIN_ID, SPOKE_A_SELECTOR);
        spokeARouter = spokeAInfra.router;
        spokeABridgeCcip = spokeAInfra.bridge;
        spokeABridge = IBridge(address(spokeAInfra.bridge));
        spokeACollateralToken = CollateralToken(address(spokeAInfra.collateral.token));
        spokeACollateralToken.addMinter(address(this));

        CcipChainInfra memory spokeBInfra = _deployChainInfra(SPOKE_B_CHAIN_ID, SPOKE_B_SELECTOR);
        spokeBRouter = spokeBInfra.router;
        spokeBBridge = IBridge(address(spokeBInfra.bridge));
        spokeBCollateralToken = CollateralToken(address(spokeBInfra.collateral.token));
        spokeBCollateralToken.addMinter(address(this));

        // Configure peers
        hubInfra.bridge.setPeer(SPOKE_A_SELECTOR, _toBytes32(address(spokeAInfra.bridge)));
        hubInfra.bridge.setPeer(SPOKE_B_SELECTOR, _toBytes32(address(spokeBInfra.bridge)));
        spokeAInfra.bridge.setPeer(HUB_SELECTOR, _toBytes32(address(hubInfra.bridge)));
        spokeAInfra.bridge.setPeer(SPOKE_B_SELECTOR, _toBytes32(address(spokeBInfra.bridge)));
        spokeBInfra.bridge.setPeer(HUB_SELECTOR, _toBytes32(address(hubInfra.bridge)));
        spokeBInfra.bridge.setPeer(SPOKE_A_SELECTOR, _toBytes32(address(spokeAInfra.bridge)));
    }

    /*--------------------------------------------------------------
                       VIRTUAL IMPLEMENTATIONS
    --------------------------------------------------------------*/

    function _deliverFromHub() internal override {
        _deliver(hubRouter);
    }

    function _deliverFromSpokeA() internal override {
        _deliver(spokeARouter);
    }

    function _deliverFromSpokeB() internal override {
        _deliver(spokeBRouter);
    }

    /*--------------------------------------------------------------
                    CCIP-SPECIFIC REVERT TEST
    --------------------------------------------------------------*/

    function test_revert_CcipBridge_receiveCollateral_noMinterRole() public {
        uint256 amount = 1e6;

        vm.chainId(HUB_CHAIN_ID);
        hubCollateralToken.mint(user, amount);
        vm.prank(user);
        hubCollateralToken.transfer(address(hubBridge), amount);

        vm.prank(user);
        hubBridge.bridgeCollateral{ value: 0.01 ether }(SPOKE_A_DST, amount, _toBytes32(recipient), "");

        spokeACollateralToken.removeMinter(address(spokeABridgeCcip));

        MockCcipRouter.SentMessage memory msg_ = hubRouter.getLastSentMessage();
        vm.chainId(SPOKE_A_CHAIN_ID);

        vm.expectRevert();
        spokeARouter.simulateReceive(
            uint64(HUB_SELECTOR), address(CcipBridge(address(hubBridge))), address(spokeABridgeCcip), msg_.data
        );
    }
}

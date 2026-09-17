// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { CcipBridge } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { MockCcipRouter } from "./mocks/MockCcipRouter.sol";
import { CcipBridgeTestBase, CcipChainInfra } from "./base/CcipBridgeTestBase.sol";
import { BridgeMigrationTestBase } from "./base/BridgeMigrationTestBase.sol";
import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";

// Modules
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ModuleProxyLib } from "@polymarket-v2/src/modules/dev/ModuleProxyLib.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";

// Legacy infrastructure
import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { INegRiskAdapter } from "@polymarket-v2/src/legacy/interfaces/INegRiskAdapter.sol";
import { DeployLib } from "@polymarket-v2/src/dev/DeployLib.sol";

/// @title CcipBridgeMigrationTest
/// @notice Cross-chain bridge tests for legacy migration flows via CCIP
contract CcipBridgeMigrationTest is CcipBridgeTestBase, BridgeMigrationTestBase {
    MockCcipRouter public hubRouter;
    MockCcipRouter public spokeARouter;
    MockCcipRouter public spokeBRouter;

    function setUp() public {
        _initTestAddresses();

        HUB_DST = HUB_SELECTOR;
        SPOKE_A_DST = SPOKE_A_SELECTOR;
        SPOKE_B_DST = SPOKE_B_SELECTOR;

        _deployHub();
        _deploySpokeA();
        _deploySpokeB();
        _configurePeers();
    }

    /*--------------------------------------------------------------
                            SETUP FUNCTIONS
    --------------------------------------------------------------*/

    function _deployHub() internal {
        CcipChainInfra memory infra = _deployChainInfra(HUB_CHAIN_ID, HUB_SELECTOR);
        hubRouter = infra.router;
        hubBridge = IBridge(address(infra.bridge));
        hubPositionManager = infra.positionManager;
        hubCollateral = infra.collateral;
        hubUsdce = address(infra.collateral.usdce);

        // Deploy legacy infrastructure (migration-specific)
        hubCT = IConditionalTokens(DeployLib.deployConditionalTokens());
        hubNRA = INegRiskAdapter(DeployLib.deployNegRiskAdapter(address(hubCT), hubUsdce, address(0xdead)));
        hubNRA.addAdmin(oracle);
        hubWrappedCollateral = hubNRA.wcol();

        // Deploy merged modules (with migration support)
        hubBinaryModule =
            ModuleProxyLib.deployBinaryModule(address(hubPositionManager), owner, admin, address(hubCT), hubUsdce);
        hubNegRiskModule = ModuleProxyLib.deployNegRiskModule(
            address(hubPositionManager), owner, admin, address(hubCT), hubUsdce, address(hubNRA)
        );

        _setupModules(infra, address(hubBinaryModule), address(hubNegRiskModule), true);
    }

    function _deploySpokeA() internal {
        CcipChainInfra memory infra = _deployChainInfra(SPOKE_A_CHAIN_ID, SPOKE_A_SELECTOR);
        spokeARouter = infra.router;
        spokeABridge = IBridge(address(infra.bridge));
        spokeAPositionManager = infra.positionManager;

        spokeABinaryModule =
            ModuleProxyLib.deployBinaryModule(address(spokeAPositionManager), owner, admin, address(0), address(0));
        spokeANegRiskModule = ModuleProxyLib.deployNegRiskModule(
            address(spokeAPositionManager), owner, admin, address(0), address(0), address(0)
        );

        _setupModules(infra, address(spokeABinaryModule), address(spokeANegRiskModule), false);
    }

    function _deploySpokeB() internal {
        CcipChainInfra memory infra = _deployChainInfra(SPOKE_B_CHAIN_ID, SPOKE_B_SELECTOR);
        spokeBRouter = infra.router;
        spokeBBridge = IBridge(address(infra.bridge));
        spokeBPositionManager = infra.positionManager;

        spokeBBinaryModule =
            ModuleProxyLib.deployBinaryModule(address(spokeBPositionManager), owner, admin, address(0), address(0));
        spokeBNegRiskModule = ModuleProxyLib.deployNegRiskModule(
            address(spokeBPositionManager), owner, admin, address(0), address(0), address(0)
        );

        _setupModules(infra, address(spokeBBinaryModule), address(spokeBNegRiskModule), false);
    }

    function _configurePeers() internal {
        CcipBridge hubBridgeCcip = CcipBridge(address(hubBridge));
        CcipBridge spokeABridgeCcip = CcipBridge(address(spokeABridge));
        CcipBridge spokeBBridgeCcip = CcipBridge(address(spokeBBridge));

        // Hub peers
        hubBridgeCcip.setPeer(SPOKE_A_SELECTOR, _toBytes32(address(spokeABridge)));
        hubBridgeCcip.setPeer(SPOKE_B_SELECTOR, _toBytes32(address(spokeBBridge)));
        hubBridgeCcip.setModuleSupported(address(hubBinaryModule), SPOKE_A_SELECTOR, true);
        hubBridgeCcip.setModuleSupported(address(hubBinaryModule), SPOKE_B_SELECTOR, true);
        hubBridgeCcip.setModuleSupported(address(hubNegRiskModule), SPOKE_A_SELECTOR, true);
        hubBridgeCcip.setModuleSupported(address(hubNegRiskModule), SPOKE_B_SELECTOR, true);

        // Spoke A peers
        spokeABridgeCcip.setPeer(HUB_SELECTOR, _toBytes32(address(hubBridge)));
        spokeABridgeCcip.setPeer(SPOKE_B_SELECTOR, _toBytes32(address(spokeBBridge)));
        spokeABridgeCcip.setModuleSupported(address(spokeABinaryModule), HUB_SELECTOR, true);
        spokeABridgeCcip.setModuleSupported(address(spokeABinaryModule), SPOKE_B_SELECTOR, true);
        spokeABridgeCcip.setModuleSupported(address(spokeANegRiskModule), HUB_SELECTOR, true);
        spokeABridgeCcip.setModuleSupported(address(spokeANegRiskModule), SPOKE_B_SELECTOR, true);

        // Spoke B peers
        spokeBBridgeCcip.setPeer(HUB_SELECTOR, _toBytes32(address(hubBridge)));
        spokeBBridgeCcip.setPeer(SPOKE_A_SELECTOR, _toBytes32(address(spokeABridge)));
        spokeBBridgeCcip.setModuleSupported(address(spokeBBinaryModule), HUB_SELECTOR, true);
        spokeBBridgeCcip.setModuleSupported(address(spokeBBinaryModule), SPOKE_A_SELECTOR, true);
        spokeBBridgeCcip.setModuleSupported(address(spokeBNegRiskModule), HUB_SELECTOR, true);
        spokeBBridgeCcip.setModuleSupported(address(spokeBNegRiskModule), SPOKE_A_SELECTOR, true);
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
}

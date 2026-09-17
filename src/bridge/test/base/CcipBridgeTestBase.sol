// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { CcipBridge } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { MockCcipRouter } from "@polymarket-v2/src/bridge/test/mocks/MockCcipRouter.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { Collateral, CollateralSetup } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { BridgeTestBase } from "./BridgeTestBase.sol";

/// @notice Deployed infrastructure for a single chain (CCIP)
struct CcipChainInfra {
    uint256 chainId;
    uint256 chainSelector;
    Collateral collateral;
    PositionManager positionManager;
    MockCcipRouter router;
    CcipBridge bridge;
}

/// @title CcipBridgeTestBase
/// @notice Shared test infrastructure for multi-chain CCIP bridge tests
abstract contract CcipBridgeTestBase is BridgeTestBase {
    /*--------------------------------------------------------------
                          CHAIN CONFIGURATION
    --------------------------------------------------------------*/

    uint256 constant HUB_SELECTOR = 4051577828743386545; // Polygon CCIP selector
    uint256 constant SPOKE_A_SELECTOR = 4949039107694359620; // Arbitrum CCIP selector
    uint256 constant SPOKE_B_SELECTOR = 15971525489660198786; // Base CCIP selector

    /*--------------------------------------------------------------
                             CHAIN REGISTRY
    --------------------------------------------------------------*/

    /// @notice Maps chain selector to deployed chain infrastructure
    mapping(uint256 => CcipChainInfra) internal chainBySelector;

    /*--------------------------------------------------------------
                             SETUP HELPERS
    --------------------------------------------------------------*/

    /// @notice Deploy common chain infrastructure (collateral, PM, router, bridge, callback)
    /// @dev Does NOT deploy modules - that's test-specific
    function _deployChainInfra(uint256 chainId, uint256 selector) internal returns (CcipChainInfra memory) {
        vm.chainId(chainId);

        CcipChainInfra memory infra;
        infra.chainId = chainId;
        infra.chainSelector = selector;

        // Deploy collateral
        infra.collateral = CollateralSetup._deploy(owner);

        // Deploy position manager
        address pmImpl = address(new PositionManager(address(infra.collateral.token)));
        address pmProxy = LibClone.deployERC1967(pmImpl);
        infra.positionManager = PositionManager(pmProxy);
        infra.positionManager.initialize(owner, admin);

        // Deploy router and bridge
        infra.router = new MockCcipRouter(uint64(selector));
        address bridgeImpl = address(
            new CcipBridge(
                address(infra.router),
                address(infra.positionManager),
                address(infra.collateral.token),
                HUB_CHAIN_ID,
                HUB_SELECTOR
            )
        );
        address bridgeProxy = LibClone.deployERC1967(bridgeImpl);
        infra.bridge = CcipBridge(bridgeProxy);
        infra.bridge.initialize(owner, admin);

        // Grant bridge minter role
        infra.collateral.token.addMinter(address(infra.bridge));

        // Register in chain registry for simplified _deliver
        chainBySelector[selector] = infra;

        return infra;
    }

    /// @notice Setup module roles and registration (call after deploying modules)
    function _setupModules(CcipChainInfra memory infra, address binaryModule, address negRiskModule, bool isHub)
        internal
    {
        BaseModule binary = BaseModule(binaryModule);
        BaseModule negRisk = BaseModule(negRiskModule);

        vm.startPrank(owner);
        // Grant minter roles to modules
        infra.collateral.token.addMinter(binaryModule);
        infra.collateral.token.addMinter(negRiskModule);
        vm.stopPrank();

        vm.startPrank(admin);
        infra.positionManager.addModule(binaryModule);
        infra.positionManager.addModule(negRiskModule);

        if (isHub) {
            binary.addCreator(creator);
            negRisk.addCreator(creator);
        }

        binary.addBridge(address(infra.bridge));
        negRisk.addBridge(address(infra.bridge));
        vm.stopPrank();
    }

    /*--------------------------------------------------------------
                            MESSAGE DELIVERY
    --------------------------------------------------------------*/

    /// @notice Deliver the last sent message from src router to its destination
    function _deliver(MockCcipRouter srcRouter) internal {
        MockCcipRouter.SentMessage memory msg_ = srcRouter.getLastSentMessage();
        CcipChainInfra storage src = chainBySelector[srcRouter.chainSelector()];
        CcipChainInfra storage dst = chainBySelector[msg_.destChainSelector];

        vm.chainId(dst.chainId);
        dst.router.simulateReceive(srcRouter.chainSelector(), address(src.bridge), address(dst.bridge), msg_.data);
    }
}

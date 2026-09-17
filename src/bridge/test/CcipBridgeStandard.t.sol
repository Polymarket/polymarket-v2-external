// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { CcipBridge } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { MockCcipRouter } from "./mocks/MockCcipRouter.sol";
import { CcipBridgeTestBase, CcipChainInfra } from "./base/CcipBridgeTestBase.sol";
import { BridgeStandardTestBase } from "./base/BridgeStandardTestBase.sol";
import { BridgeBase } from "@polymarket-v2/src/bridge/abstract/BridgeBase.sol";
import { IBridge } from "@polymarket-v2/src/bridge/interfaces/IBridge.sol";
import { ConditionIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { MessageType } from "@polymarket-v2/src/libraries/CrossChainTypes.sol";

// Standard modules
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ModuleProxyLib } from "@polymarket-v2/src/modules/dev/ModuleProxyLib.sol";

// Infrastructure
import { BridgeRouter } from "@polymarket-v2/src/routers/BridgeRouter.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

/// @title CcipBridgeStandardTest
/// @notice Cross-chain bridge tests for standard Binary and NegRisk modules via CCIP
contract CcipBridgeStandardTest is CcipBridgeTestBase, BridgeStandardTestBase {
    // Transport-specific references for message delivery
    MockCcipRouter public hubRouter;
    MockCcipRouter public spokeARouter;
    MockCcipRouter public spokeBRouter;

    // Typed reference for transport-specific revert test
    CcipBridge public spokeABridgeCcip;

    function setUp() public {
        _initTestAddresses();

        HUB_DST = HUB_SELECTOR;
        SPOKE_A_DST = SPOKE_A_SELECTOR;
        SPOKE_B_DST = SPOKE_B_SELECTOR;

        // Deploy hub
        CcipChainInfra memory hubInfra = _deployChainInfra(HUB_CHAIN_ID, HUB_SELECTOR);
        hubRouter = hubInfra.router;
        hubBridge = IBridge(address(hubInfra.bridge));
        hubPositionManager = hubInfra.positionManager;
        hubCollateral = hubInfra.collateral;

        hubBinaryModule =
            ModuleProxyLib.deployBinaryModule(address(hubPositionManager), owner, admin, address(0), address(0));
        hubNegRiskModule = ModuleProxyLib.deployNegRiskModule(
            address(hubPositionManager), owner, admin, address(0), address(0), address(0)
        );
        _setupModules(hubInfra, address(hubBinaryModule), address(hubNegRiskModule), true);

        hubBridgeRouter = RouterSetup.deployBridgeRouter(address(hubPositionManager), address(hubBridge), owner);

        // Deploy spoke A
        CcipChainInfra memory spokeAInfra = _deployChainInfra(SPOKE_A_CHAIN_ID, SPOKE_A_SELECTOR);
        spokeARouter = spokeAInfra.router;
        spokeABridgeCcip = spokeAInfra.bridge;
        spokeABridge = IBridge(address(spokeAInfra.bridge));
        spokeAPositionManager = spokeAInfra.positionManager;

        spokeABinaryModule =
            ModuleProxyLib.deployBinaryModule(address(spokeAPositionManager), owner, admin, address(0), address(0));
        spokeANegRiskModule = ModuleProxyLib.deployNegRiskModule(
            address(spokeAPositionManager), owner, admin, address(0), address(0), address(0)
        );
        _setupModules(spokeAInfra, address(spokeABinaryModule), address(spokeANegRiskModule), false);

        // Deploy spoke B
        CcipChainInfra memory spokeBInfra = _deployChainInfra(SPOKE_B_CHAIN_ID, SPOKE_B_SELECTOR);
        spokeBRouter = spokeBInfra.router;
        spokeBBridge = IBridge(address(spokeBInfra.bridge));
        spokeBPositionManager = spokeBInfra.positionManager;

        spokeBBinaryModule =
            ModuleProxyLib.deployBinaryModule(address(spokeBPositionManager), owner, admin, address(0), address(0));
        spokeBNegRiskModule = ModuleProxyLib.deployNegRiskModule(
            address(spokeBPositionManager), owner, admin, address(0), address(0), address(0)
        );
        _setupModules(spokeBInfra, address(spokeBBinaryModule), address(spokeBNegRiskModule), false);

        // Configure peers and module support
        hubInfra.bridge.setPeer(SPOKE_A_SELECTOR, _toBytes32(address(spokeAInfra.bridge)));
        hubInfra.bridge.setPeer(SPOKE_B_SELECTOR, _toBytes32(address(spokeBInfra.bridge)));
        hubInfra.bridge.setModuleSupported(address(hubBinaryModule), SPOKE_A_SELECTOR, true);
        hubInfra.bridge.setModuleSupported(address(hubBinaryModule), SPOKE_B_SELECTOR, true);
        hubInfra.bridge.setModuleSupported(address(hubNegRiskModule), SPOKE_A_SELECTOR, true);
        hubInfra.bridge.setModuleSupported(address(hubNegRiskModule), SPOKE_B_SELECTOR, true);

        spokeAInfra.bridge.setPeer(HUB_SELECTOR, _toBytes32(address(hubInfra.bridge)));
        spokeAInfra.bridge.setPeer(SPOKE_B_SELECTOR, _toBytes32(address(spokeBInfra.bridge)));
        spokeAInfra.bridge.setModuleSupported(address(spokeABinaryModule), HUB_SELECTOR, true);
        spokeAInfra.bridge.setModuleSupported(address(spokeABinaryModule), SPOKE_B_SELECTOR, true);
        spokeAInfra.bridge.setModuleSupported(address(spokeANegRiskModule), HUB_SELECTOR, true);
        spokeAInfra.bridge.setModuleSupported(address(spokeANegRiskModule), SPOKE_B_SELECTOR, true);

        spokeBInfra.bridge.setPeer(HUB_SELECTOR, _toBytes32(address(hubInfra.bridge)));
        spokeBInfra.bridge.setPeer(SPOKE_A_SELECTOR, _toBytes32(address(spokeAInfra.bridge)));
        spokeBInfra.bridge.setModuleSupported(address(spokeBBinaryModule), HUB_SELECTOR, true);
        spokeBInfra.bridge.setModuleSupported(address(spokeBBinaryModule), SPOKE_A_SELECTOR, true);
        spokeBInfra.bridge.setModuleSupported(address(spokeBNegRiskModule), HUB_SELECTOR, true);
        spokeBInfra.bridge.setModuleSupported(address(spokeBNegRiskModule), SPOKE_A_SELECTOR, true);
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

    function _spokeACollateralBalance(address _account) internal view override returns (uint256) {
        CcipChainInfra storage spokeA = chainBySelector[SPOKE_A_SELECTOR];
        return spokeA.collateral.token.balanceOf(_account);
    }

    /*--------------------------------------------------------------
                    CCIP-SPECIFIC REVERT TEST
    --------------------------------------------------------------*/

    function test_revert_CcipBridge_receivePositions_noBridgeRole() public {
        uint256 amount = 100_000_000;

        // Setup condition and positions on hub
        (, uint256 positionId0, uint256 positionId1) = _setupBinaryCondition(bytes("test-no-bridge-role"), amount);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(positionId0);
        positionIds[1] = PositionId.wrap(positionId1);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        // Bridge positions (sends CCIP message)
        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_A_DST, positionIds, amounts, _toBytes32(user), "");

        // Remove bridge role from spoke module before delivery
        vm.prank(admin);
        spokeABinaryModule.removeBridge(address(spokeABridgeCcip));

        // Delivery should revert due to missing bridge role
        MockCcipRouter.SentMessage memory msg_ = hubRouter.getLastSentMessage();
        vm.chainId(SPOKE_A_CHAIN_ID);

        vm.expectRevert();
        spokeARouter.simulateReceive(
            uint64(HUB_SELECTOR), address(CcipBridge(address(hubBridge))), address(spokeABridgeCcip), msg_.data
        );
    }

    function test_revert_CcipBridge_result_spokeToHub() public {
        uint256 amount = 100_000_000;

        (bytes32 conditionId,,) = _setupBinaryCondition(bytes("test-result-spoke-hub"), amount);

        // Resolve on hub and bridge the result to spoke A
        vm.chainId(HUB_CHAIN_ID);
        _resolveBinaryOnHub(conditionId);
        hubBridge.bridgeResult{ value: 0.01 ether }(SPOKE_A_DST, ConditionIdLib.from(conditionId), "");
        _deliverFromHub();

        assertTrue(spokeABinaryModule.hasResult(ConditionIdLib.from(conditionId)), "Result not on spoke A");

        // Sending the result back towards its resolution chain is refused on the spoke
        vm.chainId(SPOKE_A_CHAIN_ID);
        vm.expectRevert(BridgeBase.InvalidResolutionChainId.selector);
        spokeABridge.bridgeResult{ value: 0.01 ether }(HUB_DST, ConditionIdLib.from(conditionId), "");

        // And a peer that sends one anyway is refused on delivery
        uint256[] memory resultData = new uint256[](2);
        resultData[0] = 1_000_000;
        resultData[1] = 0;
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.RESULT)), abi.encode(conditionId, resultData));

        vm.chainId(HUB_CHAIN_ID);
        vm.expectRevert(BridgeBase.LocalResolutionChain.selector);
        hubRouter.simulateReceive(
            uint64(SPOKE_A_SELECTOR), address(spokeABridgeCcip), address(CcipBridge(address(hubBridge))), payload
        );
    }

    /// @dev Delivered through the router: a compromised spoke skips its own send-side guard.
    function test_revert_CcipBridge_receiveResult_fromSpokePeer() public {
        uint256 amount = 100_000_000;

        (bytes32 conditionId, uint256 positionId0,) = _setupBinaryCondition(bytes("test-result-spoke-spoke"), amount);

        // Bridge positions HUB -> SPOKE_B so the condition exists there.
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        hubPositionManager.unsafeBatchTransferFrom(user, address(hubBridge), positionIds, amounts);

        vm.prank(user);
        hubBridge.bridgePositions{ value: 0.01 ether }(SPOKE_B_DST, positionIds, amounts, _toBytes32(user), "");
        _deliverFromHub();

        // A result the hub never resolved, naming the losing outcome as the winner.
        uint256[] memory forgedResult = new uint256[](2);
        forgedResult[0] = 0;
        forgedResult[1] = 1_000_000;
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.RESULT)), abi.encode(conditionId, forgedResult));

        // Not the resolution chain's lane.
        vm.chainId(SPOKE_B_CHAIN_ID);
        vm.expectRevert(BridgeBase.UnexpectedResultSource.selector);
        spokeBRouter.simulateReceive(
            uint64(SPOKE_A_SELECTOR), address(spokeABridgeCcip), address(CcipBridge(address(spokeBBridge))), payload
        );

        assertFalse(spokeBBinaryModule.hasResult(ConditionIdLib.from(conditionId)), "Forged result was accepted");

        // Positive control: the same payload on the hub's lane is accepted.
        vm.chainId(SPOKE_B_CHAIN_ID);
        spokeBRouter.simulateReceive(
            uint64(HUB_SELECTOR),
            address(CcipBridge(address(hubBridge))),
            address(CcipBridge(address(spokeBBridge))),
            payload
        );

        assertTrue(spokeBBinaryModule.hasResult(ConditionIdLib.from(conditionId)), "Hub lane was refused");
    }

    /// @dev The source check passes here and only the local check refuses; fails if collapsed.
    function test_revert_CcipBridge_receiveResult_hubSelfLane() public {
        (bytes32 conditionId,,) = _setupBinaryCondition(bytes("test-result-hub-self"), 100_000_000);

        uint256[] memory forgedResult = new uint256[](2);
        forgedResult[0] = 0;
        forgedResult[1] = 1_000_000;
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.RESULT)), abi.encode(conditionId, forgedResult));

        CcipBridge hubBridgeCcip = CcipBridge(address(hubBridge));

        // The hub's own selector is a configurable peer.
        vm.chainId(HUB_CHAIN_ID);
        vm.prank(owner);
        hubBridgeCcip.setPeer(HUB_SELECTOR, _toBytes32(address(hubBridgeCcip)));

        // Source check satisfied; the local check refuses.
        assertEq(hubBridgeCcip.RESOLUTION_CHAIN_SELECTOR(), HUB_SELECTOR);
        vm.expectRevert(BridgeBase.LocalResolutionChain.selector);
        hubRouter.simulateReceive(uint64(HUB_SELECTOR), address(hubBridgeCcip), address(hubBridgeCcip), payload);

        assertFalse(hubBinaryModule.hasResult(ConditionIdLib.from(conditionId)), "Hub imported a result");
    }
}

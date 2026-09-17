// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import { Ownable } from "@solady/src/auth/Ownable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { CallContextChecker } from "@solady/src/utils/CallContextChecker.sol";

import { CcipBridge } from "@polymarket-v2/src/bridge/CcipBridge.sol";
import { BridgeBase } from "@polymarket-v2/src/bridge/abstract/BridgeBase.sol";
import { BridgePayloads } from "@polymarket-v2/src/libraries/BridgePayloads.sol";
import { MessageType } from "@polymarket-v2/src/libraries/CrossChainTypes.sol";
import { ConditionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { BridgeUnitTestBase } from "./base/BridgeUnitTestBase.t.sol";
import { MockCcipRouter } from "./mocks/MockCcipRouter.sol";

contract CcipBridgeUnitTest is BridgeUnitTestBase {
    MockCcipRouter public router;
    CcipBridge public ccipBridge;

    /// @dev `_baseSetUp` stands the bridge on the spoke, so the remote peer is the hub.
    uint256 public constant LOCAL_SELECTOR = 4949039107694359620;
    uint256 public constant REMOTE_SELECTOR = 4051577828743386545;
    /// @dev A peer that is neither the local chain nor the resolution chain.
    uint256 public constant OTHER_SPOKE_SELECTOR = 15971525489660198786;

    function setUp() public {
        REMOTE_DST = REMOTE_SELECTOR;

        router = new MockCcipRouter(uint64(LOCAL_SELECTOR));

        // _baseSetUp needs bridge set first (for role grants)
        // Deploy a temporary to get the address, then deploy for real after PM exists
        // Actually: deploy collateral+PM first, then bridge
        _deployCollateralAndPM();

        address bridgeImpl = address(
            new CcipBridge(
                address(router), address(positionManager), address(collateralToken), HUB_CHAIN_ID, REMOTE_SELECTOR
            )
        );
        address bridgeProxy = LibClone.deployERC1967(bridgeImpl);
        ccipBridge = CcipBridge(bridgeProxy);
        ccipBridge.initialize(owner, admin);
        bridge = BridgeBase(address(ccipBridge));

        _baseSetUp();

        // Configure transport-specific peer + module support
        bridge.setModuleSupported(address(binaryModule), REMOTE_SELECTOR, true);
        bridge.setModuleSupported(address(negRiskModule), REMOTE_SELECTOR, true);
        ccipBridge.setPeer(REMOTE_SELECTOR, _toBytes32(address(ccipBridge)));

        // A second, equally authorized peer that is not the resolution chain.
        ccipBridge.setPeer(OTHER_SPOKE_SELECTOR, _toBytes32(address(ccipBridge)));
        bridge.setModuleSupported(address(binaryModule), OTHER_SPOKE_SELECTOR, true);
        bridge.setModuleSupported(address(negRiskModule), OTHER_SPOKE_SELECTOR, true);
    }

    /*--------------------------------------------------------------
                       VIRTUAL IMPLEMENTATIONS
    --------------------------------------------------------------*/

    function _simulateReceive(bytes memory _payload) internal override {
        router.simulateReceive(uint64(REMOTE_SELECTOR), address(ccipBridge), address(ccipBridge), _payload);
    }

    function _simulateReceiveFromNonResolutionChain(bytes memory _payload) internal override {
        router.simulateReceive(uint64(OTHER_SPOKE_SELECTOR), address(ccipBridge), address(ccipBridge), _payload);
    }

    function _simulateReceiveUnauthorized(bytes memory _payload) internal override {
        router.simulateReceive(uint64(REMOTE_SELECTOR), address(0xdead), address(ccipBridge), _payload);
    }

    function _getSentMessageCount() internal view override returns (uint256) {
        return router.getSentMessageCount();
    }

    function _setPeerAndExpectRevert(uint256 _dst) internal override {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ccipBridge.setPeer(_dst, _toBytes32(address(1)));
    }

    function _getUnauthorizedSenderError() internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(CcipBridge.UnauthorizedSender.selector);
    }

    function _setPeerForRoute(uint256 _dst) internal override {
        ccipBridge.setPeer(_dst, _toBytes32(address(ccipBridge)));
    }

    /*--------------------------------------------------------------
                         INITIALIZE TESTS
    --------------------------------------------------------------*/

    function test_CcipBridge_initialize_setsOwnerAndAdmin() public view {
        assertEq(ccipBridge.owner(), owner);
        assertTrue(ccipBridge.hasAllRoles(admin, ccipBridge.ADMIN_ROLE()));
    }

    function test_revert_CcipBridge_initialize_zeroOwner() public {
        address bridgeImpl = address(
            new CcipBridge(
                address(router), address(positionManager), address(collateralToken), HUB_CHAIN_ID, REMOTE_SELECTOR
            )
        );
        address bridgeProxy = LibClone.deployERC1967(bridgeImpl);

        vm.expectRevert(CcipBridge.InvalidOwner.selector);
        CcipBridge(bridgeProxy).initialize(address(0), admin);
    }

    function test_revert_CcipBridge_initialize_zeroAdmin() public {
        address bridgeImpl = address(
            new CcipBridge(
                address(router), address(positionManager), address(collateralToken), HUB_CHAIN_ID, REMOTE_SELECTOR
            )
        );
        address bridgeProxy = LibClone.deployERC1967(bridgeImpl);

        vm.expectRevert(CcipBridge.InvalidAdmin.selector);
        CcipBridge(bridgeProxy).initialize(owner, address(0));
    }

    function test_revert_CcipBridge_initialize_twice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ccipBridge.initialize(owner, admin);
    }

    function test_revert_CcipBridge_initialize_onImplementation() public {
        address bridgeImpl = address(
            new CcipBridge(
                address(router), address(positionManager), address(collateralToken), HUB_CHAIN_ID, REMOTE_SELECTOR
            )
        );

        vm.expectRevert(CallContextChecker.UnauthorizedCallContext.selector);
        CcipBridge(bridgeImpl).initialize(owner, admin);
    }

    /*--------------------------------------------------------------
                           UUPS TESTS
    --------------------------------------------------------------*/

    function test_CcipBridge_upgrade_ownerSucceedsAndPreservesStorage() public {
        ccipBridge.pauseSend();
        ccipBridge.pauseReceive();

        address newImpl = address(
            new CcipBridge(
                address(router), address(positionManager), address(collateralToken), HUB_CHAIN_ID, REMOTE_SELECTOR
            )
        );
        ccipBridge.upgradeToAndCall(newImpl, "");

        assertEq(ccipBridge.peers(REMOTE_SELECTOR), _toBytes32(address(ccipBridge)));
        assertTrue(bridge.moduleSupported(1, REMOTE_SELECTOR));
        assertTrue(bridge.moduleSupported(2, REMOTE_SELECTOR));
        assertTrue(bridge.sendPaused());
        assertTrue(bridge.receivePaused());
        assertTrue(ccipBridge.hasAllRoles(admin, ccipBridge.ADMIN_ROLE()));
    }

    function test_CcipBridge_upgrade_canChangeRouter() public {
        MockCcipRouter newRouter = new MockCcipRouter(uint64(LOCAL_SELECTOR));
        address newImpl = address(
            new CcipBridge(
                address(newRouter), address(positionManager), address(collateralToken), HUB_CHAIN_ID, REMOTE_SELECTOR
            )
        );

        ccipBridge.upgradeToAndCall(newImpl, "");

        assertEq(ccipBridge.getRouter(), address(newRouter));
    }

    function test_revert_CcipBridge_upgrade_unauthorized() public {
        address newImpl = address(
            new CcipBridge(
                address(router), address(positionManager), address(collateralToken), HUB_CHAIN_ID, REMOTE_SELECTOR
            )
        );

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ccipBridge.upgradeToAndCall(newImpl, "");
    }

    /*--------------------------------------------------------------
                    CCIP-SPECIFIC TESTS
    --------------------------------------------------------------*/

    function test_revert_CcipBridge_setPeer_invalidChainSelector() public {
        uint256 oversizedSelector = uint256(type(uint64).max) + 1;

        vm.expectRevert(CcipBridge.InvalidChainSelector.selector);
        ccipBridge.setPeer(oversizedSelector, _toBytes32(address(1)));
    }

    function test_revert_CcipBridge_setPeer_zeroPeer() public {
        vm.expectRevert(CcipBridge.ZeroPeer.selector);
        ccipBridge.setPeer(REMOTE_SELECTOR, bytes32(0));
    }

    function test_CcipBridge_setPeer_rawBytes32Peer() public {
        bytes32 rawPeer = keccak256("non-evm-peer");

        vm.expectEmit(true, false, false, true, address(ccipBridge));
        emit CcipBridge.PeerSet(REMOTE_SELECTOR, rawPeer);
        ccipBridge.setPeer(REMOTE_SELECTOR, rawPeer);

        assertEq(ccipBridge.peers(REMOTE_SELECTOR), rawPeer);
    }

    function test_CcipBridge_receive_rawBytes32Peer() public {
        bytes32 rawPeer = keccak256("non-evm-peer");
        ccipBridge.setPeer(REMOTE_SELECTOR, rawPeer);

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        vm.expectEmit(false, true, false, true, address(ccipBridge));
        emit BridgeBase.CollateralReceived(bytes32(0), recipient, 1000 ether);
        router.simulateReceiveRaw(uint64(REMOTE_SELECTOR), abi.encode(rawPeer), address(ccipBridge), payload);

        assertEq(collateralToken.balanceOf(recipient), 1000 ether);
    }

    function test_revert_CcipBridge_receive_dirtyUpperBitsSender() public {
        // Sender whose low 160 bits match the configured peer but whose upper bits are dirty
        bytes32 dirtySender = _toBytes32(address(ccipBridge)) | bytes32(uint256(0xff) << 160);

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        vm.expectRevert(CcipBridge.UnauthorizedSender.selector);
        router.simulateReceiveRaw(uint64(REMOTE_SELECTOR), abi.encode(dirtySender), address(ccipBridge), payload);
    }

    function test_CcipBridge_send_emitsRouterMessageId() public {
        collateralToken.mint(address(bridge), 1000 ether);

        // MockCcipRouter.ccipSend's deterministic return for its first message (nonce 1)
        bytes memory payload = BridgePayloads.collateral(_toBytes32(recipient), 100 ether);
        bytes32 expectedId = keccak256(abi.encode(uint64(LOCAL_SELECTOR), uint64(REMOTE_SELECTOR), uint256(1), payload));

        vm.expectEmit(true, true, true, true, address(bridge));
        emit BridgeBase.CollateralBridged(expectedId, REMOTE_SELECTOR, address(this), _toBytes32(recipient), 100 ether);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), "");
    }

    function test_revert_CcipBridge_pauseChainSend_invalidChainSelector() public {
        uint256 oversizedSelector = uint256(type(uint64).max) + 1;

        vm.expectRevert(CcipBridge.InvalidChainSelector.selector);
        bridge.pauseChainSend(oversizedSelector);
    }

    function test_revert_CcipBridge_pauseChainReceive_invalidChainSelector() public {
        uint256 oversizedSelector = uint256(type(uint64).max) + 1;

        vm.expectRevert(CcipBridge.InvalidChainSelector.selector);
        bridge.pauseChainReceive(oversizedSelector);
    }

    function test_revert_CcipBridge_setModuleSupported_invalidChainSelector() public {
        uint256 oversizedSelector = uint256(type(uint64).max) + 1;

        vm.expectRevert(CcipBridge.InvalidChainSelector.selector);
        bridge.setModuleSupported(address(binaryModule), oversizedSelector, true);
    }

    function test_revert_CcipBridge_setBatchModuleSupported_invalidChainSelector() public {
        uint256[] memory selectors = new uint256[](2);
        selectors[0] = 10;
        selectors[1] = uint256(type(uint64).max) + 1;

        vm.expectRevert(CcipBridge.InvalidChainSelector.selector);
        bridge.setBatchModuleSupported(address(binaryModule), selectors, true);
    }

    function test_revert_CcipBridge_bridgeCollateral_peerNotSet() public {
        collateralToken.mint(address(bridge), 1000 ether);

        uint256 unconfiguredSelector = 12345;

        vm.expectRevert(CcipBridge.PeerNotSet.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(unconfiguredSelector, 100 ether, _toBytes32(recipient), "");
    }

    function test_revert_CcipBridge_quoteBridgeCollateral_peerNotSet() public {
        uint256 unconfiguredSelector = 12345;

        vm.expectRevert(CcipBridge.PeerNotSet.selector);
        bridge.quoteBridgeCollateral(unconfiguredSelector, 100 ether, _toBytes32(recipient), "");
    }

    /*--------------------------------------------------------------
                    MESSAGING OPTIONS TESTS
    --------------------------------------------------------------*/

    function test_CcipBridge_send_emptyOptions_defaultGasOutOfOrder() public {
        collateralToken.mint(address(bridge), 1000 ether);

        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), "");

        bytes memory expected = Client._argsToBytes(
            Client.GenericExtraArgsV2({ gasLimit: ccipBridge.DEFAULT_GAS_LIMIT(), allowOutOfOrderExecution: true })
        );
        assertEq(router.getLastSentMessage().extraArgs, expected);
    }

    function test_CcipBridge_send_gasLimitOptions_outOfOrder() public {
        collateralToken.mint(address(bridge), 1000 ether);

        bridge.bridgeCollateral{ value: 0.01 ether }(
            REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), abi.encode(uint256(500_000))
        );

        bytes memory expected =
            Client._argsToBytes(Client.GenericExtraArgsV2({ gasLimit: 500_000, allowOutOfOrderExecution: true }));
        assertEq(router.getLastSentMessage().extraArgs, expected);
    }

    function test_CcipBridge_quote_gasLimitOptions() public view {
        (uint256 nativeFee,) = bridge.quoteBridgeCollateral(
            REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), abi.encode(uint256(500_000))
        );
        assertGt(nativeFee, 0);
    }

    function test_revert_CcipBridge_send_invalidOptions() public {
        collateralToken.mint(address(bridge), 1000 ether);

        // Raw CCIP extraArgs are rejected; only empty or a bare abi-encoded gas limit is accepted
        bytes memory rawExtraArgs =
            Client._argsToBytes(Client.GenericExtraArgsV2({ gasLimit: 200_000, allowOutOfOrderExecution: false }));

        vm.expectRevert(CcipBridge.InvalidOptions.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), rawExtraArgs);
    }

    function test_revert_CcipBridge_quote_invalidOptions() public {
        vm.expectRevert(CcipBridge.InvalidOptions.selector);
        bridge.quoteBridgeCollateral(REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), hex"01");
    }

    /*--------------------------------------------------------------
                    ADMIN ROLE TESTS
    --------------------------------------------------------------*/

    function test_CcipBridge_addAdmin() public {
        ccipBridge.addAdmin(admin);
        assertTrue(ccipBridge.hasAllRoles(admin, 1 << 0));
    }

    function test_CcipBridge_removeAdmin() public {
        ccipBridge.addAdmin(admin);
        ccipBridge.removeAdmin(admin);
        assertFalse(ccipBridge.hasAllRoles(admin, 1 << 0));
    }

    function test_revert_CcipBridge_addAdmin_nonOwner() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ccipBridge.addAdmin(admin);
    }

    function test_revert_CcipBridge_removeAdmin_nonOwner() public {
        ccipBridge.addAdmin(admin);

        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ccipBridge.removeAdmin(admin);
    }

    function test_CcipBridge_adminCanPause() public {
        ccipBridge.addAdmin(admin);

        vm.prank(admin);
        bridge.pauseSend();
        assertTrue(bridge.sendPaused());

        vm.prank(admin);
        bridge.pauseReceive();
        assertTrue(bridge.receivePaused());
    }

    function test_CcipBridge_adminCanUnpause() public {
        ccipBridge.addAdmin(admin);

        bridge.pauseSend();
        bridge.pauseReceive();

        vm.prank(admin);
        bridge.unpauseSend();
        assertFalse(bridge.sendPaused());

        vm.prank(admin);
        bridge.unpauseReceive();
        assertFalse(bridge.receivePaused());
    }

    function test_revert_CcipBridge_adminCannotSetPeer() public {
        ccipBridge.addAdmin(admin);

        vm.prank(admin);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ccipBridge.setPeer(REMOTE_SELECTOR, _toBytes32(address(1)));
    }

    function test_revert_CcipBridge_adminCannotSetModuleSupported() public {
        ccipBridge.addAdmin(admin);

        vm.prank(admin);
        vm.expectRevert(Ownable.Unauthorized.selector);
        bridge.setModuleSupported(address(binaryModule), REMOTE_SELECTOR, false);
    }

    /*--------------------------------------------------------------
                    REMOVE PEER TESTS
    --------------------------------------------------------------*/

    function test_CcipBridge_removePeer() public {
        assertEq(ccipBridge.peers(REMOTE_SELECTOR), _toBytes32(address(ccipBridge)));

        vm.expectEmit(true, false, false, true, address(ccipBridge));
        emit CcipBridge.PeerSet(REMOTE_SELECTOR, bytes32(0));
        ccipBridge.removePeer(REMOTE_SELECTOR);

        assertEq(ccipBridge.peers(REMOTE_SELECTOR), bytes32(0));
    }

    function test_CcipBridge_setPeer_afterRemoval() public {
        ccipBridge.removePeer(REMOTE_SELECTOR);
        assertEq(ccipBridge.peers(REMOTE_SELECTOR), bytes32(0));

        bytes32 newPeer = _toBytes32(address(0xBEEF));
        ccipBridge.setPeer(REMOTE_SELECTOR, newPeer);
        assertEq(ccipBridge.peers(REMOTE_SELECTOR), newPeer);
    }

    function test_revert_CcipBridge_removePeer_nonOwner() public {
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ccipBridge.removePeer(REMOTE_SELECTOR);
    }

    function test_revert_CcipBridge_removePeer_adminCannotRemove() public {
        ccipBridge.addAdmin(admin);

        vm.prank(admin);
        vm.expectRevert(Ownable.Unauthorized.selector);
        ccipBridge.removePeer(REMOTE_SELECTOR);
    }

    function test_revert_CcipBridge_removePeer_invalidChainSelector() public {
        uint256 oversizedSelector = uint256(type(uint64).max) + 1;

        vm.expectRevert(CcipBridge.InvalidChainSelector.selector);
        ccipBridge.removePeer(oversizedSelector);
    }

    function test_revert_CcipBridge_bridgeCollateral_afterPeerRemoved() public {
        ccipBridge.removePeer(REMOTE_SELECTOR);

        collateralToken.mint(address(bridge), 1000 ether);

        vm.expectRevert(CcipBridge.PeerNotSet.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), "");
    }

    function test_revert_CcipBridge_quoteBridgeCollateral_afterPeerRemoved() public {
        ccipBridge.removePeer(REMOTE_SELECTOR);

        vm.expectRevert(CcipBridge.PeerNotSet.selector);
        bridge.quoteBridgeCollateral(REMOTE_SELECTOR, 100 ether, _toBytes32(recipient), "");
    }

    function test_revert_CcipBridge_receive_afterPeerRemoved() public {
        ccipBridge.removePeer(REMOTE_SELECTOR);

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        vm.expectRevert(CcipBridge.UnauthorizedSender.selector);
        router.simulateReceive(uint64(REMOTE_SELECTOR), address(ccipBridge), address(ccipBridge), payload);
    }

    /*--------------------------------------------------------------
                      RESOLUTION CHAIN TESTS
    --------------------------------------------------------------*/

    function test_CcipBridge_resolutionChainId() public view {
        assertEq(ccipBridge.RESOLUTION_CHAIN_ID(), HUB_CHAIN_ID);
    }

    function test_CcipBridge_resolutionChainSelector() public view {
        assertEq(ccipBridge.RESOLUTION_CHAIN_SELECTOR(), REMOTE_SELECTOR);
    }

    function test_revert_CcipBridge_constructor_zeroResolutionChainId() public {
        vm.expectRevert(BridgeBase.InvalidResolutionChainId.selector);
        new CcipBridge(address(router), address(positionManager), address(collateralToken), 0, REMOTE_SELECTOR);
    }

    function test_revert_CcipBridge_constructor_zeroResolutionChainSelector() public {
        vm.expectRevert(CcipBridge.InvalidResolutionChainSelector.selector);
        new CcipBridge(address(router), address(positionManager), address(collateralToken), HUB_CHAIN_ID, 0);
    }

    /// @dev A selector out of `uint64` range could never be a source chain.
    function test_revert_CcipBridge_constructor_resolutionChainSelectorAboveUint64() public {
        vm.expectRevert(CcipBridge.InvalidChainSelector.selector);
        new CcipBridge(
            address(router),
            address(positionManager),
            address(collateralToken),
            HUB_CHAIN_ID,
            uint256(type(uint64).max) + 1
        );
    }

    /// @dev The exporting chain follows the configured immutable, not one fixed chain id.
    function test_CcipBridge_bridgeResult_fromConfiguredResolutionChain() public {
        // A bridge configured to treat the chain the unit tests stand on as the resolution chain.
        address altImpl = address(
            new CcipBridge(
                address(router), address(positionManager), address(collateralToken), SPOKE_CHAIN_ID, REMOTE_SELECTOR
            )
        );
        CcipBridge altBridge = CcipBridge(LibClone.deployERC1967(altImpl));
        altBridge.initialize(owner, admin);
        altBridge.setPeer(REMOTE_SELECTOR, _toBytes32(address(altBridge)));
        altBridge.setModuleSupported(address(binaryModule), REMOTE_SELECTOR, true);
        binaryModule.addBridge(address(altBridge));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;
        binaryModule.reportResult(ConditionIdLib.from(testConditionId), result);

        assertEq(block.chainid, SPOKE_CHAIN_ID);
        assertEq(altBridge.RESOLUTION_CHAIN_ID(), SPOKE_CHAIN_ID);

        vm.expectEmit(false, true, true, true, address(altBridge));
        emit BridgeBase.ResultBridged(bytes32(0), REMOTE_SELECTOR, ConditionIdLib.from(testConditionId));
        altBridge.bridgeResult{ value: 0.01 ether }(REMOTE_SELECTOR, ConditionIdLib.from(testConditionId), "");

        assertEq(router.getSentMessageCount(), 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Test, stdError } from "forge-std/Test.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";
import { ERC1155 } from "@solady/src/tokens/ERC1155.sol";

import { BridgeBase } from "@polymarket-v2/src/bridge/abstract/BridgeBase.sol";
import { MessageType, BridgedPosition } from "@polymarket-v2/src/libraries/CrossChainTypes.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ModuleProxyLib } from "@polymarket-v2/src/modules/dev/ModuleProxyLib.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { Collateral, CollateralSetup } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { ConditionId, EventId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionId, PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

/// @title BridgeUnitTestBase
/// @notice Abstract base containing all shared unit test logic for bridge transports.
/// @dev Concrete implementations set `bridge`, `REMOTE_DST`, deploy the transport mock,
///      and override the virtual functions that differ between transport layers.
abstract contract BridgeUnitTestBase is Test {
    /*--------------------------------------------------------------
                           CONTRACTS
    --------------------------------------------------------------*/

    /// @dev Set by concrete setUp before calling _baseSetUp
    BridgeBase public bridge;
    PositionManager public positionManager;
    CollateralToken public collateralToken;
    BinaryModule public binaryModule;
    NegRiskModule public negRiskModule;

    /*--------------------------------------------------------------
                         TEST ADDRESSES
    --------------------------------------------------------------*/

    address public owner = address(this);
    address public admin = address(0x3);
    address public user = address(0x1);
    address public recipient = address(0x2);

    /*--------------------------------------------------------------
                         TEST CONSTANTS
    --------------------------------------------------------------*/

    /// @dev Set by concrete setUp (CCIP chain selector)
    uint256 public REMOTE_DST;
    uint256 public constant HUB_CHAIN_ID = 137;
    /// @dev The unit bridge stands on a spoke: test conditions resolve on the hub and are imported.
    uint256 public constant SPOKE_CHAIN_ID = 42161;
    uint256 internal constant MINTER_ROLE = 1 << 0;

    /*--------------------------------------------------------------
                           TEST DATA
    --------------------------------------------------------------*/

    bytes32 internal testConditionId;
    bytes32 internal testEventId;
    uint256 internal testPositionId0;
    uint256 internal testPositionId1;

    /*--------------------------------------------------------------
                       VIRTUAL FUNCTIONS
    --------------------------------------------------------------*/

    /// @dev Simulate receiving a cross-chain message from the configured remote peer
    function _simulateReceive(bytes memory _payload) internal virtual;

    /// @dev Simulate receiving a cross-chain message from an unauthorized sender
    function _simulateReceiveUnauthorized(bytes memory _payload) internal virtual;

    /// @dev Simulate receiving from a configured peer other than the resolution chain
    function _simulateReceiveFromNonResolutionChain(bytes memory _payload) internal virtual;

    /// @dev Return the number of outbound messages sent through the transport mock
    function _getSentMessageCount() internal view virtual returns (uint256);

    /// @dev Attempt setPeer as non-owner and expect revert
    function _setPeerAndExpectRevert(uint256 _dst) internal virtual;

    /// @dev Return the expected revert data for unauthorized sender
    function _getUnauthorizedSenderError() internal view virtual returns (bytes memory);

    /// @dev Set a peer for the given route (used by routeNotSupported tests)
    function _setPeerForRoute(uint256 _dst) internal virtual;

    /*--------------------------------------------------------------
                          SHARED SETUP
    --------------------------------------------------------------*/

    /// @notice Deploy collateral and position manager. Call before deploying the bridge.
    function _deployCollateralAndPM() internal {
        Collateral memory collateral = CollateralSetup._deploy(owner);
        collateralToken = collateral.token;

        address positionManagerImpl = address(new PositionManager(address(collateralToken)));
        address positionManagerProxy = LibClone.deployERC1967(positionManagerImpl);
        positionManager = PositionManager(positionManagerProxy);
        positionManager.initialize(owner, owner);
    }

    /// @notice Deploy modules, configure roles, and set up test data.
    ///         Concrete setUp must call _deployCollateralAndPM(), deploy the bridge,
    ///         set `bridge`, then call this.
    function _baseSetUp() internal {
        vm.chainId(SPOKE_CHAIN_ID);

        // Deploy modules
        binaryModule = ModuleProxyLib.deployBinaryModule(address(positionManager), owner, owner, address(0), address(0));
        negRiskModule = ModuleProxyLib.deployNegRiskModule(
            address(positionManager), owner, owner, address(0), address(0), address(0)
        );

        // Register modules
        positionManager.addModule(address(binaryModule));
        positionManager.addModule(address(negRiskModule));

        // Grant bridge role
        binaryModule.addBridge(address(bridge));
        negRiskModule.addBridge(address(bridge));

        // Grant bridge role to test contract for direct module calls
        binaryModule.addBridge(owner);
        negRiskModule.addBridge(owner);

        // Grant minter role to bridge and test contract for collateral
        collateralToken.addMinter(address(bridge));
        collateralToken.addMinter(owner);

        // Setup test condition
        bytes32 testBaseHash = keccak256(abi.encode(HUB_CHAIN_ID, address(binaryModule), "test-condition"));
        testConditionId = ConditionId.unwrap(ConditionIdLib.encode(ModuleIds.BINARY, testBaseHash, 0, 0));
        testPositionId0 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(testConditionId)), 0));
        testPositionId1 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(testConditionId)), 1));

        // Setup test event for NegRisk
        testEventId = EventId.unwrap(
            EventIdLib.encode(
                ModuleIds.NEGRISK, keccak256(abi.encode(HUB_CHAIN_ID, address(negRiskModule), "test-event")), 3
            )
        );

        // Fund user
        vm.deal(user, 10 ether);
    }

    function _deployEnabledCombinatorialModule() internal returns (CombinatorialModule combinatorialModule) {
        combinatorialModule = ModuleProxyLib.deployCombinatorialModule(address(positionManager), owner, owner);
        positionManager.addModule(address(combinatorialModule));
        // Route left enabled on purpose: the combinatorial rejection must win over configuration.
        bridge.setModuleSupported(address(combinatorialModule), REMOTE_DST, true);
    }

    function _getCombinatorialPositionId() internal pure returns (PositionId) {
        ConditionId conditionId =
            ConditionIdLib.encode(ModuleIds.COMBINATORIAL, keccak256("combinatorial-bridge"), 0, 0);
        return conditionId.computePositionId(0);
    }

    /*--------------------------------------------------------------
                          ADMIN TESTS
    --------------------------------------------------------------*/

    function test_bridge_setModuleSupported() public {
        uint256 newDst = 3;

        bridge.setModuleSupported(address(binaryModule), newDst, true);

        assertEq(bridge.moduleSupported(1, newDst), true);
    }

    function test_revert_bridge_setModuleSupported_invalidModule() public {
        BinaryModule unregisteredModule =
            new BinaryModule(address(positionManager), address(0), address(0), ResolutionChain.POLYGON);

        vm.expectRevert(BridgeBase.ModuleNotRegistered.selector);
        bridge.setModuleSupported(address(unregisteredModule), REMOTE_DST, true);
    }

    /*--------------------------------------------------------------
                     POSITION RECEIVE TESTS
    --------------------------------------------------------------*/

    function test_bridge_receivePositions_binary() public {
        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(testPositionId0), amount: 1000 ether });

        bytes memory innerData = abi.encode(recipient, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        _simulateReceive(payload);

        assertEq(positionManager.balanceOf(recipient, testPositionId0), 1000 ether);
    }

    function test_bridge_receivePositions_negRisk() public {
        bytes32 negRiskConditionId =
            ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(testEventId)), 0));
        uint256 negRiskPositionId1 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(negRiskConditionId)), 1));

        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(negRiskPositionId1), amount: 500 ether });

        bytes memory innerData = abi.encode(recipient, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        _simulateReceive(payload);

        uint256 positionId1 =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(negRiskConditionId)), 1));
        assertEq(positionManager.balanceOf(recipient, positionId1), 500 ether);
    }

    /*--------------------------------------------------------------
                    COLLATERAL RECEIVE TESTS
    --------------------------------------------------------------*/

    function test_bridge_receiveCollateral() public {
        uint256 amount = 1000 ether;

        bytes memory innerData = abi.encode(recipient, amount);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        _simulateReceive(payload);

        assertEq(collateralToken.balanceOf(recipient), amount);
    }

    /*--------------------------------------------------------------
                      RESULT RECEIVE TESTS
    --------------------------------------------------------------*/

    function test_bridge_receiveResult() public {
        // Bridge has _ROLE_3 so it can resolve directly (no condition preparation needed)
        uint256[] memory resultData = new uint256[](2);
        resultData[0] = 1_000_000;
        resultData[1] = 0;

        bytes memory innerData = abi.encode(testConditionId, resultData);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.RESULT)), innerData);

        _simulateReceive(payload);

        assertTrue(binaryModule.hasResult(ConditionIdLib.from(testConditionId)));
        uint256[] memory storedResult = binaryModule.getResult(ConditionIdLib.from(testConditionId));
        assertEq(storedResult[0], 1_000_000);
        assertEq(storedResult[1], 0);
    }

    /// @dev Asserts the specific error; the source check does not cover this case.
    function test_revert_bridge_receiveResult_localResolutionChain() public {
        // Stand the bridge on the resolution chain.
        vm.chainId(HUB_CHAIN_ID);

        uint256[] memory resultData = new uint256[](2);
        resultData[0] = 1_000_000;
        resultData[1] = 0;

        bytes memory innerData = abi.encode(testConditionId, resultData);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.RESULT)), innerData);

        vm.expectRevert(BridgeBase.LocalResolutionChain.selector);
        _simulateReceive(payload);

        assertFalse(binaryModule.hasResult(ConditionIdLib.from(testConditionId)));
    }

    /// @dev A result is only valid on the resolution chain's lane; the peer's guard is not evidence.
    function test_revert_bridge_receiveResult_unexpectedSource() public {
        uint256[] memory resultData = new uint256[](2);
        resultData[0] = 1_000_000;
        resultData[1] = 0;

        bytes memory innerData = abi.encode(testConditionId, resultData);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.RESULT)), innerData);

        vm.expectRevert(BridgeBase.UnexpectedResultSource.selector);
        _simulateReceiveFromNonResolutionChain(payload);

        assertFalse(binaryModule.hasResult(ConditionIdLib.from(testConditionId)));
    }

    /// @dev Positions and collateral are lane-agnostic, so the source check must not leak onto them.
    function test_bridge_receivePositions_fromNonResolutionChain() public {
        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(testPositionId0), amount: 1000 ether });

        bytes memory innerData = abi.encode(recipient, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        _simulateReceiveFromNonResolutionChain(payload);

        assertEq(positionManager.balanceOf(recipient, testPositionId0), 1000 ether);
    }

    function test_bridge_receiveCollateral_fromNonResolutionChain() public {
        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        _simulateReceiveFromNonResolutionChain(payload);

        assertEq(collateralToken.balanceOf(recipient), 1000 ether);
    }

    /*--------------------------------------------------------------
                      POSITION SEND TESTS
    --------------------------------------------------------------*/

    function test_bridge_bridgePositions() public {
        // Receive some positions to user
        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(testPositionId0), amount: 1000 ether });

        bytes memory innerData = abi.encode(user, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        _simulateReceive(payload);

        // Bridge them out — pre-transfer to bridge, then call
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(testPositionId0);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        vm.prank(user);
        positionManager.unsafeBatchTransferFrom(user, address(bridge), positionIds, amounts);

        vm.prank(user);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), bytes(""));

        assertEq(_getSentMessageCount(), 1);
        assertEq(positionManager.balanceOf(user, testPositionId0), 500 ether);
    }

    function test_bridge_bridgePositions_noConditionPreparationNeeded() public {
        uint256 positionId = testPositionId0;
        uint256 amount = 500 ether;

        vm.prank(address(bridge));
        binaryModule.mintFromBridge(user, PositionId.wrap(positionId), amount);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(positionId);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        positionManager.unsafeBatchTransferFrom(user, address(bridge), positionIds, amounts);

        // Bridging no longer requires condition preparation
        vm.prank(user);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), "");

        assertEq(_getSentMessageCount(), 1);
        assertEq(positionManager.balanceOf(user, positionId), 0);
    }

    /*--------------------------------------------------------------
                     COLLATERAL SEND TESTS
    --------------------------------------------------------------*/

    function test_bridge_bridgeCollateral() public {
        collateralToken.mint(user, 1000 ether);

        vm.prank(user);
        collateralToken.transfer(address(bridge), 500 ether);

        vm.prank(user);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, _toBytes32(recipient), bytes(""));

        assertEq(_getSentMessageCount(), 1);
        assertEq(collateralToken.balanceOf(user), 500 ether);
    }

    /*--------------------------------------------------------------
                          QUOTE TESTS
    --------------------------------------------------------------*/

    function test_bridge_quoteBridgeCollateral() public view {
        (uint256 nativeFee, uint256 alternativeFee) =
            bridge.quoteBridgeCollateral(REMOTE_DST, 1000 ether, _toBytes32(recipient), bytes(""));

        assertGt(nativeFee, 0);
        assertEq(alternativeFee, 0);
    }

    function test_bridge_quoteBridgePositions() public view {
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(testPositionId0);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        (uint256 nativeFee, uint256 alternativeFee) =
            bridge.quoteBridgePositions(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), bytes(""));

        assertGt(nativeFee, 0);
        assertEq(alternativeFee, 0);
    }

    function test_bridge_quoteBridgeResult() public {
        // Bridge has _ROLE_3 so it can resolve
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;
        binaryModule.reportResult(ConditionIdLib.from(testConditionId), result);

        (uint256 nativeFee, uint256 alternativeFee) =
            bridge.quoteBridgeResult(REMOTE_DST, ConditionIdLib.from(testConditionId), "");

        assertGt(nativeFee, 0, "Native fee should be non-zero");
        assertEq(alternativeFee, 0, "Alternative fee should be zero");
    }

    /*--------------------------------------------------------------
                   QUOTE FUNCTION EDGE CASES
    --------------------------------------------------------------*/

    function test_bridge_quoteBridgePositions_emptyArray() public view {
        PositionId[] memory positionIds = new PositionId[](0);
        uint256[] memory amounts = new uint256[](0);

        (uint256 nativeFee, uint256 alternativeFee) =
            bridge.quoteBridgePositions(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), "");

        assertEq(nativeFee, 0, "Native fee should be zero for empty array");
        assertEq(alternativeFee, 0, "Alternative fee should be zero for empty array");
    }

    function test_revert_bridge_quoteBridgePositions_lengthMismatch() public {
        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(testPositionId0);
        positionIds[1] = PositionId.wrap(testPositionId1);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        vm.expectRevert(BridgeBase.ArrayLengthMismatch.selector);
        bridge.quoteBridgePositions(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), "");
    }

    /*--------------------------------------------------------------
                     BATCH & CALLBACK TESTS
    --------------------------------------------------------------*/

    function test_bridge_setBatchModuleSupported() public {
        uint256[] memory dsts = new uint256[](3);
        dsts[0] = 10;
        dsts[1] = 20;
        dsts[2] = 30;

        bridge.setBatchModuleSupported(address(binaryModule), dsts, true);

        assertEq(bridge.moduleSupported(1, 10), true);
        assertEq(bridge.moduleSupported(1, 20), true);
        assertEq(bridge.moduleSupported(1, 30), true);
    }

    function test_revert_bridge_setPeer_nonOwner() public {
        _setPeerAndExpectRevert(50);
    }

    function test_bridge_onERC1155Received() public {
        bytes4 sel = bridge.onERC1155Received(address(0), address(0), 0, 0, "");

        assertEq(sel, bridge.onERC1155Received.selector);
    }

    /*--------------------------------------------------------------
                REVERT TESTS - BRIDGE FUNCTIONS
    --------------------------------------------------------------*/

    function test_revert_bridge_bridgePositions_emptyArray() public {
        PositionId[] memory positionIds = new PositionId[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(user);
        vm.expectRevert(BridgeBase.NoPositions.selector);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), "");
    }

    function test_revert_bridge_bridgePositions_lengthMismatch() public {
        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(testPositionId0);
        positionIds[1] = PositionId.wrap(testPositionId1);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        vm.prank(user);
        vm.expectRevert(BridgeBase.ArrayLengthMismatch.selector);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), "");
    }

    function test_revert_bridge_bridgePositions_zeroRecipient() public {
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(testPositionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        vm.prank(user);
        vm.expectRevert(BridgeBase.ZeroRecipient.selector);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, bytes32(0), "");
    }

    function test_revert_bridge_bridgePositions_dirtyRecipient() public {
        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(testPositionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        // Valid address in the low 160 bits, dirty upper bits
        bytes32 dirtyRecipient = _toBytes32(recipient) | bytes32(uint256(1) << 160);

        vm.prank(user);
        vm.expectRevert(BridgeBase.InvalidRecipient.selector);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, dirtyRecipient, "");
    }

    function testFuzz_revert_bridge_bridgePositions_dirtyRecipient(uint256 dirtyRecipient) public {
        // Ensure the upper bits beyond the address are actually dirty
        vm.assume(dirtyRecipient > type(uint160).max);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(testPositionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        vm.prank(user);
        vm.expectRevert(BridgeBase.InvalidRecipient.selector);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, bytes32(dirtyRecipient), "");
    }

    function test_revert_bridge_bridgeCollateral_zeroRecipient() public {
        vm.prank(user);
        vm.expectRevert(BridgeBase.ZeroRecipient.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, bytes32(0), "");
    }

    function test_revert_bridge_bridgeCollateral_dirtyRecipient() public {
        // Valid address in the low 160 bits, dirty upper bits
        bytes32 dirtyRecipient = _toBytes32(recipient) | bytes32(uint256(1) << 160);

        vm.prank(user);
        vm.expectRevert(BridgeBase.InvalidRecipient.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, dirtyRecipient, "");
    }

    function testFuzz_revert_bridge_bridgeCollateral_dirtyRecipient(uint256 dirtyRecipient) public {
        // Ensure the upper bits beyond the address are actually dirty
        vm.assume(dirtyRecipient > type(uint160).max);

        vm.prank(user);
        vm.expectRevert(BridgeBase.InvalidRecipient.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, bytes32(dirtyRecipient), "");
    }

    function test_revert_bridge_bridgeResult_moduleNotConfigured() public {
        // Only the resolution chain may export, so stand the bridge on it for send-path tests.
        vm.chainId(HUB_CHAIN_ID);

        // Well-formed ID naming the hub, but a module that was never registered.
        ConditionId unregisteredModuleConditionId =
            ConditionIdLib.encode(ModuleIds.COMBINATORIAL + 1, keccak256("non-existent"), 0, 0);

        vm.expectRevert(BridgeBase.ModuleNotConfigured.selector);
        bridge.bridgeResult{ value: 0.01 ether }(REMOTE_DST, unregisteredModuleConditionId, "");
    }

    function test_revert_bridge_bridgeResult_routeNotSupported() public {
        vm.chainId(HUB_CHAIN_ID);

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;
        binaryModule.reportResult(ConditionIdLib.from(testConditionId), result);

        uint256 unsupported = 999;
        _setPeerForRoute(unsupported);

        vm.expectRevert(BridgeBase.RouteNotSupported.selector);
        bridge.bridgeResult{ value: 0.01 ether }(unsupported, ConditionIdLib.from(testConditionId), "");
    }

    function test_revert_bridge_bridgeResult_resultNotReported() public {
        vm.chainId(HUB_CHAIN_ID);

        vm.expectRevert(BridgeBase.ResultNotReported.selector);
        bridge.bridgeResult{ value: 0.01 ether }(REMOTE_DST, ConditionIdLib.from(testConditionId), "");
    }

    function test_revert_bridge_bridgeResult_invalidResolutionChainId() public {
        // Bridge stands on a spoke; the condition names the hub as its resolution chain.
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;
        binaryModule.reportResult(ConditionIdLib.from(testConditionId), result);

        vm.expectRevert(BridgeBase.InvalidResolutionChainId.selector);
        bridge.bridgeResult{ value: 0.01 ether }(REMOTE_DST, ConditionIdLib.from(testConditionId), "");

        assertEq(_getSentMessageCount(), 0);
    }

    /*--------------------------------------------------------------
                  POSITION METADATA VALIDATION
    --------------------------------------------------------------*/

    function test_revert_bridge_bridgePositions_routeNotSupported() public {
        binaryModule.mintFromBridge(user, PositionId.wrap(testPositionId0), 100 ether);

        uint256 unsupported = 999;
        _setPeerForRoute(unsupported);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(testPositionId0);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100 ether;

        vm.prank(user);
        positionManager.unsafeBatchTransferFrom(user, address(bridge), positionIds, amounts);

        vm.prank(user);
        vm.expectRevert(BridgeBase.RouteNotSupported.selector);
        bridge.bridgePositions{ value: 0.01 ether }(unsupported, positionIds, amounts, _toBytes32(recipient), "");
    }

    function test_revert_bridge_bridgePositions_differentModules() public {
        bytes32 binaryBaseHash = keccak256("binary-condition");
        bytes32 binaryConditionId = ConditionId.unwrap(ConditionIdLib.encode(ModuleIds.BINARY, binaryBaseHash, 0, 0));
        bytes32 negRiskConditionId =
            ConditionId.unwrap(EventIdLib.computeConditionId(EventId.wrap(bytes29(testEventId)), 0));

        uint256 binaryPositionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(binaryConditionId)), 0));
        uint256 negRiskPositionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(negRiskConditionId)), 0));

        binaryModule.mintFromBridge(user, PositionId.wrap(binaryPositionId), 100 ether);
        negRiskModule.mintFromBridge(user, PositionId.wrap(negRiskPositionId), 100 ether);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = PositionId.wrap(binaryPositionId);
        positionIds[1] = PositionId.wrap(negRiskPositionId);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 100 ether;

        vm.prank(user);
        positionManager.unsafeBatchTransferFrom(user, address(bridge), positionIds, amounts);

        vm.prank(user);
        vm.expectRevert(BridgeBase.PositionsNotSameModule.selector);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), "");
    }

    function test_revert_bridge_bridgePositions_combinatorialNotSupported() public {
        CombinatorialModule combinatorialModule = _deployEnabledCombinatorialModule();
        PositionId positionId = _getCombinatorialPositionId();
        uint256 amount = 100 ether;

        // The module exposes no bridge mint path any more, so mint as the module to stage supply.
        vm.prank(address(combinatorialModule));
        positionManager.mint(user, positionId, amount);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = positionId;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        vm.prank(user);
        positionManager.unsafeBatchTransferFrom(user, address(bridge), positionIds, amounts);

        vm.prank(user);
        vm.expectRevert(BridgeBase.PositionTypeNotSupported.selector);
        // forgefmt: disable-next-item
        bridge.bridgePositions{ value: 0.01 ether }({
            _dstChain: REMOTE_DST,
            _positionIds: positionIds,
            _amounts: amounts,
            _recipient: _toBytes32(recipient),
            _options: ""
        });

        assertEq(_getSentMessageCount(), 0);
        assertEq(positionManager.balanceOf(address(bridge), PositionId.unwrap(positionId)), amount);
    }

    /*--------------------------------------------------------------
                    RECEIVE HANDLER REVERTS
    --------------------------------------------------------------*/

    function test_revert_bridge_receivePositions_combinatorialNotSupported() public {
        _deployEnabledCombinatorialModule();
        PositionId positionId = _getCombinatorialPositionId();

        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: positionId, amount: 1000 ether });

        bytes memory innerData = abi.encode(recipient, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        vm.expectRevert(BridgeBase.PositionTypeNotSupported.selector);
        _simulateReceive(payload);

        assertEq(positionManager.balanceOf(recipient, PositionId.unwrap(positionId)), 0);
    }

    function test_revert_bridge_receivePositions_differentModules() public {
        bytes32 binaryBaseHash = keccak256("binary-condition-receive");
        ConditionId binaryConditionId = ConditionIdLib.encode(ModuleIds.BINARY, binaryBaseHash, 0, 0);
        ConditionId negRiskConditionId = EventIdLib.computeConditionId(EventId.wrap(bytes29(testEventId)), 0);

        uint256 binaryPositionId = PositionId.unwrap(ConditionIdLib.computePositionId(binaryConditionId, 0));
        uint256 negRiskPositionId = PositionId.unwrap(ConditionIdLib.computePositionId(negRiskConditionId, 0));

        BridgedPosition[] memory positions = new BridgedPosition[](2);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(binaryPositionId), amount: 1000 ether });
        positions[1] = BridgedPosition({ positionId: PositionId.wrap(negRiskPositionId), amount: 1000 ether });

        bytes memory innerData = abi.encode(recipient, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        vm.expectRevert(BridgeBase.PositionsNotSameModule.selector);
        _simulateReceive(payload);
    }

    /// @dev An unknown module is refused on type, before configuration is even consulted. Under the
    ///      previous blocklist this reached `ModuleNotConfigured`, i.e. "we would bridge it if it
    ///      were registered" -- the opt-out weakness the allowlist closes.
    function test_revert_bridge_receivePositions_unknownModuleType() public {
        bytes32 invalidConditionId = ConditionId.unwrap(ConditionIdLib.encode(99, keccak256("test"), 0, 0));
        uint256 invalidPositionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(invalidConditionId)), 0));
        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(invalidPositionId), amount: 1000 ether });

        bytes memory innerData = abi.encode(recipient, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        vm.expectRevert(BridgeBase.PositionTypeNotSupported.selector);
        _simulateReceive(payload);
    }

    /// @dev The `ModuleNotConfigured` branch is still reachable for an allowlisted module that is
    ///      not registered on this chain, so the allowlist does not mask it.
    function test_revert_bridge_receivePositions_moduleNotConfigured() public {
        positionManager.removeModule(ModuleIds.BINARY);

        bytes32 conditionId = ConditionId.unwrap(ConditionIdLib.encode(ModuleIds.BINARY, keccak256("test"), 0, 0));
        uint256 positionId =
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(conditionId)), 0));
        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(positionId), amount: 1000 ether });

        bytes memory innerData = abi.encode(recipient, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);

        vm.expectRevert(BridgeBase.ModuleNotConfigured.selector);
        _simulateReceive(payload);
    }

    function test_revert_bridge_receiveResult_moduleNotConfigured() public {
        // Canonical ID for an unregistered module, so the module lookup is what fails.
        bytes32 nonExistentConditionId = ConditionId.unwrap(ConditionIdLib.encode(200, keccak256("non-existent"), 0, 0));
        uint256[] memory resultData = new uint256[](2);
        resultData[0] = 1_000_000;
        resultData[1] = 0;

        bytes memory innerData = abi.encode(nonExistentConditionId, resultData);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.RESULT)), innerData);

        vm.expectRevert(BridgeBase.ModuleNotConfigured.selector);
        _simulateReceive(payload);
    }

    function test_revert_bridge_receiveFromUnauthorizedSender() public {
        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        vm.expectRevert(_getUnauthorizedSenderError());
        _simulateReceiveUnauthorized(payload);
    }

    function test_revert_bridge_receiveEmptyMessage() public {
        vm.expectRevert(stdError.indexOOBError);
        _simulateReceive("");
    }

    function test_revert_bridge_receiveTypeByteOnly() public {
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)));

        // abi.decode reverts with no selector on empty data
        vm.expectRevert();
        _simulateReceive(payload);
    }

    /*--------------------------------------------------------------
                      PAUSE SEND TESTS
    --------------------------------------------------------------*/

    function test_bridge_pauseSend() public {
        bridge.pauseSend();
        assertTrue(bridge.sendPaused());
    }

    function test_bridge_unpauseSend() public {
        bridge.pauseSend();
        bridge.unpauseSend();
        assertFalse(bridge.sendPaused());
    }

    function test_bridge_pauseSend_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(bridge));
        emit BridgeBase.SendPauseSet(true);
        bridge.pauseSend();
    }

    function test_bridge_unpauseSend_emitsEvent() public {
        bridge.pauseSend();

        vm.expectEmit(false, false, false, true, address(bridge));
        emit BridgeBase.SendPauseSet(false);
        bridge.unpauseSend();
    }

    function test_revert_bridge_pauseSend_nonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.pauseSend();
    }

    function test_revert_bridge_unpauseSend_nonOwner() public {
        bridge.pauseSend();

        vm.prank(user);
        vm.expectRevert();
        bridge.unpauseSend();
    }

    function test_revert_bridge_bridgeCollateral_whenSendPaused() public {
        collateralToken.mint(user, 1000 ether);

        vm.prank(user);
        collateralToken.transfer(address(bridge), 500 ether);

        bridge.pauseSend();

        vm.prank(user);
        vm.expectRevert(BridgeBase.SendIsPaused.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, _toBytes32(recipient), "");
    }

    function test_revert_bridge_bridgePositions_whenSendPaused() public {
        BridgedPosition[] memory positions = new BridgedPosition[](1);
        positions[0] = BridgedPosition({ positionId: PositionId.wrap(testPositionId0), amount: 1000 ether });

        bytes memory innerData = abi.encode(user, positions);
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.POSITIONS)), innerData);
        _simulateReceive(payload);

        PositionId[] memory positionIds = new PositionId[](1);
        positionIds[0] = PositionId.wrap(testPositionId0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 ether;

        vm.prank(user);
        positionManager.unsafeBatchTransferFrom(user, address(bridge), positionIds, amounts);

        bridge.pauseSend();

        vm.prank(user);
        vm.expectRevert(BridgeBase.SendIsPaused.selector);
        bridge.bridgePositions{ value: 0.01 ether }(REMOTE_DST, positionIds, amounts, _toBytes32(recipient), "");
    }

    function test_revert_bridge_bridgeResult_whenSendPaused() public {
        vm.chainId(HUB_CHAIN_ID);

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;
        binaryModule.reportResult(ConditionIdLib.from(testConditionId), result);

        bridge.pauseSend();

        vm.expectRevert(BridgeBase.SendIsPaused.selector);
        bridge.bridgeResult{ value: 0.01 ether }(REMOTE_DST, ConditionIdLib.from(testConditionId), "");
    }

    function test_bridge_receiveStillWorks_whenSendPaused() public {
        bridge.pauseSend();

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        _simulateReceive(payload);

        assertEq(collateralToken.balanceOf(recipient), 1000 ether);
    }

    /*--------------------------------------------------------------
                     PAUSE RECEIVE TESTS
    --------------------------------------------------------------*/

    function test_bridge_pauseReceive() public {
        bridge.pauseReceive();
        assertTrue(bridge.receivePaused());
    }

    function test_bridge_unpauseReceive() public {
        bridge.pauseReceive();
        bridge.unpauseReceive();
        assertFalse(bridge.receivePaused());
    }

    function test_bridge_pauseReceive_emitsEvent() public {
        vm.expectEmit(false, false, false, true, address(bridge));
        emit BridgeBase.ReceivePauseSet(true);
        bridge.pauseReceive();
    }

    function test_bridge_unpauseReceive_emitsEvent() public {
        bridge.pauseReceive();

        vm.expectEmit(false, false, false, true, address(bridge));
        emit BridgeBase.ReceivePauseSet(false);
        bridge.unpauseReceive();
    }

    function test_revert_bridge_pauseReceive_nonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.pauseReceive();
    }

    function test_revert_bridge_unpauseReceive_nonOwner() public {
        bridge.pauseReceive();

        vm.prank(user);
        vm.expectRevert();
        bridge.unpauseReceive();
    }

    function test_revert_bridge_receive_whenReceivePaused() public {
        bridge.pauseReceive();

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        vm.expectRevert(BridgeBase.ReceiveIsPaused.selector);
        _simulateReceive(payload);
    }

    function test_bridge_sendStillWorks_whenReceivePaused() public {
        collateralToken.mint(user, 1000 ether);

        vm.prank(user);
        collateralToken.transfer(address(bridge), 500 ether);

        bridge.pauseReceive();

        vm.prank(user);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, _toBytes32(recipient), "");

        assertEq(_getSentMessageCount(), 1);
    }

    /*--------------------------------------------------------------
                   PAUSE CHAIN SEND TESTS
    --------------------------------------------------------------*/

    function test_bridge_pauseChainSend() public {
        bridge.pauseChainSend(REMOTE_DST);
        assertTrue(bridge.chainSendPaused(REMOTE_DST));
    }

    function test_bridge_unpauseChainSend() public {
        bridge.pauseChainSend(REMOTE_DST);
        bridge.unpauseChainSend(REMOTE_DST);
        assertFalse(bridge.chainSendPaused(REMOTE_DST));
    }

    function test_bridge_pauseChainSend_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeBase.ChainSendPauseSet(REMOTE_DST, true);
        bridge.pauseChainSend(REMOTE_DST);
    }

    function test_bridge_unpauseChainSend_emitsEvent() public {
        bridge.pauseChainSend(REMOTE_DST);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeBase.ChainSendPauseSet(REMOTE_DST, false);
        bridge.unpauseChainSend(REMOTE_DST);
    }

    function test_revert_bridge_pauseChainSend_nonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.pauseChainSend(REMOTE_DST);
    }

    function test_revert_bridge_unpauseChainSend_nonOwner() public {
        bridge.pauseChainSend(REMOTE_DST);

        vm.prank(user);
        vm.expectRevert();
        bridge.unpauseChainSend(REMOTE_DST);
    }

    function test_revert_bridge_bridgeCollateral_whenChainSendPaused() public {
        collateralToken.mint(user, 1000 ether);

        vm.prank(user);
        collateralToken.transfer(address(bridge), 500 ether);

        bridge.pauseChainSend(REMOTE_DST);

        vm.prank(user);
        vm.expectRevert(BridgeBase.ChainSendIsPaused.selector);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, _toBytes32(recipient), "");
    }

    function test_bridge_sendToOtherChainStillWorks_whenChainSendPaused() public {
        collateralToken.mint(user, 1000 ether);

        vm.prank(user);
        collateralToken.transfer(address(bridge), 500 ether);

        // Pause a different lane; sends to REMOTE_DST are unaffected
        bridge.pauseChainSend(REMOTE_DST + 1);

        vm.prank(user);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, _toBytes32(recipient), "");

        assertEq(_getSentMessageCount(), 1);
    }

    function test_bridge_sendResumesAfterChainUnpause() public {
        collateralToken.mint(user, 1000 ether);

        vm.prank(user);
        collateralToken.transfer(address(bridge), 500 ether);

        bridge.pauseChainSend(REMOTE_DST);
        bridge.unpauseChainSend(REMOTE_DST);

        vm.prank(user);
        bridge.bridgeCollateral{ value: 0.01 ether }(REMOTE_DST, 500 ether, _toBytes32(recipient), "");

        assertEq(_getSentMessageCount(), 1);
    }

    /*--------------------------------------------------------------
                   PAUSE CHAIN RECEIVE TESTS
    --------------------------------------------------------------*/

    function test_bridge_pauseChainReceive() public {
        bridge.pauseChainReceive(REMOTE_DST);
        assertTrue(bridge.chainReceivePaused(REMOTE_DST));
    }

    function test_bridge_unpauseChainReceive() public {
        bridge.pauseChainReceive(REMOTE_DST);
        bridge.unpauseChainReceive(REMOTE_DST);
        assertFalse(bridge.chainReceivePaused(REMOTE_DST));
    }

    function test_bridge_pauseChainReceive_emitsEvent() public {
        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeBase.ChainReceivePauseSet(REMOTE_DST, true);
        bridge.pauseChainReceive(REMOTE_DST);
    }

    function test_bridge_unpauseChainReceive_emitsEvent() public {
        bridge.pauseChainReceive(REMOTE_DST);

        vm.expectEmit(true, false, false, true, address(bridge));
        emit BridgeBase.ChainReceivePauseSet(REMOTE_DST, false);
        bridge.unpauseChainReceive(REMOTE_DST);
    }

    function test_revert_bridge_pauseChainReceive_nonOwner() public {
        vm.prank(user);
        vm.expectRevert();
        bridge.pauseChainReceive(REMOTE_DST);
    }

    function test_revert_bridge_unpauseChainReceive_nonOwner() public {
        bridge.pauseChainReceive(REMOTE_DST);

        vm.prank(user);
        vm.expectRevert();
        bridge.unpauseChainReceive(REMOTE_DST);
    }

    function test_revert_bridge_receive_whenChainReceivePaused() public {
        bridge.pauseChainReceive(REMOTE_DST);

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        vm.expectRevert(BridgeBase.ChainReceiveIsPaused.selector);
        _simulateReceive(payload);
    }

    function test_bridge_receiveFromOtherChainStillWorks_whenChainReceivePaused() public {
        // Pause a different lane; receives from REMOTE_DST are unaffected
        bridge.pauseChainReceive(REMOTE_DST + 1);

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        _simulateReceive(payload);

        assertEq(collateralToken.balanceOf(recipient), 1000 ether);
    }

    function test_bridge_receiveResumesAfterChainUnpause() public {
        bridge.pauseChainReceive(REMOTE_DST);
        bridge.unpauseChainReceive(REMOTE_DST);

        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);

        _simulateReceive(payload);

        assertEq(collateralToken.balanceOf(recipient), 1000 ether);
    }

    /*--------------------------------------------------------------
                   PAUSE BOTH + RESUME TESTS
    --------------------------------------------------------------*/

    function test_bridge_pauseBoth() public {
        bridge.pauseSend();
        bridge.pauseReceive();
        assertTrue(bridge.sendPaused());
        assertTrue(bridge.receivePaused());
    }

    function test_bridge_resumeAfterUnpause() public {
        bridge.pauseSend();
        bridge.pauseReceive();
        bridge.unpauseSend();
        bridge.unpauseReceive();

        // Receive should work
        bytes memory innerData = abi.encode(recipient, uint256(1000 ether));
        bytes memory payload = bytes.concat(bytes1(uint8(MessageType.COLLATERAL)), innerData);
        _simulateReceive(payload);
        assertEq(collateralToken.balanceOf(recipient), 1000 ether);
    }

    /*--------------------------------------------------------------
                            HELPERS
    --------------------------------------------------------------*/

    function _toBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}

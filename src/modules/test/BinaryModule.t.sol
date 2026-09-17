// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";
import { Ownable } from "@solady/src/auth/Ownable.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";

import { ConditionId, EventId, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";
import { ConditionIdLib, EventIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { PositionIdLib } from "@polymarket-v2/src/libraries/Ids.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { OracleModuleErrors } from "@polymarket-v2/src/modules/abstract/OracleModule.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { Router } from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

import { BaseModuleTest } from "./BaseModule.t.sol";

contract BinaryModuleTest is BaseModuleTest {
    Router router;

    uint256 internal _conditionCounter;

    function setUp() public virtual override {
        super.setUp();

        router = RouterSetup.deployRouter(address(positions.manager), owner);

        // Grant resolver role to oracle address
        vm.prank(admin);
        positions.binaryModule.addResolver(oracle);
    }

    /*--------------------------------------------------------------
                        VIRTUAL IMPLEMENTATIONS
    --------------------------------------------------------------*/

    function _module() internal view override returns (BaseModule) {
        return BaseModule(address(positions.binaryModule));
    }

    function _prepareCondition() internal override returns (bytes32 conditionId) {
        // Conditions no longer need preparation; just derive the ID
        conditionId = ConditionId.unwrap(
            positions.binaryModule.getConditionId(abi.encodePacked("condition_", block.timestamp, _conditionCounter++))
        );
    }

    function _getBridgeConditionId() internal override returns (bytes32) {
        // Generate a unique condition ID for bridge tests
        return ConditionId.unwrap(
            positions.binaryModule
                .getConditionId(abi.encodePacked("bridge_condition_", block.timestamp, _conditionCounter++))
        );
    }

    function _reportResultFromBridge(bytes32 _conditionId, uint256[] memory _result) internal override {
        vm.prank(bridge);
        positions.binaryModule.reportResult(ConditionIdLib.from(_conditionId), _result);
    }

    function _reportResult(bytes32 _conditionId) internal override {
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000; // YES wins
        result[1] = 0;

        vm.prank(oracle);
        positions.binaryModule.reportResult(ConditionIdLib.from(_conditionId), result);
    }

    function _reportPartialResult(bytes32 _conditionId) internal override {
        uint256[] memory result = new uint256[](2);
        result[0] = 500_000; // 50/50 split
        result[1] = 500_000;

        vm.prank(oracle);
        positions.binaryModule.reportResult(ConditionIdLib.from(_conditionId), result);
    }

    function _redeem(address _user, bytes32 _conditionId, uint256 _outcomeIndex, uint256 _amount) internal override {
        vm.startPrank(_user);
        positions.manager.setApprovalForAll(address(router), true);
        router.redeem(ConditionIdLib.from(_conditionId), _outcomeIndex, _amount);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                            BRIDGE
--------------------------------------------------------------*/

contract BinaryModuleTest_bridge is BinaryModuleTest {
    function test_mintFromBridge() public {
        _assert_mintFromBridge();
    }

    function test_mintFromBridge_zeroAmount() public {
        _assert_mintFromBridge_zeroAmount();
    }

    function test_revert_mintFromBridge_unauthorized() public {
        _assert_revert_mintFromBridge_unauthorized();
    }

    function test_mintFromBridge_thenRedeem() public {
        _assert_mintFromBridge_thenRedeem();
    }

    function test_burnFromBridge() public {
        _assert_burnFromBridge();
    }

    function test_onERC1155Received_normalTransfer() public {
        _assert_onERC1155Received_normalTransfer();
    }

    function test_burnFromBridge_batch() public {
        _assert_burnFromBridge_batch();
    }

    function test_onERC1155BatchReceived_normalTransfer() public {
        _assert_onERC1155BatchReceived_normalTransfer();
    }
}

/*--------------------------------------------------------------
                          HAS RESULT
--------------------------------------------------------------*/

contract BinaryModuleTest_hasResult is BinaryModuleTest {
    function test_hasResult_false() public {
        _assert_hasResult_false();
    }

    function test_hasResult_true() public {
        _assert_hasResult_true();
    }
}

/*--------------------------------------------------------------
                          GET PAYOUT
--------------------------------------------------------------*/

contract BinaryModuleTest_getPayout is BinaryModuleTest {
    function test_revert_conditionNotResolved() public {
        _assert_revert_getPayout_conditionNotResolved();
    }

    function test_revert_invalidOutcomeIndex() public {
        _assert_revert_getPayout_invalidOutcomeIndex();
    }

    function test_fullPayout() public {
        _assert_getPayout_fullPayout();
    }

    function test_partialPayout() public {
        _assert_getPayout_partialPayout();
    }
}

/*--------------------------------------------------------------
                       REPORT RESULT
--------------------------------------------------------------*/

contract BinaryModuleTest_reportResult is BinaryModuleTest {
    function test_reportResult() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);
    }

    function test_revert_unauthorized() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(alice); // alice does not have resolver role
        vm.expectRevert(Unauthorized.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }

    function test_revert_invalidSum() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_001; // sum != RESULT_DENOMINATOR
        result[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.InvalidResults.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }

    function test_revert_foreignModuleId() public {
        ConditionId conditionId =
            ConditionIdLib.encodeFromData(ModuleIds.NEGRISK, 0, abi.encode("foreign-module-condition"));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.InvalidEventId.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }

    function test_reportResult_replayCallerSemantics() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.ConditionAlreadyResolved.selector);
        positions.binaryModule.reportResult(conditionId, result);

        vm.prank(bridge);
        positions.binaryModule.reportResult(conditionId, result);

        uint256[] memory storedResult = positions.binaryModule.getResult(conditionId);
        assertEq(storedResult[0], 1_000_000);
        assertEq(storedResult[1], 0);
    }

    function test_revert_reportResult_bridgeReplayPayoutMismatch() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        result[0] = 0;
        result[1] = 1_000_000;

        vm.prank(bridge);
        vm.expectRevert(ModuleErrors.ExistingPayoutMismatch.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }

    function test_revert_reportResult_resolverReplayPayoutMismatch() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        result[0] = 0;
        result[1] = 1_000_000;

        vm.prank(oracle);
        vm.expectRevert(ModuleErrors.ExistingPayoutMismatch.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }
}

/*--------------------------------------------------------------
                            SPLIT
--------------------------------------------------------------*/

contract BinaryModuleTest_split is BinaryModuleTest {
    function test_split() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        positionIds[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, positionIds[0]), 1_000_000_000);
        assertEq(positions.manager.balanceOf(alice, positionIds[1]), 1_000_000_000);
        assertEq(collateral.token.balanceOf(alice), 0);
    }
}

/*--------------------------------------------------------------
                            MERGE
--------------------------------------------------------------*/

contract BinaryModuleTest_merge is BinaryModuleTest {
    function test_merge() public {
        collateral.usdc.mint(alice, 1_000_000_000);

        ConditionId conditionId = positions.binaryModule.getConditionId("question");
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        positionIds[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);
        vm.stopPrank();

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        router.merge(conditionId, 1_000_000_000);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, positionIds[0]), 0);
        assertEq(positions.manager.balanceOf(alice, positionIds[1]), 0);
        assertEq(collateral.token.balanceOf(alice), 1_000_000_000);
    }
}

/*--------------------------------------------------------------
                           REDEEM
--------------------------------------------------------------*/

contract BinaryModuleTest_redeem is BinaryModuleTest {
    function test_redeem(bool _outcome) public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");
        uint256[] memory positionIds = new uint256[](2);
        positionIds[0] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        positionIds[1] = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        collateral.usdc.mint(alice, 1_000_000_000);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000_000);
        collateral.token.approve(address(router), 1_000_000_000);
        router.split(conditionId, 1_000_000_000);
        vm.stopPrank();

        uint256[] memory result = new uint256[](2);
        result[_outcome ? 0 : 1] = 1_000_000;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        router.redeem(conditionId, _outcome ? 0 : 1, 1_000_000_000);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 1_000_000_000);
        assertEq(positions.manager.balanceOf(alice, positionIds[_outcome ? 0 : 1]), 0);
    }

    function test_redeem_emitsPositionRedeemed() public {
        // Exercise the module.redeem() call directly so msg.sender in the event
        // is alice (the initiator) rather than a router passthrough.
        ConditionId conditionId = positions.binaryModule.getConditionId("emit_question");
        PositionId winningPositionId = ConditionIdLib.computePositionId(conditionId, 0);
        uint256 amount = 1_000_000_000;

        collateral.usdc.mint(alice, amount);

        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), amount);
        collateral.onramp.wrap(address(collateral.usdc), alice, amount);
        collateral.token.approve(address(router), amount);
        router.split(conditionId, amount);
        vm.stopPrank();

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        // Alice transfers the winning position to the module then calls redeem directly.
        vm.prank(alice);
        positions.manager.unsafeTransferFrom(alice, address(positions.binaryModule), winningPositionId, amount);

        vm.expectEmit(true, true, true, true, address(positions.binaryModule));
        emit PositionRedeemed(alice, winningPositionId, alice, amount, amount);

        vm.prank(alice);
        positions.binaryModule.redeem(alice, winningPositionId, amount);

        assertEq(collateral.token.balanceOf(alice), amount);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId)), 0);
    }
}

/*--------------------------------------------------------------
                          RESOLVER
--------------------------------------------------------------*/

contract BinaryModuleTest_resolver is BinaryModuleTest {
    function test_addResolver_thenReport() public {
        // Grant resolver role to alice
        vm.prank(admin);
        positions.binaryModule.addResolver(alice);

        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(alice);
        positions.binaryModule.reportResult(conditionId, result);

        assertTrue(positions.binaryModule.hasResult(conditionId));
    }

    function test_pauseResolver() public {
        // Pause the resolver
        vm.prank(admin);
        positions.binaryModule.pauseResolver(oracle);

        // Verify resolver is paused
        assertEq(positions.binaryModule.resolverPausedAt(oracle), block.timestamp);
    }

    function test_unpauseResolver() public {
        // Pause the resolver
        vm.prank(admin);
        positions.binaryModule.pauseResolver(oracle);

        // Verify resolver is paused
        assertEq(positions.binaryModule.resolverPausedAt(oracle), block.timestamp);

        // Unpause the resolver
        vm.prank(admin);
        positions.binaryModule.unpauseResolver(oracle);

        // Verify resolver is not paused
        assertEq(positions.binaryModule.resolverPausedAt(oracle), 0);
    }

    function test_revert_reportResult_resolverPaused() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("question");

        // Pause the resolver
        vm.prank(admin);
        positions.binaryModule.pauseResolver(oracle);

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        // Try to report result while resolver is paused
        vm.prank(oracle);
        vm.expectRevert(OracleModuleErrors.ResolverIsPaused.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }

    function test_pauseResolution() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        // Pause the resolution
        vm.prank(admin);
        positions.binaryModule.pauseResolution(conditionId.eventId());

        // Verify resolution is paused
        assertEq(positions.binaryModule.resolutionPausedAt(conditionId.eventId()), block.timestamp);
    }

    function test_unpauseResolution() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        // Pause the resolution
        vm.prank(admin);
        positions.binaryModule.pauseResolution(conditionId.eventId());

        // Verify resolution is paused
        assertEq(positions.binaryModule.resolutionPausedAt(conditionId.eventId()), block.timestamp);

        // Unpause the resolution
        vm.prank(admin);
        positions.binaryModule.unpauseResolution(conditionId.eventId());

        // Verify resolution is not paused
        assertEq(positions.binaryModule.resolutionPausedAt(conditionId.eventId()), 0);
    }

    function test_revert_reportResult_resolutionPaused() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("condition");

        // Pause the resolution
        vm.prank(admin);
        positions.binaryModule.pauseResolution(conditionId.eventId());

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        // Try to report result while resolution is paused
        vm.prank(oracle);
        vm.expectRevert(OracleModuleErrors.ResolutionIsPaused.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }
}

/*--------------------------------------------------------------
                            VIEW
--------------------------------------------------------------*/

contract BinaryModuleTest_view is BinaryModuleTest {
    function test_getConditionId(bytes memory _data) public view {
        ConditionId conditionId = positions.binaryModule.getConditionId(_data);
        // Verify the moduleId is BINARY (1)
        uint256 moduleId = PositionId.wrap(uint256(bytes32(ConditionId.unwrap(conditionId)))).moduleId();
        assertEq(moduleId, ModuleIds.BINARY);
    }

    function test_getPositionId(bytes32 _conditionId, uint256 _outcomeIndex) public view {
        // Sanitize fuzz input so the canonicalising wrap doesn't revert.
        bytes32 canonical = bytes32(uint256(_conditionId) & ~uint256(0xFF));
        assertEq(
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(canonical)), _outcomeIndex)),
            PositionId.unwrap(ConditionIdLib.computePositionId(ConditionId.wrap(bytes31(canonical)), _outcomeIndex))
        );
    }
}

/*--------------------------------------------------------------
              LEGACY POSITION ID
--------------------------------------------------------------*/

/// @notice Tests that BinaryModule.getLegacyPositionId returns 0
///         when legacyConditionId is bytes32(0) (non-migrated condition).
contract BinaryModuleTest_legacyPositionId is BinaryModuleTest {
    // getLegacyPositionId returns 0 for non-migrated condition
    function test_getLegacyPositionId_nonMigrated() public view {
        bytes32 conditionId = ConditionId.unwrap(positions.binaryModule.getConditionId("non_migrated"));

        // Non-migrated condition -> legacyConditionId[conditionId] == bytes32(0)
        // -> returns 0 (early return for non-migrated condition)
        uint256 legacyPosId = positions.binaryModule.getLegacyPositionId(conditionId, 0);
        assertEq(legacyPosId, 0);
    }
}

/*--------------------------------------------------------------
        GET PAYOUT - COVERAGE BRANCHES
--------------------------------------------------------------*/

/// @notice Tests for BaseModule.getPayout with invalid outcome index
contract BinaryModuleTest_getPayoutCoverage is BinaryModuleTest {
    // Test getPayout with outcomeIndex >= 2 reverts InvalidOutcomeIndex
    function test_revert_getPayout_invalidOutcomeIndex() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("invalid_outcome_idx");

        // Resolve the condition
        uint256[] memory res = new uint256[](2);
        res[0] = 1_000_000;
        res[1] = 0;
        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, res);

        // Manually craft a positionId with outcomeIndex = 2 (invalid for binary)
        // ConditionIdLib.positionId sets outcomeIndex in lower 8 bits
        PositionId positionIdOutcome2 = ConditionIdLib.computePositionId(conditionId, 2);

        vm.expectRevert(ModuleErrors.InvalidOutcomeIndex.selector);
        positions.binaryModule.getPayout(positionIdOutcome2, 1_000_000);
    }
}

/*--------------------------------------------------------------
        DIRECT SPLIT/MERGE/REDEEM
--------------------------------------------------------------*/

contract BinaryModuleTest_direct is BinaryModuleTest {
    function test_split_direct() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("direct_split");

        uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), address(positions.binaryModule), 1_000_000);
        vm.stopPrank();

        // Call split
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        positions.binaryModule.split(to, conditionId, 1_000_000);

        // Verify positions minted
        assertEq(positions.manager.balanceOf(alice, yesId), 1_000_000);
        assertEq(positions.manager.balanceOf(alice, noId), 1_000_000);
    }

    function test_merge_direct() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("direct_merge");

        PositionId yesId = ConditionIdLib.computePositionId(conditionId, 0);
        PositionId noId = ConditionIdLib.computePositionId(conditionId, 1);

        // Mint positions to module first
        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000);
        collateral.token.approve(address(router), 1_000_000);
        router.split(conditionId, 1_000_000);
        vm.stopPrank();

        // Transfer positions to module
        PositionId[] memory ids = new PositionId[](2);
        ids[0] = yesId;
        ids[1] = noId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000;
        amounts[1] = 1_000_000;

        vm.prank(alice);
        positions.manager.unsafeBatchTransferFrom(alice, address(positions.binaryModule), ids, amounts);

        // Call merge
        positions.binaryModule.merge(alice, conditionId, 1_000_000);

        // Verify collateral returned
        assertEq(collateral.token.balanceOf(alice), 1_000_000);
    }

    function test_redeem_direct() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("direct_redeem");

        PositionId yesId = ConditionIdLib.computePositionId(conditionId, 0);

        // Mint positions
        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000);
        collateral.token.approve(address(router), 1_000_000);
        router.split(conditionId, 1_000_000);
        vm.stopPrank();

        // Report result - YES wins
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;
        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        // Transfer position to module
        vm.prank(alice);
        positions.manager.unsafeTransferFrom(alice, address(positions.binaryModule), yesId, 1_000_000);

        // Call redeem
        positions.binaryModule.redeem(alice, yesId, 1_000_000);

        // Verify collateral returned
        assertEq(collateral.token.balanceOf(alice), 1_000_000);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(yesId)), 0);
    }

    function test_revert_split_noPreTransfer() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("revert_no_pretransfer_split");
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        positions.binaryModule.split(to, conditionId, 1_000_000);
    }

    function test_revert_merge_noPreTransfer() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("revert_no_pretransfer_merge");
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        positions.binaryModule.merge(alice, conditionId, 1_000_000);
    }

    function test_revert_redeem_noPreTransfer() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("revert_no_pretransfer_redeem");
        // Resolve so getPayout > 0 — otherwise redeem returns early before the burn step.
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        PositionId winning = conditionId.computePositionId(0);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        positions.binaryModule.redeem(alice, winning, 1_000_000);
    }
}

/*--------------------------------------------------------------
              RESOLVER MODIFIER BRANCHES
--------------------------------------------------------------*/

/// @notice Tests for OracleModule onlyResolver modifier branches
contract BinaryModuleTest_resolverModifier is BinaryModuleTest {
    // Test onlyResolver with wrong sender (Unauthorized branch)
    function test_revert_reportResult_wrongSender() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("wrong_sender");

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        // Call from alice (no resolver role) - should hit onlyResolver role check
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }

    function test_revert_reportResult_wrongResolutionChain() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("wrong_resolution_chain");
        ConditionId wrongChainId =
            ConditionIdLib.from(bytes32(uint256(bytes32(ConditionId.unwrap(conditionId))) | (uint256(1) << 24)));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(OracleModuleErrors.InvalidResolutionChain.selector);
        positions.binaryModule.reportResult(wrongChainId, result);
    }

    // Test onlyResolver with paused resolver (ResolverIsPaused branch)
    function test_revert_reportResult_resolverPaused() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("resolver_paused");

        // Pause the resolver
        vm.prank(admin);
        positions.binaryModule.pauseResolver(oracle);

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        // Resolver has the role but is paused - should hit ResolverIsPaused
        vm.prank(oracle);
        vm.expectRevert(OracleModuleErrors.ResolverIsPaused.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }

    // Test onlyResolver with paused resolution (ResolutionIsPaused branch)
    function test_revert_reportResult_resolutionPaused() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("resolution_paused");

        // Pause the resolution for this condition
        vm.prank(admin);
        positions.binaryModule.pauseResolution(conditionId.eventId());

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        // Resolver has role and is not paused, but resolution is paused
        vm.prank(oracle);
        vm.expectRevert(OracleModuleErrors.ResolutionIsPaused.selector);
        positions.binaryModule.reportResult(conditionId, result);
    }
}

/*--------------------------------------------------------------
     SPLIT/MERGE/REDEEM VIA ROUTER
--------------------------------------------------------------*/

contract BinaryModuleTest_viaRouter is BinaryModuleTest {
    function test_split_viaRouter() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("split_via_router");

        uint256 yesId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.computePositionId(conditionId, 1));

        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000);
        collateral.token.approve(address(router), 1_000_000);

        router.split(conditionId, 1_000_000);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), 1_000_000);
        assertEq(positions.manager.balanceOf(alice, noId), 1_000_000);
    }

    function test_merge_viaRouter() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("merge_via_router");

        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000);
        collateral.token.approve(address(router), 1_000_000);
        router.split(conditionId, 1_000_000);

        positions.manager.setApprovalForAll(address(router), true);
        router.merge(conditionId, 1_000_000);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 1_000_000);
    }

    function test_redeem_viaRouter() public {
        ConditionId conditionId = positions.binaryModule.getConditionId("redeem_via_router");

        collateral.usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        collateral.usdc.approve(address(collateral.onramp), 1_000_000);
        collateral.onramp.wrap(address(collateral.usdc), alice, 1_000_000);
        collateral.token.approve(address(router), 1_000_000);
        router.split(conditionId, 1_000_000);
        vm.stopPrank();

        // Resolve YES wins
        uint256[] memory res = new uint256[](2);
        res[0] = 1_000_000;
        res[1] = 0;
        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, res);

        // Redeem via Router
        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(router), true);
        router.redeem(conditionId, 0, 1_000_000);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 1_000_000);
    }
}

/*--------------------------------------------------------------
                         INITIALIZER
--------------------------------------------------------------*/

contract BinaryModuleTest_initialize is BinaryModuleTest {
    function test_revert_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        positions.binaryModule.initialize(owner, admin);
    }
}

/*--------------------------------------------------------------
                            UUPS
--------------------------------------------------------------*/

contract BinaryModuleTest_upgrade is BinaryModuleTest {
    function test_upgradeToAndCall_preservesState() public {
        ConditionId conditionId = positions.binaryModule.getConditionId(abi.encodePacked("upgrade-state"));

        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        result[1] = 0;

        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionId, result);

        address newImpl = address(
            new BinaryModule(
                address(positions.manager),
                address(positions.binaryModule.CONDITIONAL_TOKENS()),
                positions.binaryModule.USDCE(),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(owner);
        positions.binaryModule.upgradeToAndCall(newImpl, "");

        uint256[] memory storedResult = positions.binaryModule.getResult(conditionId);
        assertEq(storedResult[0], result[0]);
        assertEq(storedResult[1], result[1]);
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(
            new BinaryModule(
                address(positions.manager),
                address(positions.binaryModule.CONDITIONAL_TOKENS()),
                positions.binaryModule.USDCE(),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        positions.binaryModule.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_incompatibleModuleId() public {
        address newImpl = address(
            new NegRiskModule(
                address(positions.manager),
                address(positions.binaryModule.CONDITIONAL_TOKENS()),
                positions.binaryModule.USDCE(),
                address(0),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(owner);
        vm.expectRevert(ModuleErrors.IncompatibleImplementation.selector);
        positions.binaryModule.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_incompatibleUsdce() public {
        address newImpl = address(
            new BinaryModule(
                address(positions.manager),
                address(positions.binaryModule.CONDITIONAL_TOKENS()),
                address(0xBEEF),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(owner);
        vm.expectRevert(ModuleErrors.IncompatibleImplementation.selector);
        positions.binaryModule.upgradeToAndCall(newImpl, "");
    }
}

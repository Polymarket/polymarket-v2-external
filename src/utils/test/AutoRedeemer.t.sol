// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { CTFHelpers } from "@polymarket-v2/src/legacy/libraries/CTFHelpers.sol";
import { CTHelpers } from "@polymarket-v2/src/legacy/libraries/CTHelpers.sol";
import { ConditionId, EventId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { ModuleProxyLib } from "@polymarket-v2/src/modules/dev/ModuleProxyLib.sol";
import {
    Legacy,
    Positions,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { Router } from "@polymarket-v2/src/routers/Router.sol";
import { AutoRedeemer, AutoRedeemerErrors, AutoRedeemerEvents } from "@polymarket-v2/src/utils/AutoRedeemer.sol";

contract AutoRedeemerTest is TestHelper {
    error Unauthorized();

    uint256 internal constant ADMIN_ROLE = 1 << 0;
    uint256 internal constant OPERATOR_ROLE = 1 << 1;
    uint256 internal constant AMOUNT = 1_000_000_000;
    uint256 internal constant SMALL_AMOUNT = 500_000_000;
    uint256 internal constant RESULT_DENOMINATOR = 1_000_000;

    AutoRedeemer internal autoRedeemer;
    CombinatorialModule internal combinatorial;
    Router internal router;
    Collateral internal collateral;
    Positions internal positions;
    Legacy internal legacy;
    uint256 internal legacyNegRiskNonce;

    function setUp() public virtual {
        (positions, collateral, legacy) = PositionManagerSetup._deploy(owner, admin, creator);

        address implementation = address(
            new AutoRedeemer(
                address(positions.manager),
                address(collateral.onramp),
                address(legacy.conditionalTokens),
                address(legacy.negRiskAdapter)
            )
        );
        address proxy = LibClone.deployERC1967(implementation);
        autoRedeemer = AutoRedeemer(proxy);
        autoRedeemer.initialize(owner, admin);

        combinatorial = ModuleProxyLib.deployCombinatorialModule(address(positions.manager), owner, admin);
        router = new Router(address(positions.manager));

        vm.prank(owner);
        collateral.token.addMinter(address(combinatorial));

        vm.startPrank(admin);
        positions.manager.addModule(address(combinatorial));
        autoRedeemer.addOperator(operator);
        positions.binaryModule.addResolver(oracle);
        positions.negRiskModule.addResolver(oracle);
        vm.stopPrank();
    }

    function _toAddressArray(address _a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = _a;
    }

    function _toBytes32Array(bytes32 _a) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = _a;
    }

    function _toPositionIdArray(PositionId _a) internal pure returns (PositionId[] memory arr) {
        arr = new PositionId[](1);
        arr[0] = _a;
    }

    function _toAddressArray(address _a, address _b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = _a;
        arr[1] = _b;
    }

    function _sorted2(PositionId _a, PositionId _b) internal pure returns (PositionId[] memory conditions) {
        conditions = new PositionId[](2);
        if (PositionId.unwrap(_a) < PositionId.unwrap(_b)) {
            conditions[0] = _a;
            conditions[1] = _b;
        } else {
            conditions[0] = _b;
            conditions[1] = _a;
        }
    }

    function _mintAndWrap(address _user, uint256 _amount) internal {
        collateral.usdc.mint(_user, _amount);

        vm.startPrank(_user);
        collateral.usdc.approve(address(collateral.onramp), _amount);
        collateral.onramp.wrap(address(collateral.usdc), _user, _amount);
        collateral.token.approve(address(router), _amount);
        vm.stopPrank();
    }

    function _prepareBinaryCondition(bytes memory _data) internal view returns (ConditionId conditionId) {
        conditionId = positions.binaryModule.getConditionId(_data);
    }

    function _splitBinary(address _user, ConditionId _conditionId, uint256 _amount) internal {
        _mintAndWrap(_user, _amount);

        vm.prank(_user);
        router.split(_conditionId, _amount);
    }

    function _resolveBinary(ConditionId _conditionId, bool _yesWins) internal {
        uint256[] memory result = new uint256[](2);
        result[_yesWins ? 0 : 1] = RESULT_DENOMINATOR;

        vm.prank(oracle);
        positions.binaryModule.reportResult(_conditionId, result);
    }

    function _prepareNegRiskCondition(bytes memory _data, uint256 _conditionIndex)
        internal
        returns (ConditionId conditionId)
    {
        vm.prank(creator);
        EventId eventId = positions.negRiskModule.getEventId(2, _data);
        conditionId = eventId.computeConditionId(_conditionIndex);
    }

    function _splitNegRisk(address _user, ConditionId _conditionId, uint256 _amount) internal {
        _mintAndWrap(_user, _amount);

        vm.prank(_user);
        router.split(_conditionId, _amount);
    }

    function _resolveNegRisk(ConditionId _conditionId, bool _yesWins) internal {
        uint256[] memory result = new uint256[](2);
        result[_yesWins ? 0 : 1] = RESULT_DENOMINATOR;

        vm.prank(oracle);
        positions.negRiskModule.reportResult(_conditionId, result);
    }

    function _prepareLegacyBinaryCondition(bytes32 _questionId) internal returns (bytes32 conditionId) {
        conditionId = CTHelpers.getConditionId(oracle, _questionId, 2);
        legacy.conditionalTokens.prepareCondition(oracle, _questionId, 2);
    }

    function _splitLegacyBinary(address _user, bytes32 _conditionId, uint256 _amount) internal {
        collateral.usdce.mint(_user, _amount);

        vm.startPrank(_user);
        collateral.usdce.approve(address(legacy.conditionalTokens), _amount);
        legacy.conditionalTokens
            .splitPosition(address(collateral.usdce), bytes32(0), _conditionId, CTFHelpers.partition(), _amount);
        vm.stopPrank();
    }

    function _resolveLegacyBinary(bytes32 _questionId, bool _yesWins) internal {
        uint256[] memory payouts = new uint256[](2);
        payouts[_yesWins ? 0 : 1] = 1;

        vm.prank(oracle);
        legacy.conditionalTokens.reportPayouts(_questionId, payouts);
    }

    function _prepareLegacyNegRiskCondition() internal returns (bytes32 questionId, bytes32 conditionId) {
        bytes memory data = abi.encode(legacyNegRiskNonce++);

        vm.prank(oracle);
        bytes32 marketId = legacy.negRiskAdapter.prepareMarket(0, data);

        vm.prank(oracle);
        questionId = legacy.negRiskAdapter.prepareQuestion(marketId, data);

        conditionId = legacy.negRiskAdapter.getConditionId(questionId);
    }

    function _splitLegacyNegRisk(address _user, bytes32 _conditionId, uint256 _amount) internal {
        collateral.usdce.mint(_user, _amount);

        vm.startPrank(_user);
        collateral.usdce.approve(address(legacy.negRiskAdapter), _amount);
        legacy.negRiskAdapter.splitPosition(_conditionId, _amount);
        vm.stopPrank();
    }

    function _resolveLegacyNegRisk(bytes32 _questionId, bool _yesWins) internal {
        vm.prank(oracle);
        legacy.negRiskAdapter.reportOutcome(_questionId, _yesWins);
    }

    function _splitCombinatorial(address _user, PositionId[] memory _conditions, uint256 _amount)
        internal
        returns (ConditionId conditionId)
    {
        conditionId = combinatorial.prepareCondition(_conditions);
        _mintAndWrap(_user, _amount);

        vm.startPrank(_user);
        collateral.token.transfer(address(combinatorial), _amount);
        combinatorial.split(_toAddressArray(_user, _user), conditionId, _amount);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                    DEPLOYMENT
--------------------------------------------------------------*/

contract AutoRedeemerTest_deployment is AutoRedeemerTest {
    function test_deployment() public view {
        assertEq(address(autoRedeemer.POSITION_MANAGER()), address(positions.manager));
        assertEq(address(autoRedeemer.COLLATERAL_TOKEN()), address(collateral.token));
        assertEq(address(autoRedeemer.COLLATERAL_ONRAMP()), address(collateral.onramp));
        assertEq(address(autoRedeemer.CONDITIONAL_TOKENS()), address(legacy.conditionalTokens));
        assertEq(address(autoRedeemer.NEG_RISK_ADAPTER()), address(legacy.negRiskAdapter));
        assertEq(autoRedeemer.USDCE(), address(collateral.usdce));
        assertEq(autoRedeemer.WRAPPED_COLLATERAL(), legacy.wrappedCollateral);
        assertEq(autoRedeemer.owner(), owner);
        assertTrue(autoRedeemer.hasAllRoles(admin, ADMIN_ROLE));
        assertTrue(autoRedeemer.hasAllRoles(operator, OPERATOR_ROLE));
        assertEq(collateral.usdce.allowance(address(autoRedeemer), address(collateral.onramp)), type(uint256).max);
        assertTrue(legacy.conditionalTokens.isApprovedForAll(address(autoRedeemer), address(legacy.negRiskAdapter)));
    }

    function test_revert_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        autoRedeemer.initialize(owner, admin);
    }

    function test_revert_implementationInitializerDisabled() public {
        AutoRedeemer implementation = new AutoRedeemer(
            address(positions.manager),
            address(collateral.onramp),
            address(legacy.conditionalTokens),
            address(legacy.negRiskAdapter)
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(owner, admin);
    }
}

/*--------------------------------------------------------------
                            UUPS
--------------------------------------------------------------*/

contract AutoRedeemerTest_upgrade is AutoRedeemerTest {
    function test_upgradeToAndCall_preservesState() public {
        address newImpl = address(
            new AutoRedeemer(
                address(positions.manager),
                address(collateral.onramp),
                address(legacy.conditionalTokens),
                address(legacy.negRiskAdapter)
            )
        );

        vm.prank(owner);
        autoRedeemer.upgradeToAndCall(newImpl, "");

        assertEq(autoRedeemer.owner(), owner);
        assertTrue(autoRedeemer.hasAllRoles(admin, ADMIN_ROLE));
        assertTrue(autoRedeemer.hasAllRoles(operator, OPERATOR_ROLE));
        assertEq(address(autoRedeemer.POSITION_MANAGER()), address(positions.manager));
        assertEq(address(autoRedeemer.COLLATERAL_TOKEN()), address(collateral.token));
        assertEq(address(autoRedeemer.COLLATERAL_ONRAMP()), address(collateral.onramp));
        assertEq(address(autoRedeemer.CONDITIONAL_TOKENS()), address(legacy.conditionalTokens));
        assertEq(address(autoRedeemer.NEG_RISK_ADAPTER()), address(legacy.negRiskAdapter));
    }

    function test_revert_upgradeUnauthorized() public {
        address newImpl = address(
            new AutoRedeemer(
                address(positions.manager),
                address(collateral.onramp),
                address(legacy.conditionalTokens),
                address(legacy.negRiskAdapter)
            )
        );

        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        autoRedeemer.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
                        REDEEM
--------------------------------------------------------------*/

contract AutoRedeemerTest_redeem is AutoRedeemerTest {
    function test_redeemBinary() public {
        ConditionId conditionId = _prepareBinaryCondition("binary");
        PositionId winningPositionId = conditionId.computePositionId(0);
        _splitBinary(alice, conditionId, AMOUNT);
        _resolveBinary(conditionId, true);

        vm.prank(alice);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        vm.prank(operator);
        autoRedeemer.redeem(_toAddressArray(alice), _toPositionIdArray(winningPositionId));

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId)), 0);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(conditionId.computePositionId(1))), AMOUNT);
    }

    function test_redeemNegRisk() public {
        ConditionId conditionId = _prepareNegRiskCondition("neg-risk", 0);
        PositionId winningPositionId = conditionId.computePositionId(0);
        _splitNegRisk(alice, conditionId, AMOUNT);
        _resolveNegRisk(conditionId, true);

        vm.prank(alice);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        vm.prank(operator);
        autoRedeemer.redeem(_toAddressArray(alice), _toPositionIdArray(winningPositionId));

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId)), 0);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(conditionId.computePositionId(1))), AMOUNT);
    }

    function test_redeemCombinatorial() public {
        ConditionId conditionIdA = _prepareBinaryCondition("binary-a");
        ConditionId conditionIdB = _prepareBinaryCondition("binary-b");
        PositionId[] memory conditions = _sorted2(conditionIdA.computePositionId(0), conditionIdB.computePositionId(0));
        ConditionId combinatorialConditionId = _splitCombinatorial(alice, conditions, AMOUNT);
        PositionId winningPositionId = combinatorialConditionId.computePositionId(0);

        _resolveBinary(conditionIdA, true);
        _resolveBinary(conditionIdB, true);

        vm.prank(alice);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        vm.prank(operator);
        autoRedeemer.redeem(_toAddressArray(alice), _toPositionIdArray(winningPositionId));

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId)), 0);
        assertEq(
            positions.manager.balanceOf(alice, PositionId.unwrap(combinatorialConditionId.computePositionId(1))), AMOUNT
        );
    }

    function test_redeemLegacyBinary() public {
        bytes32 questionId = "legacy-binary";
        bytes32 conditionId = _prepareLegacyBinaryCondition(questionId);
        uint256[] memory legacyPositionIds = CTFHelpers.positionIds(address(collateral.usdce), conditionId);

        _splitLegacyBinary(alice, conditionId, AMOUNT);
        _resolveLegacyBinary(questionId, true);

        vm.prank(alice);
        legacy.conditionalTokens.setApprovalForAll(address(autoRedeemer), true);

        vm.prank(operator);
        autoRedeemer.redeemBinary(_toAddressArray(alice), _toBytes32Array(conditionId));

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(collateral.usdce.balanceOf(alice), 0);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds[0]), 0);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds[1]), 0);
        assertEq(collateral.usdce.balanceOf(address(autoRedeemer)), 0);
    }

    function test_redeemLegacyNegRisk() public {
        (bytes32 questionId, bytes32 conditionId) = _prepareLegacyNegRiskCondition();
        uint256[] memory legacyPositionIds = CTFHelpers.positionIds(legacy.wrappedCollateral, conditionId);

        _splitLegacyNegRisk(alice, conditionId, AMOUNT);
        _resolveLegacyNegRisk(questionId, true);

        vm.prank(alice);
        legacy.conditionalTokens.setApprovalForAll(address(autoRedeemer), true);

        vm.prank(operator);
        autoRedeemer.redeemNegRisk(_toAddressArray(alice), _toBytes32Array(conditionId));

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(collateral.usdce.balanceOf(alice), 0);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds[0]), 0);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds[1]), 0);
        assertEq(collateral.usdce.balanceOf(address(autoRedeemer)), 0);
    }

    function test_redeemBatch() public {
        ConditionId conditionId1 = _prepareBinaryCondition("binary-1");
        ConditionId conditionId2 = _prepareBinaryCondition("binary-2");
        PositionId winningPositionId1 = conditionId1.computePositionId(0);
        PositionId winningPositionId2 = conditionId2.computePositionId(1);

        _splitBinary(alice, conditionId1, AMOUNT);
        _splitBinary(brian, conditionId2, SMALL_AMOUNT);

        _resolveBinary(conditionId1, true);
        _resolveBinary(conditionId2, false);

        vm.prank(alice);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);
        vm.prank(brian);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = brian;

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = winningPositionId1;
        positionIds[1] = winningPositionId2;

        vm.prank(operator);
        autoRedeemer.redeem(froms, positionIds);

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(collateral.token.balanceOf(brian), SMALL_AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId1)), 0);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(conditionId1.computePositionId(1))), AMOUNT);
        assertEq(positions.manager.balanceOf(brian, PositionId.unwrap(conditionId2.computePositionId(0))), SMALL_AMOUNT);
        assertEq(positions.manager.balanceOf(brian, PositionId.unwrap(winningPositionId2)), 0);
    }

    function test_redeemBatchManyUsers() public {
        uint256 userCount = 12;
        ConditionId conditionId = _prepareBinaryCondition("binary-many-users");
        PositionId winningPositionId = conditionId.computePositionId(0);

        address[] memory froms = new address[](userCount);
        PositionId[] memory positionIds = new PositionId[](userCount);

        for (uint256 i; i < userCount; ++i) {
            address user = address(uint160(0x1000 + i));
            froms[i] = user;
            positionIds[i] = winningPositionId;

            _splitBinary(user, conditionId, SMALL_AMOUNT);

            vm.prank(user);
            positions.manager.setApprovalForAll(address(autoRedeemer), true);
        }

        _resolveBinary(conditionId, true);

        vm.prank(operator);
        autoRedeemer.redeem(froms, positionIds);

        for (uint256 i; i < userCount; ++i) {
            assertEq(collateral.token.balanceOf(froms[i]), SMALL_AMOUNT);
            assertEq(positions.manager.balanceOf(froms[i], PositionId.unwrap(winningPositionId)), 0);
        }
    }

    function test_redeemSkipsUnapproved() public {
        ConditionId conditionId1 = _prepareBinaryCondition("binary-1");
        ConditionId conditionId2 = _prepareBinaryCondition("binary-2");
        PositionId winningPositionId1 = conditionId1.computePositionId(0);
        PositionId winningPositionId2 = conditionId2.computePositionId(0);

        _splitBinary(alice, conditionId1, AMOUNT);
        _splitBinary(brian, conditionId2, SMALL_AMOUNT);

        _resolveBinary(conditionId1, true);
        _resolveBinary(conditionId2, true);

        vm.prank(brian);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = brian;

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = winningPositionId1;
        positionIds[1] = winningPositionId2;

        vm.prank(operator);
        autoRedeemer.redeem(froms, positionIds);

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(collateral.token.balanceOf(brian), SMALL_AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId1)), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(conditionId1.computePositionId(1))), AMOUNT);
        assertEq(positions.manager.balanceOf(brian, PositionId.unwrap(winningPositionId2)), 0);
        assertEq(positions.manager.balanceOf(brian, PositionId.unwrap(conditionId2.computePositionId(1))), SMALL_AMOUNT);
    }

    function test_redeemSkipsUnapprovedInMiddle() public {
        // Three approved/unapproved/approved users in one batch. Exercises the cached
        // `collateralBalance` baseline across an iteration that is skipped: alice redeems
        // first, brian is skipped (no approval), carly redeems after the skip.
        ConditionId conditionId1 = _prepareBinaryCondition("middle-binary-1");
        ConditionId conditionId2 = _prepareBinaryCondition("middle-binary-2");
        ConditionId conditionId3 = _prepareBinaryCondition("middle-binary-3");
        PositionId winningPositionId1 = conditionId1.computePositionId(0);
        PositionId winningPositionId2 = conditionId2.computePositionId(0);
        PositionId winningPositionId3 = conditionId3.computePositionId(0);

        _splitBinary(alice, conditionId1, AMOUNT);
        _splitBinary(brian, conditionId2, SMALL_AMOUNT);
        _splitBinary(carly, conditionId3, AMOUNT);

        _resolveBinary(conditionId1, true);
        _resolveBinary(conditionId2, true);
        _resolveBinary(conditionId3, true);

        vm.prank(alice);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);
        // brian intentionally does NOT approve
        vm.prank(carly);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        address[] memory froms = new address[](3);
        froms[0] = alice;
        froms[1] = brian;
        froms[2] = carly;

        PositionId[] memory positionIds = new PositionId[](3);
        positionIds[0] = winningPositionId1;
        positionIds[1] = winningPositionId2;
        positionIds[2] = winningPositionId3;

        // alice and carly emit Redemption; brian does not (silent skip).
        vm.expectEmit(true, false, false, true, address(autoRedeemer));
        emit AutoRedeemerEvents.Redemption(alice, winningPositionId1, AMOUNT);
        vm.expectEmit(true, false, false, true, address(autoRedeemer));
        emit AutoRedeemerEvents.Redemption(carly, winningPositionId3, AMOUNT);

        vm.prank(operator);
        autoRedeemer.redeem(froms, positionIds);

        // Both approved users got paid the full payout.
        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(collateral.token.balanceOf(carly), AMOUNT);
        // brian's positions are untouched.
        assertEq(collateral.token.balanceOf(brian), 0);
        assertEq(positions.manager.balanceOf(brian, PositionId.unwrap(winningPositionId2)), SMALL_AMOUNT);
        assertEq(positions.manager.balanceOf(brian, PositionId.unwrap(conditionId2.computePositionId(1))), SMALL_AMOUNT);
        // alice's and carly's winning positions are burned.
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId1)), 0);
        assertEq(positions.manager.balanceOf(carly, PositionId.unwrap(winningPositionId3)), 0);
        // Redeemer holds no residual collateral.
        assertEq(collateral.token.balanceOf(address(autoRedeemer)), 0);
    }

    function test_redeemSkipsUnapprovedFirst() public {
        ConditionId conditionId = _prepareBinaryCondition("skip-first");
        PositionId winningPositionId = conditionId.computePositionId(0);

        _splitBinary(alice, conditionId, AMOUNT);
        _splitBinary(brian, conditionId, SMALL_AMOUNT);
        _resolveBinary(conditionId, true);

        vm.prank(brian);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = brian;

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = winningPositionId;
        positionIds[1] = winningPositionId;

        vm.prank(operator);
        autoRedeemer.redeem(froms, positionIds);

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(collateral.token.balanceOf(brian), SMALL_AMOUNT);
        assertEq(collateral.token.balanceOf(address(autoRedeemer)), 0);
    }

    function test_redeemAllUnapproved() public {
        ConditionId conditionId = _prepareBinaryCondition("all-unapproved");
        PositionId winningPositionId = conditionId.computePositionId(0);

        _splitBinary(alice, conditionId, AMOUNT);
        _splitBinary(brian, conditionId, SMALL_AMOUNT);
        _resolveBinary(conditionId, true);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = brian;

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = winningPositionId;
        positionIds[1] = winningPositionId;

        vm.prank(operator);
        autoRedeemer.redeem(froms, positionIds);

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(collateral.token.balanceOf(brian), 0);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId)), AMOUNT);
        assertEq(positions.manager.balanceOf(brian, PositionId.unwrap(winningPositionId)), SMALL_AMOUNT);
        assertEq(collateral.token.balanceOf(address(autoRedeemer)), 0);
    }

    function test_redeemLegacyBinarySkipsUnapproved() public {
        bytes32 questionId1 = "legacy-binary-1";
        bytes32 questionId2 = "legacy-binary-2";
        bytes32 conditionId1 = _prepareLegacyBinaryCondition(questionId1);
        bytes32 conditionId2 = _prepareLegacyBinaryCondition(questionId2);
        uint256[] memory legacyPositionIds1 = CTFHelpers.positionIds(address(collateral.usdce), conditionId1);
        uint256[] memory legacyPositionIds2 = CTFHelpers.positionIds(address(collateral.usdce), conditionId2);

        _splitLegacyBinary(alice, conditionId1, AMOUNT);
        _splitLegacyBinary(brian, conditionId2, SMALL_AMOUNT);

        _resolveLegacyBinary(questionId1, true);
        _resolveLegacyBinary(questionId2, true);

        vm.prank(brian);
        legacy.conditionalTokens.setApprovalForAll(address(autoRedeemer), true);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = brian;

        bytes32[] memory conditionIds = new bytes32[](2);
        conditionIds[0] = conditionId1;
        conditionIds[1] = conditionId2;

        vm.prank(operator);
        autoRedeemer.redeemBinary(froms, conditionIds);

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(collateral.token.balanceOf(brian), SMALL_AMOUNT);
        assertEq(collateral.usdce.balanceOf(alice), 0);
        assertEq(collateral.usdce.balanceOf(brian), 0);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds1[0]), AMOUNT);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds1[1]), AMOUNT);
        assertEq(legacy.conditionalTokens.balanceOf(brian, legacyPositionIds2[0]), 0);
        assertEq(legacy.conditionalTokens.balanceOf(brian, legacyPositionIds2[1]), 0);
    }

    function test_redeemLegacyNegRiskSkipsUnapproved() public {
        (bytes32 questionId1, bytes32 conditionId1) = _prepareLegacyNegRiskCondition();
        (bytes32 questionId2, bytes32 conditionId2) = _prepareLegacyNegRiskCondition();
        uint256[] memory legacyPositionIds1 = CTFHelpers.positionIds(legacy.wrappedCollateral, conditionId1);
        uint256[] memory legacyPositionIds2 = CTFHelpers.positionIds(legacy.wrappedCollateral, conditionId2);

        _splitLegacyNegRisk(alice, conditionId1, AMOUNT);
        _splitLegacyNegRisk(brian, conditionId2, SMALL_AMOUNT);

        _resolveLegacyNegRisk(questionId1, true);
        _resolveLegacyNegRisk(questionId2, true);

        vm.prank(brian);
        legacy.conditionalTokens.setApprovalForAll(address(autoRedeemer), true);

        address[] memory froms = new address[](2);
        froms[0] = alice;
        froms[1] = brian;

        bytes32[] memory conditionIds = new bytes32[](2);
        conditionIds[0] = conditionId1;
        conditionIds[1] = conditionId2;

        vm.prank(operator);
        autoRedeemer.redeemNegRisk(froms, conditionIds);

        assertEq(collateral.token.balanceOf(alice), 0);
        assertEq(collateral.token.balanceOf(brian), SMALL_AMOUNT);
        assertEq(collateral.usdce.balanceOf(alice), 0);
        assertEq(collateral.usdce.balanceOf(brian), 0);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds1[0]), AMOUNT);
        assertEq(legacy.conditionalTokens.balanceOf(alice, legacyPositionIds1[1]), AMOUNT);
        assertEq(legacy.conditionalTokens.balanceOf(brian, legacyPositionIds2[0]), 0);
        assertEq(legacy.conditionalTokens.balanceOf(brian, legacyPositionIds2[1]), 0);
    }

    function test_redeemDoesNotForwardStrandedBalance() public {
        ConditionId conditionId = _prepareBinaryCondition("binary");
        PositionId winningPositionId = conditionId.computePositionId(0);
        uint256 strandedBalance = 123;
        _splitBinary(alice, conditionId, AMOUNT);
        _resolveBinary(conditionId, true);

        vm.prank(owner);
        collateral.token.addMinter(address(this));
        collateral.token.mint(address(autoRedeemer), strandedBalance);

        vm.prank(alice);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        vm.prank(operator);
        autoRedeemer.redeem(_toAddressArray(alice), _toPositionIdArray(winningPositionId));

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(collateral.token.balanceOf(address(autoRedeemer)), strandedBalance);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(winningPositionId)), 0);
    }

    function test_redeemLegacyBinaryDoesNotForwardStrandedBalance() public {
        bytes32 questionId = "legacy-binary";
        bytes32 conditionId = _prepareLegacyBinaryCondition(questionId);
        uint256 strandedBalance = 123;

        collateral.usdce.mint(address(autoRedeemer), strandedBalance);

        _splitLegacyBinary(alice, conditionId, AMOUNT);
        _resolveLegacyBinary(questionId, true);

        vm.prank(alice);
        legacy.conditionalTokens.setApprovalForAll(address(autoRedeemer), true);

        vm.prank(operator);
        autoRedeemer.redeemBinary(_toAddressArray(alice), _toBytes32Array(conditionId));

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(collateral.usdce.balanceOf(alice), 0);
        assertEq(collateral.usdce.balanceOf(address(autoRedeemer)), strandedBalance);
    }

    function test_revertUnauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Unauthorized.selector);
        autoRedeemer.redeem(new address[](0), new PositionId[](0));
    }

    function test_revertLengthMismatch() public {
        vm.prank(operator);
        vm.expectRevert(AutoRedeemerErrors.LengthMismatch.selector);
        autoRedeemer.redeem(new address[](1), new PositionId[](2));
    }

    function test_revertLegacyBinaryLengthMismatch() public {
        vm.prank(operator);
        vm.expectRevert(AutoRedeemerErrors.LengthMismatch.selector);
        autoRedeemer.redeemBinary(new address[](1), new bytes32[](2));
    }

    function test_revertLegacyNegRiskLengthMismatch() public {
        vm.prank(operator);
        vm.expectRevert(AutoRedeemerErrors.LengthMismatch.selector);
        autoRedeemer.redeemNegRisk(new address[](1), new bytes32[](2));
    }
}

/*--------------------------------------------------------------
                           EVENTS
--------------------------------------------------------------*/

contract AutoRedeemerTest_events is AutoRedeemerTest {
    function test_redeemEmitsPayout() public {
        ConditionId conditionId = _prepareBinaryCondition("binary");
        PositionId winningPositionId = conditionId.computePositionId(0);
        _splitBinary(alice, conditionId, AMOUNT);
        _resolveBinary(conditionId, true);

        vm.prank(alice);
        positions.manager.setApprovalForAll(address(autoRedeemer), true);

        vm.expectEmit(true, true, false, true);
        emit AutoRedeemerEvents.Redemption(alice, winningPositionId, AMOUNT);

        vm.prank(operator);
        autoRedeemer.redeem(_toAddressArray(alice), _toPositionIdArray(winningPositionId));
    }

    function test_redeemLegacyBinaryEmitsPayout() public {
        bytes32 questionId = "legacy-binary";
        bytes32 conditionId = _prepareLegacyBinaryCondition(questionId);
        _splitLegacyBinary(alice, conditionId, AMOUNT);
        _resolveLegacyBinary(questionId, true);

        vm.prank(alice);
        legacy.conditionalTokens.setApprovalForAll(address(autoRedeemer), true);

        vm.expectEmit(true, true, false, true);
        emit AutoRedeemerEvents.BinaryRedemption(alice, conditionId, AMOUNT);

        vm.prank(operator);
        autoRedeemer.redeemBinary(_toAddressArray(alice), _toBytes32Array(conditionId));
    }

    function test_redeemLegacyNegRiskEmitsPayout() public {
        (bytes32 questionId, bytes32 conditionId) = _prepareLegacyNegRiskCondition();
        _splitLegacyNegRisk(alice, conditionId, AMOUNT);
        _resolveLegacyNegRisk(questionId, true);

        vm.prank(alice);
        legacy.conditionalTokens.setApprovalForAll(address(autoRedeemer), true);

        vm.expectEmit(true, true, false, true);
        emit AutoRedeemerEvents.NegRiskRedemption(alice, conditionId, AMOUNT);

        vm.prank(operator);
        autoRedeemer.redeemNegRisk(_toAddressArray(alice), _toBytes32Array(conditionId));
    }
}

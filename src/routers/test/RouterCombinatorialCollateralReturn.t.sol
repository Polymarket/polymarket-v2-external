// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { ConditionId, EventId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import {
    CombinatorialModule,
    CombinatorialModuleErrors,
    CombinatorialModuleEvents
} from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { Positions, PositionManagerSetup } from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import {
    CombinatorialReturnTransfers,
    Router,
    RouterErrors,
    RouterEvents
} from "@polymarket-v2/src/routers/Router.sol";
import { RouterSetup } from "@polymarket-v2/src/routers/dev/RouterSetup.sol";

contract RouterCombinatorialCollateralReturnTest is TestHelper, RouterErrors, RouterEvents, CombinatorialModuleEvents {
    uint256 internal constant AMOUNT = 1_000e6;

    Positions internal positions;
    Collateral internal collateral;
    CombinatorialModule internal combinatorial;
    Router internal router;

    ConditionId internal conditionA;
    ConditionId internal conditionB;

    function setUp() public virtual {
        (positions, collateral,) = PositionManagerSetup._deploy(owner, admin, creator);
        router = RouterSetup.deployRouter(address(positions.manager), owner);

        address implementation =
            deployCode("CombinatorialModule.sol:CombinatorialModule", abi.encode(address(positions.manager)));
        combinatorial = CombinatorialModule(LibClone.deployERC1967(implementation));
        combinatorial.initialize(owner, admin);

        vm.prank(owner);
        collateral.token.addMinter(address(combinatorial));

        vm.startPrank(admin);
        positions.manager.addModule(address(combinatorial));
        positions.manager.setCrossModuleAuth(address(combinatorial), true);
        vm.stopPrank();

        conditionA = positions.binaryModule.getConditionId("A");
        conditionB = positions.binaryModule.getConditionId("B");
    }

    function _singleLegCondition(ConditionId _conditionId) internal returns (ConditionId) {
        PositionId[] memory legs = new PositionId[](1);
        legs[0] = _conditionId.computePositionId(0);
        return combinatorial.prepareCondition(legs);
    }

    function _twoLegCondition(PositionId _leg0, PositionId _leg1) internal returns (ConditionId) {
        return combinatorial.prepareCondition(_twoLegs(_leg0, _leg1));
    }

    function _twoLegs(PositionId _leg0, PositionId _leg1) internal pure returns (PositionId[] memory legs) {
        legs = new PositionId[](2);
        if (PositionId.unwrap(_leg0) < PositionId.unwrap(_leg1)) {
            legs[0] = _leg0;
            legs[1] = _leg1;
        } else {
            legs[0] = _leg1;
            legs[1] = _leg0;
        }
    }

    function _transfer(uint256 _collateralAmount, PositionId[] memory _positionIds)
        internal
        pure
        returns (CombinatorialReturnTransfers memory transfers)
    {
        uint256 length = _positionIds.length;
        uint256[] memory positionAmounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            positionAmounts[i] = AMOUNT;
        }

        transfers = CombinatorialReturnTransfers({
            collateralAmount: _collateralAmount, positionIds: _positionIds, positionAmounts: positionAmounts
        });
    }

    function _call(bytes4 _selector, bytes memory _arguments) internal pure returns (bytes memory) {
        return abi.encodePacked(_selector, _arguments);
    }

    function _splitCall(ConditionId _conditionId, address _recipient) internal pure returns (bytes memory) {
        address[] memory recipients = new address[](2);
        recipients[0] = _recipient;
        recipients[1] = _recipient;
        return _call(CombinatorialModule.split.selector, abi.encode(recipients, _conditionId, AMOUNT));
    }

    function _approveRouter() internal {
        collateral.token.approve(address(router), type(uint256).max);
        positions.manager.setApprovalForAll(address(router), true);
    }

    function _dealCollateral(uint256 _amount) internal {
        vm.prank(address(combinatorial));
        collateral.token.mint(alice, _amount);
    }

    function _recipients(address _recipient, uint256 _length) internal pure returns (address[] memory recipients) {
        recipients = new address[](_length);
        for (uint256 i; i < _length; ++i) {
            recipients[i] = _recipient;
        }
    }
}

contract RouterCombinatorialCollateralReturnTest_execution is RouterCombinatorialCollateralReturnTest {
    function test_splitAndMerge() public {
        ConditionId conditionId = _singleLegCondition(conditionA);

        bytes[] memory operations = new bytes[](2);
        operations[0] = _splitCall(conditionId, address(combinatorial));
        operations[1] = _call(CombinatorialModule.merge.selector, abi.encode(alice, conditionId, AMOUNT));

        _dealCollateral(AMOUNT);
        vm.startPrank(alice);
        _approveRouter();
        vm.expectEmit(true, false, false, true, address(router));
        emit CombinatorialCollateralReturned(alice, 2);
        router.combinatorialCollateralReturn(_transfer(AMOUNT, new PositionId[](0)), operations);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(conditionId.computePositionId(0))), 0);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(conditionId.computePositionId(1))), 0);
        assertEq(collateral.token.balanceOf(address(combinatorial)), 0);
    }

    function test_transfersAllWalletPositionsBeforeCalls() public {
        ConditionId conditionId = _singleLegCondition(conditionA);
        bytes[] memory splitOperations = new bytes[](1);
        splitOperations[0] = _splitCall(conditionId, alice);

        _dealCollateral(AMOUNT);
        vm.startPrank(alice);
        _approveRouter();
        router.combinatorialCollateralReturn(_transfer(AMOUNT, new PositionId[](0)), splitOperations);

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = conditionId.computePositionId(0);
        positionIds[1] = conditionId.computePositionId(1);
        bytes[] memory mergeOperations = new bytes[](1);
        mergeOperations[0] = _call(CombinatorialModule.merge.selector, abi.encode(alice, conditionId, AMOUNT));
        router.combinatorialCollateralReturn(_transfer(0, positionIds), mergeOperations);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(positionIds[0])), 0);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(positionIds[1])), 0);
    }

    function test_routesIntermediateAndTerminalByproducts() public {
        ConditionId parentConditionId = _singleLegCondition(conditionA);
        ConditionId fullConditionId = _twoLegCondition(conditionA.computePositionId(0), conditionB.computePositionId(0));

        _dealCollateral(AMOUNT * 2);
        vm.startPrank(alice);
        _approveRouter();
        router.split(parentConditionId, AMOUNT);
        router.split(fullConditionId, AMOUNT);

        PositionId parentYesPositionId = parentConditionId.computePositionId(0);
        PositionId fullNoPositionId = fullConditionId.computePositionId(1);
        PositionId[] memory fullLegs = combinatorial.getLegs(fullConditionId);
        uint256 conditionIndex =
            PositionId.unwrap(fullLegs[0]) == PositionId.unwrap(conditionA.computePositionId(0)) ? 1 : 0;

        PositionId[] memory positionIds = new PositionId[](2);
        positionIds[0] = parentYesPositionId;
        positionIds[1] = fullNoPositionId;

        address[] memory recipients = new address[](2);
        recipients[0] = address(combinatorial);
        recipients[1] = alice;
        bytes[] memory operations = new bytes[](2);
        operations[0] = _call(
            CombinatorialModule.extract.selector, abi.encode(recipients, fullNoPositionId, conditionIndex, AMOUNT)
        );
        operations[1] = _call(CombinatorialModule.merge.selector, abi.encode(alice, parentConditionId, AMOUNT));
        router.combinatorialCollateralReturn(_transfer(0, positionIds), operations);
        vm.stopPrank();

        PositionId residualYesPositionId = combinatorial.getConditionId(
                _twoLegs(conditionA.computePositionId(0), conditionB.computePositionId(1))
            ).computePositionId(0);
        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(residualYesPositionId)), AMOUNT);
        assertEq(positions.manager.balanceOf(address(combinatorial), PositionId.unwrap(residualYesPositionId)), 0);
    }
}

contract RouterCombinatorialCollateralReturnTest_validation is RouterCombinatorialCollateralReturnTest {
    function test_allowsAnyCombinatorialModuleSelector() public {
        PositionId[] memory legs = new PositionId[](1);
        legs[0] = conditionA.computePositionId(0);
        bytes[] memory operations = new bytes[](1);
        operations[0] = _call(CombinatorialModule.prepareCondition.selector, abi.encode(legs));

        router.combinatorialCollateralReturn(_transfer(0, new PositionId[](0)), operations);

        assertTrue(combinatorial.isConditionPrepared(combinatorial.getConditionId(legs)));
    }

    function test_revertsForMismatchedTransferInputs() public {
        CombinatorialReturnTransfers memory transfers = _transfer(0, new PositionId[](1));
        transfers.positionAmounts = new uint256[](0);

        vm.expectRevert(InvalidCombinatorialReturnOperation.selector);
        router.combinatorialCollateralReturn(transfers, new bytes[](1));
    }

    function test_revertsForEmptyOperations() public {
        _dealCollateral(AMOUNT);
        vm.startPrank(alice);
        _approveRouter();
        vm.expectRevert(InvalidCombinatorialReturnOperation.selector);
        router.combinatorialCollateralReturn(_transfer(AMOUNT, new PositionId[](0)), new bytes[](0));
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        assertEq(collateral.token.balanceOf(address(combinatorial)), 0);
    }

    function test_bubblesOperationRevert() public {
        bytes[] memory operations = new bytes[](1);
        operations[0] = _splitCall(conditionA, alice);

        vm.expectRevert(CombinatorialModuleErrors.InvalidConditionModule.selector);
        router.combinatorialCollateralReturn(_transfer(0, new PositionId[](0)), operations);
    }

    function test_revertsWhenCombinatorialModuleNotConfigured() public {
        vm.prank(admin);
        positions.manager.removeModule(ModuleIds.COMBINATORIAL);

        vm.expectRevert(CombinatorialModuleNotConfigured.selector);
        router.wrap(conditionA.computePositionId(0), AMOUNT);
    }
}

contract RouterCombinatorialOperationsTest is RouterCombinatorialCollateralReturnTest {
    function _splitCombinatorial(ConditionId _conditionId)
        internal
        returns (PositionId yesPositionId, PositionId noPositionId)
    {
        yesPositionId = _conditionId.computePositionId(0);
        noPositionId = _conditionId.computePositionId(1);
        _dealCollateral(AMOUNT);
        vm.startPrank(alice);
        _approveRouter();
        router.split(_conditionId, AMOUNT);
        vm.stopPrank();
    }

    function test_splitMergeOnCondition() public {
        ConditionId parentConditionId = _singleLegCondition(conditionA);
        (PositionId parentYesPositionId,) = _splitCombinatorial(parentConditionId);
        PositionId[] memory parentLegs = combinatorial.getLegs(parentConditionId);

        PositionId childYesPositionId =
            combinatorial.getConditionId(_twoLegs(parentLegs[0], conditionB.computePositionId(0))).computePositionId(0);
        PositionId childNoPositionId =
            combinatorial.getConditionId(_twoLegs(parentLegs[0], conditionB.computePositionId(1))).computePositionId(0);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true, address(combinatorial));
        emit SplitOnCondition(
            address(router),
            parentConditionId,
            childYesPositionId.conditionId(),
            childNoPositionId.conditionId(),
            alice,
            alice,
            AMOUNT
        );
        router.splitOnCondition(parentYesPositionId, conditionB, AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(childYesPositionId)), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(childNoPositionId)), AMOUNT);

        vm.expectEmit(true, true, false, true, address(combinatorial));
        emit MergedOnCondition(
            address(router),
            parentConditionId,
            childYesPositionId.conditionId(),
            childNoPositionId.conditionId(),
            alice,
            AMOUNT
        );
        router.mergeOnCondition(parentYesPositionId, conditionB, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(parentYesPositionId)), AMOUNT);
    }

    function test_extractInjectAndYesBasket() public {
        ConditionId fullConditionId = _twoLegCondition(conditionA.computePositionId(0), conditionB.computePositionId(0));
        (, PositionId fullNoPositionId) = _splitCombinatorial(fullConditionId);
        PositionId[] memory fullLegs = combinatorial.getLegs(fullConditionId);
        uint256 conditionIndex =
            PositionId.unwrap(fullLegs[0]) == PositionId.unwrap(conditionA.computePositionId(0)) ? 1 : 0;
        PositionId extractedLeg = fullLegs[conditionIndex];
        PositionId remainingLeg = fullLegs[conditionIndex == 0 ? 1 : 0];
        PositionId[] memory reducedLegs = new PositionId[](1);
        reducedLegs[0] = remainingLeg;
        ConditionId reducedConditionId = combinatorial.getConditionId(reducedLegs);
        ConditionId residualConditionId = combinatorial.getConditionId(
            _twoLegs(remainingLeg, extractedLeg.conditionId().computePositionId(extractedLeg.outcomeIndex() ^ 1))
        );
        address[] memory recipients = _recipients(alice, 2);

        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true, address(combinatorial));
        emit Extracted(address(router), fullConditionId, reducedConditionId, residualConditionId, alice, alice, AMOUNT);
        router.extract(fullNoPositionId, conditionIndex, AMOUNT);

        vm.expectEmit(true, true, false, true, address(combinatorial));
        emit Injected(address(router), fullConditionId, reducedConditionId, residualConditionId, alice, AMOUNT);
        router.inject(fullNoPositionId, conditionIndex, AMOUNT);

        vm.expectEmit(true, true, false, true, address(combinatorial));
        emit ConvertedToYesBasket(address(router), fullConditionId, recipients, AMOUNT);
        router.convertToYesBasket(fullNoPositionId, AMOUNT);

        vm.expectEmit(true, true, false, true, address(combinatorial));
        emit MergedFromYesBasket(address(router), fullConditionId, alice, AMOUNT);
        router.mergeFromYesBasket(fullNoPositionId, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(fullNoPositionId)), AMOUNT);
    }

    function test_splitMergeAndConvertOnEvent() public {
        EventId eventId = positions.negRiskModule.getEventId(3, "router-event");
        ConditionId parentConditionId = _singleLegCondition(conditionA);
        (PositionId parentYesPositionId,) = _splitCombinatorial(parentConditionId);
        address[] memory splitRecipients = _recipients(alice, 4);

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit SplitOnEvent(address(router), parentConditionId, eventId, splitRecipients, AMOUNT);
        router.splitOnEvent(parentYesPositionId, eventId, AMOUNT);

        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit MergedOnEvent(address(router), parentConditionId, eventId, alice, AMOUNT);
        router.mergeOnEvent(parentYesPositionId, eventId, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(parentYesPositionId)), AMOUNT);

        ConditionId convertConditionId =
            _twoLegCondition(conditionA.computePositionId(0), eventId.computeConditionId(0).computePositionId(1));
        (PositionId convertYesPositionId,) = _splitCombinatorial(convertConditionId);
        PositionId[] memory convertLegs = combinatorial.getLegs(convertConditionId);
        uint256 conditionIndex = PositionId.unwrap(convertLegs[0])
            == PositionId.unwrap(eventId.computeConditionId(0).computePositionId(1))
            ? 0
            : 1;

        address[] memory convertRecipients = _recipients(alice, 3);
        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit ConvertedOnEvent(address(router), convertConditionId, eventId, conditionIndex, convertRecipients, AMOUNT);
        vm.prank(alice);
        router.convertOnEvent(convertYesPositionId, conditionIndex, AMOUNT);

        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(convertYesPositionId)), 0);
    }

    function test_wrapAndUnwrap() public {
        _dealCollateral(AMOUNT);
        PositionId underlyingYesPositionId = conditionA.computePositionId(0);
        ConditionId wrappedConditionId = _singleLegCondition(conditionA);
        PositionId wrappedYesPositionId = wrappedConditionId.computePositionId(0);

        vm.startPrank(alice);
        _approveRouter();
        router.split(conditionA, AMOUNT);

        vm.expectEmit(true, false, false, true, address(combinatorial));
        emit Wrapped(address(router), underlyingYesPositionId, wrappedYesPositionId, alice, AMOUNT);
        router.wrap(underlyingYesPositionId, AMOUNT);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(combinatorial));
        emit Unwrapped(address(router), wrappedYesPositionId, underlyingYesPositionId, alice, AMOUNT);
        vm.prank(alice);
        router.unwrap(wrappedYesPositionId, AMOUNT);

        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(underlyingYesPositionId)), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, PositionId.unwrap(wrappedYesPositionId)), 0);
    }

    function test_compress() public {
        ConditionId conditionId = _singleLegCondition(conditionA);
        (PositionId yesPositionId,) = _splitCombinatorial(conditionId);

        vm.prank(admin);
        positions.binaryModule.addResolver(oracle);
        uint256[] memory result = new uint256[](2);
        result[0] = 1_000_000;
        vm.prank(oracle);
        positions.binaryModule.reportResult(conditionA, result);

        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit Compressed(address(router), yesPositionId, PositionId.wrap(0), alice, AMOUNT, 0, AMOUNT);
        vm.prank(alice);
        router.compress(yesPositionId, AMOUNT);

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }
}

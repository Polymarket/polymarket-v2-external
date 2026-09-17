// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Ownable } from "@solady/src/auth/Ownable.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { LibClone } from "@solady/src/utils/LibClone.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import {
    ConditionId,
    ConditionIdLib,
    EventId,
    EventIdLib,
    PositionId,
    ResolutionChain
} from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import {
    CombinatorialModule,
    CombinatorialModuleEvents,
    CombinatorialModuleErrors
} from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";
import {
    Positions,
    Legacy,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";

contract CombinatorialModuleTest is TestHelper, CombinatorialModuleEvents, CombinatorialModuleErrors {
    error Unauthorized();

    Positions positions;
    Collateral collateral;
    CombinatorialModule combinatorial;
    address bridge;

    // Binary conditions used as combinatorial conditions
    bytes32 condA;
    bytes32 condB;
    bytes32 condC;
    bytes32 condD;

    // Corresponding position IDs (YES = outcomeIndex 0, NO = outcomeIndex 1)
    uint256 conditionAY; // Y(A)
    uint256 conditionAN; // N(A)
    uint256 conditionBY; // Y(B)
    uint256 conditionBN; // N(B)
    uint256 conditionCY; // Y(C)
    uint256 conditionCN; // N(C)
    uint256 conditionDY; // Y(D)
    uint256 conditionDN; // N(D)

    uint256 constant AMOUNT = 1_000e6;
    uint256 constant RESULT_DENOMINATOR = 1_000_000;

    function _positionIds(uint256[] memory ids) internal pure returns (PositionId[] memory positionIds) {
        positionIds = new PositionId[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            positionIds[i] = PositionId.wrap(ids[i]);
        }
    }

    function _rawPositionIds(PositionId[] memory ids) internal pure returns (uint256[] memory positionIds) {
        positionIds = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            positionIds[i] = PositionId.unwrap(ids[i]);
        }
    }

    /// @dev External wrapper so `vm.expectRevert` observes `ConditionIdLib.from` reverts.
    function callConditionIdFrom(bytes32 conditionId) external pure returns (ConditionId) {
        return ConditionIdLib.from(conditionId);
    }

    function setUp() public virtual {
        Legacy memory legacy;
        (positions, collateral, legacy) = PositionManagerSetup._deploy(owner, admin, creator);

        address implementation = address(new CombinatorialModule(address(positions.manager)));
        address proxy = LibClone.deployERC1967(implementation);
        combinatorial = CombinatorialModule(proxy);
        combinatorial.initialize(owner, admin);

        vm.prank(owner);
        collateral.token.addMinter(address(combinatorial));

        bridge = vm.createWallet("bridge").addr;

        vm.startPrank(admin);
        positions.manager.addModule(address(combinatorial));
        positions.manager.setCrossModuleAuth(address(combinatorial), true);
        positions.binaryModule.addResolver(oracle);
        vm.stopPrank();

        condA = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("A")));
        condB = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("B")));
        condC = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("C")));
        condD = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("D")));

        conditionAY = PositionId.unwrap(ConditionIdLib.from(condA).computePositionId(0));
        conditionAN = PositionId.unwrap(ConditionIdLib.from(condA).computePositionId(1));
        conditionBY = PositionId.unwrap(ConditionIdLib.from(condB).computePositionId(0));
        conditionBN = PositionId.unwrap(ConditionIdLib.from(condB).computePositionId(1));
        conditionCY = PositionId.unwrap(ConditionIdLib.from(condC).computePositionId(0));
        conditionCN = PositionId.unwrap(ConditionIdLib.from(condC).computePositionId(1));
        conditionDY = PositionId.unwrap(ConditionIdLib.from(condD).computePositionId(0));
        conditionDN = PositionId.unwrap(ConditionIdLib.from(condD).computePositionId(1));
    }

    /*--------------------------------------------------------------
                             HELPERS
    --------------------------------------------------------------*/

    /// @dev Deal collateral to an address.
    function _dealCollateral(address _to, uint256 _amount) internal {
        vm.prank(address(combinatorial));
        collateral.token.mint(_to, _amount);
    }

    /// @dev Sort two conditions ascending.
    function _sorted2(uint256 a, uint256 b) internal pure returns (uint256[] memory) {
        uint256[] memory conditions = new uint256[](2);
        if (a < b) {
            conditions[0] = a;
            conditions[1] = b;
        } else {
            conditions[0] = b;
            conditions[1] = a;
        }
        return conditions;
    }

    /// @dev Sort three conditions ascending.
    function _sorted3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory) {
        uint256[] memory conditions = new uint256[](3);
        conditions[0] = a;
        conditions[1] = b;
        conditions[2] = c;
        // Simple bubble sort for 3 elements
        if (conditions[0] > conditions[1]) (conditions[0], conditions[1]) = (conditions[1], conditions[0]);
        if (conditions[1] > conditions[2]) (conditions[1], conditions[2]) = (conditions[2], conditions[1]);
        if (conditions[0] > conditions[1]) (conditions[0], conditions[1]) = (conditions[1], conditions[0]);
        return conditions;
    }

    /// @dev Find the index of a condition in a sorted array.
    function _indexOf(uint256[] memory _arr, uint256 _val) internal pure returns (uint256) {
        for (uint256 i; i < _arr.length; ++i) {
            if (_arr[i] == _val) return i;
        }
        revert("condition not found");
    }

    /// @dev Build a single-element condition array.
    function _singleCondition(uint256 a) internal pure returns (uint256[] memory) {
        uint256[] memory conds = new uint256[](1);
        conds[0] = a;
        return conds;
    }

    /// @dev Remove the last condition from a memory array.
    function _removeLast(uint256[] memory _arr) internal pure returns (uint256[] memory) {
        uint256[] memory trimmed = new uint256[](_arr.length - 1);
        for (uint256 i; i < trimmed.length; ++i) {
            trimmed[i] = _arr[i];
        }
        return trimmed;
    }

    /// @dev Flip a condition from YES to NO or vice versa.
    function _flipCondition(uint256 _condition) internal pure returns (uint256) {
        return PositionId.unwrap(
            PositionId.wrap(_condition).conditionId().computePositionId(PositionId.wrap(_condition).outcomeIndex() ^ 1)
        );
    }

    /// @dev Build the canonical YES basket ids for the provided canonical condition array.
    function _yesBasketIds(uint256[] memory _fullConditions) internal view returns (uint256[] memory basketIds) {
        uint256 length = _fullConditions.length;
        basketIds = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            uint256[] memory basketConditions = new uint256[](i + 1);
            for (uint256 j; j < i; ++j) {
                basketConditions[j] = _fullConditions[j];
            }
            basketConditions[i] = _flipCondition(_fullConditions[i]);

            basketIds[i] =
                PositionId.unwrap(combinatorial.getConditionId(_positionIds(basketConditions)).computePositionId(0));
        }
    }

    /// @dev Prepare the canonical YES basket condition definitions for the provided canonical condition array.
    function _prepareYesBasketConditions(uint256[] memory _fullConditions) internal {
        uint256 length = _fullConditions.length;
        for (uint256 i; i < length; ++i) {
            uint256[] memory basketConditions = new uint256[](i + 1);
            for (uint256 j; j < i; ++j) {
                basketConditions[j] = _fullConditions[j];
            }
            basketConditions[i] = _flipCondition(_fullConditions[i]);

            _prepareCondition(basketConditions);
        }
    }

    /// @dev Sum the final payouts of many combinatorial positions for the same amount.
    function _sumPayouts(uint256[] memory _positionIds, uint256 _amount) internal view returns (uint256 total) {
        uint256 length = _positionIds.length;
        for (uint256 i; i < length; ++i) {
            total += combinatorial.getPayout(PositionId.wrap(_positionIds[i]), _amount);
        }
    }

    /// @dev Returns whether the payout is one of the two binary endpoints.
    function _isBinaryPayout(uint256 _payout) internal pure returns (bool) {
        return _payout == 0 || _payout == RESULT_DENOMINATOR;
    }

    function _manyBinaryYesConditions(uint256 _length)
        internal
        view
        returns (uint256[] memory yesConditions, bytes32[] memory conditionIds)
    {
        yesConditions = new uint256[](_length);
        conditionIds = new bytes32[](_length);

        for (uint256 i; i < _length;) {
            bytes32 conditionId =
                bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId(abi.encodePacked("many", i))));
            conditionIds[i] = conditionId;
            yesConditions[i] = PositionId.unwrap(ConditionIdLib.from(conditionId).computePositionId(0));

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 1; i < _length;) {
            uint256 value = yesConditions[i];
            uint256 j = i;
            while (j > 0 && yesConditions[j - 1] > value) {
                yesConditions[j] = yesConditions[j - 1];
                unchecked {
                    --j;
                }
            }
            yesConditions[j] = value;

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Prepare a combinatorial condition and return its conditionId.
    function _prepareCondition(uint256[] memory _conditions) internal returns (bytes32) {
        return bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(_conditions))));
    }

    /// @dev Compute a combinatorial bridge conditionId without storing its definition.
    function _getBridgeConditionId() internal view returns (bytes32) {
        return bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(_singleCondition(conditionAY)))));
    }

    /// @dev Perform a root split for alice. Returns (yesPositionId, noPositionId).
    function _splitForAlice(uint256[] memory _conditions, uint256 _amount) internal returns (uint256, uint256) {
        bytes32 combinatorialConditionId = _prepareCondition(_conditions);
        uint256 yesId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(1));

        _dealCollateral(alice, _amount);

        vm.startPrank(alice);
        collateral.token.transfer(address(combinatorial), _amount);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        combinatorial.split(to, ConditionIdLib.from(combinatorialConditionId), _amount);
        vm.stopPrank();

        return (yesId, noId);
    }

    /// @dev Simulate legacy outstanding supply whose combinatorial condition storage was never prepared.
    function _mintLegacyUnpreparedPairForAlice(uint256[] memory _conditions, uint256 _amount)
        internal
        returns (uint256, uint256)
    {
        bytes32 combinatorialConditionId =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(_conditions))));
        uint256 yesId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(1));

        _dealCollateral(alice, _amount);

        vm.prank(alice);
        collateral.token.transfer(address(combinatorial), _amount);

        vm.startPrank(address(combinatorial));
        positions.manager.mint(alice, PositionId.wrap(yesId), _amount);
        positions.manager.mint(alice, PositionId.wrap(noId), _amount);
        collateral.token.burn(_amount);
        vm.stopPrank();

        return (yesId, noId);
    }

    /// @dev Resolve a binary condition. YES wins if _yesWins is true.
    function _resolve(bytes32 _conditionId, bool _yesWins) internal {
        uint256[] memory result = new uint256[](2);
        result[0] = _yesWins ? RESULT_DENOMINATOR : 0;
        result[1] = _yesWins ? 0 : RESULT_DENOMINATOR;
        vm.prank(oracle);
        positions.binaryModule.reportResult(ConditionIdLib.from(_conditionId), result);
    }

    /// @dev Resolve a binary condition to an arbitrary [yes, no] payout vector.
    function _resolveFractional(bytes32 _conditionId, uint256 _yesPayout) internal {
        uint256[] memory result = new uint256[](2);
        result[0] = _yesPayout;
        result[1] = RESULT_DENOMINATOR - _yesPayout;
        vm.prank(oracle);
        positions.binaryModule.reportResult(ConditionIdLib.from(_conditionId), result);
    }
}

/*--------------------------------------------------------------
                            SPLIT
--------------------------------------------------------------*/

contract CombinatorialModuleTest_split is CombinatorialModuleTest {
    function test_split() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        bytes32 combinatorialConditionId = _prepareCondition(conditions);
        uint256 yesId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(1));

        _dealCollateral(alice, AMOUNT);

        vm.startPrank(alice);
        collateral.token.transfer(address(combinatorial), AMOUNT);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = brian;

        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit PositionsSplit(alice, ConditionIdLib.from(combinatorialConditionId), alice, brian, AMOUNT);

        combinatorial.split(to, ConditionIdLib.from(combinatorialConditionId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), AMOUNT);
        assertEq(positions.manager.balanceOf(brian, noId), AMOUNT);
        assertEq(collateral.token.balanceOf(alice), 0);

        uint256[] memory storedLegs =
            _rawPositionIds(combinatorial.getLegs(ConditionIdLib.from(combinatorialConditionId)));
        assertEq(storedLegs.length, conditions.length);
        for (uint256 i; i < conditions.length; ++i) {
            assertEq(storedLegs[i], conditions[i]);
        }
    }

    function test_revert_split_unprepared() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        ConditionId combinatorialConditionId = combinatorial.getConditionId(_positionIds(conditions));

        assertFalse(combinatorial.isConditionPrepared(combinatorialConditionId));

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = brian;

        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.split(to, combinatorialConditionId, AMOUNT);
    }

    function test_split_singleCondition() public {
        uint256[] memory conditions = _singleCondition(conditionAY);
        (uint256 yesId, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        assertEq(positions.manager.balanceOf(alice, yesId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, noId), AMOUNT);
    }

    function test_revert_emptyConditions() public {
        uint256[] memory conditions = new uint256[](0);
        vm.expectRevert(InvalidConditionSet.selector);
        bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));
    }

    function test_prepareCondition_maxLegs() public {
        (uint256[] memory conditions,) = _manyBinaryYesConditions(50);

        bytes32 conditionId = bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));

        assertEq(_rawPositionIds(combinatorial.getLegs(ConditionIdLib.from(conditionId))).length, 50);
    }

    function test_revert_prepareCondition_tooManyLegs() public {
        (uint256[] memory conditions,) = _manyBinaryYesConditions(50 + 1);

        vm.expectRevert(InvalidConditionSet.selector);
        combinatorial.prepareCondition(_positionIds(conditions));
    }

    function test_revert_splitOnCondition_tooManyLegs() public {
        (uint256[] memory conditions,) = _manyBinaryYesConditions(50);
        bytes32 parentConditionId =
            bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));
        uint256 parentYesId = PositionId.unwrap(ConditionIdLib.from(parentConditionId).computePositionId(0));
        bytes32 extraConditionId = bytes32(ConditionId.unwrap(positions.binaryModule.getConditionId("extra")));

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(InvalidConditionSet.selector);
        combinatorial.splitOnCondition(to, PositionId.wrap(parentYesId), ConditionIdLib.from(extraConditionId), AMOUNT);
    }

    function test_revert_wrongToLength() public {
        uint256[] memory conditions = _singleCondition(conditionAY);
        bytes32 conditionId = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(conditions))));
        address[] memory to = new address[](1);
        to[0] = alice;

        vm.expectRevert(InvalidArrayLength.selector);
        combinatorial.split(to, ConditionIdLib.from(conditionId), AMOUNT);
    }

    function test_revert_split_wrongModuleId() public {
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(InvalidConditionModule.selector);
        combinatorial.split(to, ConditionIdLib.from(condA), AMOUNT);
    }

    function test_revert_nonCanonicalOrder() public {
        // conditionAY and conditionBY - create them in wrong order
        uint256[] memory conditions = new uint256[](2);
        // Put the larger one first
        if (conditionAY < conditionBY) {
            conditions[0] = conditionBY;
            conditions[1] = conditionAY;
        } else {
            conditions[0] = conditionAY;
            conditions[1] = conditionBY;
        }

        vm.expectRevert(NonCanonicalInput.selector);
        bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));
    }

    function test_revert_conflictingConditions() public {
        // Y(A) and N(A) share conditionId
        uint256[] memory conditions = _sorted2(conditionAY, conditionAN);

        vm.expectRevert(ConflictingConditions.selector);
        bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));
    }

    function test_revert_duplicateCondition() public {
        uint256[] memory conditions = new uint256[](2);
        conditions[0] = conditionAY;
        conditions[1] = conditionAY;

        vm.expectRevert(NonCanonicalInput.selector);
        bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));
    }
}

/*--------------------------------------------------------------
                            MERGE
--------------------------------------------------------------*/

contract CombinatorialModuleTest_merge is CombinatorialModuleTest {
    function test_merge() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");

        bytes32 combinatorialConditionId =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(conditions))));
        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit PositionsMerged(alice, ConditionIdLib.from(combinatorialConditionId), alice, AMOUNT);

        combinatorial.merge(alice, ConditionIdLib.from(combinatorialConditionId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), 0);
        assertEq(positions.manager.balanceOf(alice, noId), 0);
        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_merge_unpreparedLegacyPair() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        ConditionId conditionId = combinatorial.getConditionId(_positionIds(conditions));
        (uint256 yesId, uint256 noId) = _mintLegacyUnpreparedPairForAlice(conditions, AMOUNT);

        assertFalse(combinatorial.isConditionPrepared(conditionId));
        assertEq(collateral.token.balanceOf(alice), 0);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.merge(alice, conditionId, AMOUNT);
        vm.stopPrank();

        assertFalse(combinatorial.isConditionPrepared(conditionId));
        assertEq(positions.manager.balanceOf(alice, yesId), 0);
        assertEq(positions.manager.balanceOf(alice, noId), 0);
        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_splitMerge_roundtrip() public {
        uint256[] memory conditions = _sorted3(conditionAY, conditionBN, conditionCY);
        _dealCollateral(alice, AMOUNT);

        uint256 balBefore = collateral.token.balanceOf(alice);

        (uint256 yesId, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.merge(
            alice,
            ConditionIdLib.from(bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(conditions))))),
            AMOUNT
        );
        vm.stopPrank();

        // Extra AMOUNT from _dealCollateral in _splitForAlice
        assertEq(collateral.token.balanceOf(alice), balBefore + AMOUNT);
    }

    function test_revert_merge_wrongModuleId() public {
        vm.expectRevert(InvalidConditionModule.selector);
        combinatorial.merge(alice, ConditionIdLib.from(condA), AMOUNT);
    }
}

/*--------------------------------------------------------------
                       SPLIT ON CONDITION
--------------------------------------------------------------*/

contract CombinatorialModuleTest_splitOnCondition is CombinatorialModuleTest {
    function test_splitOnCondition() public {
        // Start with YES(A^B), split on C -> YES(A^B^Y(C)) + YES(A^B^N(C))
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);

        uint256[] memory childYesConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        uint256[] memory childNoConditions = _sorted3(conditionAY, conditionBY, conditionCN);

        bytes32 childYesCid =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(childYesConditions))));
        bytes32 childNoCid = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(childNoConditions))));
        uint256 childYesId = PositionId.unwrap(ConditionIdLib.from(childYesCid).computePositionId(0));
        uint256 childNoId = PositionId.unwrap(ConditionIdLib.from(childNoCid).computePositionId(0));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        combinatorial.splitOnCondition(to, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, parentYesId), 0);
        assertEq(positions.manager.balanceOf(alice, childYesId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, childNoId), AMOUNT);
    }

    function test_revert_splitOnCondition_wrongToLength() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");

        address[] memory to = new address[](1);
        to[0] = alice;

        vm.expectRevert(InvalidArrayLength.selector);
        combinatorial.splitOnCondition(to, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
        vm.stopPrank();
    }

    function test_revert_splitOnCondition_referenceMustBeConditionId() public {
        bytes32 nonCanonicalConditionId = bytes32(uint256(condC) | 1);

        vm.expectRevert(
            abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, nonCanonicalConditionId)
        );
        this.callConditionIdFrom(nonCanonicalConditionId);
    }

    function test_revert_splitOnCondition_parentMustBeYes() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (, uint256 parentNoId) = _splitForAlice(parentConditions, AMOUNT);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(InvalidOutcomeIndex.selector);
        combinatorial.splitOnCondition(to, PositionId.wrap(parentNoId), ConditionIdLib.from(condC), AMOUNT);
    }

    function test_revert_splitOnCondition_parentUnprepared() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _mintLegacyUnpreparedPairForAlice(parentConditions, AMOUNT);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.splitOnCondition(to, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
    }

    function test_revert_conditionAlreadyPresent() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        // condA is already in the combinatorial
        vm.expectRevert(MarketAlreadyPresent.selector);
        combinatorial.splitOnCondition(to, PositionId.wrap(parentYesId), ConditionIdLib.from(condA), AMOUNT);
    }
}

/*--------------------------------------------------------------
                       MERGE ON CONDITION
--------------------------------------------------------------*/

contract CombinatorialModuleTest_mergeOnCondition is CombinatorialModuleTest {
    function test_mergeOnCondition() public {
        // Split parent into children, then merge back
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);

        // Split on C
        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        combinatorial.splitOnCondition(to, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);

        // Now merge back
        uint256[] memory childYesConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        uint256[] memory childNoConditions = _sorted3(conditionAY, conditionBY, conditionCN);
        uint256 childYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(childYesConditions)).computePositionId(0));
        uint256 childNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(childNoConditions)).computePositionId(0));

        positions.manager.safeTransferFrom(alice, address(combinatorial), childYesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), childNoId, AMOUNT, "");
        combinatorial.mergeOnCondition(alice, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, parentYesId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, childYesId), 0);
        assertEq(positions.manager.balanceOf(alice, childNoId), 0);
    }

    function test_revert_mergeOnCondition_referenceMustBeConditionId() public {
        bytes32 nonCanonicalConditionId = bytes32(uint256(condC) | 1);

        vm.expectRevert(
            abi.encodeWithSelector(ConditionIdLib.NonCanonicalConditionId.selector, nonCanonicalConditionId)
        );
        this.callConditionIdFrom(nonCanonicalConditionId);
    }

    function test_revert_mergeOnCondition_parentMustBeYes() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (, uint256 parentNoId) = _splitForAlice(parentConditions, AMOUNT);

        vm.expectRevert(InvalidOutcomeIndex.selector);
        combinatorial.mergeOnCondition(alice, PositionId.wrap(parentNoId), ConditionIdLib.from(condC), AMOUNT);
    }

    function test_revert_mergeOnCondition_parentUnprepared() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _mintLegacyUnpreparedPairForAlice(parentConditions, AMOUNT);

        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.mergeOnCondition(alice, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
    }
}

/*--------------------------------------------------------------
                    SPLIT / MERGE / CONVERT ON EVENT
--------------------------------------------------------------*/

contract CombinatorialModuleTest_eventOperations is CombinatorialModuleTest {
    function _eventRecipients(uint256 _length) private pure returns (address[] memory recipients) {
        recipients = new address[](_length);
        for (uint256 i; i < _length; ++i) {
            recipients[i] = address(uint160(0xA11CE000 + i));
        }
    }

    function _prepareEventChildPositionId(EventId _eventId, uint256 _conditionIndex)
        private
        returns (uint256 childPositionId)
    {
        uint256 eventYesId = PositionId.unwrap(_eventId.computeConditionId(_conditionIndex).computePositionId(0));
        bytes32 childConditionId = _prepareCondition(_sorted2(conditionAY, eventYesId));
        childPositionId = PositionId.unwrap(ConditionIdLib.from(childConditionId).computePositionId(0));
    }

    function _assertRecipientOrdering(address[] memory _recipients, uint256[] memory _childPositionIds) private view {
        assertEq(_recipients.length, _childPositionIds.length);

        for (uint256 childIndex; childIndex < _childPositionIds.length; ++childIndex) {
            for (uint256 recipientIndex; recipientIndex < _recipients.length; ++recipientIndex) {
                uint256 expectedBalance = childIndex == recipientIndex ? AMOUNT : 0;
                assertEq(
                    positions.manager.balanceOf(_recipients[recipientIndex], _childPositionIds[childIndex]),
                    expectedBalance
                );
            }
        }
    }

    function test_splitMergeOnEvent() public {
        EventId eventId = positions.negRiskModule.getEventId(3, "split-merge-on-event");
        (uint256 parentYesId,) = _splitForAlice(_singleCondition(conditionAY), AMOUNT);

        uint256[] memory childPositionIds = new uint256[](4);
        for (uint256 i; i < childPositionIds.length; ++i) {
            uint256 eventYesId = PositionId.unwrap(eventId.computeConditionId(i).computePositionId(0));
            childPositionIds[i] = PositionId.unwrap(
                combinatorial.getConditionId(_positionIds(_sorted2(conditionAY, eventYesId))).computePositionId(0)
            );
        }

        address[] memory to = new address[](4);
        for (uint256 i; i < to.length; ++i) {
            to[i] = alice;
        }

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");
        combinatorial.splitOnEvent(to, PositionId.wrap(parentYesId), eventId, AMOUNT);

        assertEq(positions.manager.balanceOf(alice, parentYesId), 0);
        for (uint256 i; i < childPositionIds.length; ++i) {
            assertEq(positions.manager.balanceOf(alice, childPositionIds[i]), AMOUNT);
            positions.manager.safeTransferFrom(alice, address(combinatorial), childPositionIds[i], AMOUNT, "");
        }

        combinatorial.mergeOnEvent(alice, PositionId.wrap(parentYesId), eventId, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, parentYesId), AMOUNT);
        for (uint256 i; i < childPositionIds.length; ++i) {
            assertEq(positions.manager.balanceOf(alice, childPositionIds[i]), 0);
        }
    }

    function test_splitOnEvent_recipientsFollowConditionIndexIncludingOther() public {
        uint256 conditionCount = 3;
        EventId eventId = positions.negRiskModule.getEventId(conditionCount, "split-recipient-order");
        (uint256 parentYesId,) = _splitForAlice(_singleCondition(conditionAY), AMOUNT);
        ConditionId parentConditionId = PositionId.wrap(parentYesId).conditionId();

        address[] memory recipients = _eventRecipients(conditionCount + 1);
        uint256[] memory childPositionIds = new uint256[](conditionCount + 1);
        for (uint256 conditionIndex; conditionIndex <= conditionCount; ++conditionIndex) {
            childPositionIds[conditionIndex] = _prepareEventChildPositionId(eventId, conditionIndex);
        }

        vm.startPrank(alice);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");

        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit SplitOnEvent(alice, parentConditionId, eventId, recipients, AMOUNT);
        combinatorial.splitOnEvent(recipients, PositionId.wrap(parentYesId), eventId, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, parentYesId), 0);
        _assertRecipientOrdering(recipients, childPositionIds);
    }

    function test_revert_splitOnEvent_invalidRecipientCount() public {
        EventId eventId = positions.negRiskModule.getEventId(3, "split-invalid-recipient-count");
        (uint256 parentYesId,) = _splitForAlice(_singleCondition(conditionAY), AMOUNT);
        address[] memory recipients = _eventRecipients(3);

        vm.expectRevert(InvalidArrayLength.selector);
        combinatorial.splitOnEvent(recipients, PositionId.wrap(parentYesId), eventId, AMOUNT);
    }

    function test_convertOnEvent() public {
        EventId eventId = positions.negRiskModule.getEventId(3, "convert-on-event");
        uint256 eventNoId = PositionId.unwrap(eventId.computeConditionId(0).computePositionId(1));
        uint256[] memory parentConditions = _sorted2(conditionAY, eventNoId);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);
        uint256 sourceIndex = _indexOf(parentConditions, eventNoId);

        address[] memory to = new address[](3);
        for (uint256 i; i < to.length; ++i) {
            to[i] = alice;
        }

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");
        combinatorial.convertOnEvent(to, PositionId.wrap(parentYesId), sourceIndex, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, parentYesId), 0);
        for (uint256 i = 1; i <= 3; ++i) {
            uint256 eventYesId = PositionId.unwrap(eventId.computeConditionId(i).computePositionId(0));
            uint256 childPositionId = PositionId.unwrap(
                combinatorial.getConditionId(_positionIds(_sorted2(conditionAY, eventYesId))).computePositionId(0)
            );
            assertEq(positions.manager.balanceOf(alice, childPositionId), AMOUNT);
        }
    }

    function test_convertOnEvent_recipientsFollowConditionIndexExcludingEverySource() public {
        uint256 conditionCount = 3;

        for (uint256 sourceConditionIndex; sourceConditionIndex <= conditionCount; ++sourceConditionIndex) {
            EventId eventId = positions.negRiskModule
                .getEventId(conditionCount, abi.encode("convert-recipient-order", sourceConditionIndex));
            uint256 eventNoId = PositionId.unwrap(eventId.computeConditionId(sourceConditionIndex).computePositionId(1));
            uint256[] memory parentConditions = _sorted2(conditionAY, eventNoId);
            (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);
            ConditionId parentConditionId = PositionId.wrap(parentYesId).conditionId();
            uint256 sourceLegIndex = _indexOf(parentConditions, eventNoId);

            address[] memory recipients = _eventRecipients(conditionCount);
            uint256[] memory childPositionIds = new uint256[](conditionCount);
            uint256 recipientIndex;
            for (uint256 conditionIndex; conditionIndex <= conditionCount; ++conditionIndex) {
                if (conditionIndex == sourceConditionIndex) continue;
                childPositionIds[recipientIndex] = _prepareEventChildPositionId(eventId, conditionIndex);
                ++recipientIndex;
            }

            vm.startPrank(alice);
            positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");

            vm.expectEmit(true, true, true, true, address(combinatorial));
            emit ConvertedOnEvent(alice, parentConditionId, eventId, sourceLegIndex, recipients, AMOUNT);
            combinatorial.convertOnEvent(recipients, PositionId.wrap(parentYesId), sourceLegIndex, AMOUNT);
            vm.stopPrank();

            assertEq(positions.manager.balanceOf(alice, parentYesId), 0);
            _assertRecipientOrdering(recipients, childPositionIds);
        }
    }

    function test_revert_convertOnEvent_invalidRecipientCount() public {
        EventId eventId = positions.negRiskModule.getEventId(3, "convert-invalid-recipient-count");
        uint256 eventNoId = PositionId.unwrap(eventId.computeConditionId(1).computePositionId(1));
        uint256[] memory parentConditions = _sorted2(conditionAY, eventNoId);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);
        uint256 sourceLegIndex = _indexOf(parentConditions, eventNoId);
        address[] memory recipients = _eventRecipients(2);

        vm.expectRevert(InvalidArrayLength.selector);
        combinatorial.convertOnEvent(recipients, PositionId.wrap(parentYesId), sourceLegIndex, AMOUNT);
    }

    function test_revert_splitOnEvent_eventAlreadyPresent() public {
        EventId eventId = positions.negRiskModule.getEventId(3, "event-already-present");
        uint256 eventYesId = PositionId.unwrap(eventId.computeConditionId(0).computePositionId(0));
        (uint256 parentYesId,) = _splitForAlice(_sorted2(conditionAY, eventYesId), AMOUNT);

        address[] memory to = new address[](4);
        vm.expectRevert(EventAlreadyPresent.selector);
        combinatorial.splitOnEvent(to, PositionId.wrap(parentYesId), eventId, AMOUNT);
    }
}

/*--------------------------------------------------------------
                           EXTRACT
--------------------------------------------------------------*/

contract CombinatorialModuleTest_extract is CombinatorialModuleTest {
    function test_extract() public {
        // NO(A^B^C), extract C -> NO(A^B) + YES(A^B^N(C))
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        // Find the index of conditionCY in the sorted array
        uint256 cIndex;
        for (uint256 i; i < fullConditions.length; ++i) {
            if (fullConditions[i] == conditionCY) {
                cIndex = i;
                break;
            }
        }

        uint256[] memory reducedConditions = _sorted2(conditionAY, conditionBY);
        uint256[] memory residualConditions = _sorted3(conditionAY, conditionBY, conditionCN);

        bytes32 reducedCid = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(reducedConditions))));
        bytes32 residualCid =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(residualConditions))));
        uint256 reducedNoId = PositionId.unwrap(ConditionIdLib.from(reducedCid).computePositionId(1));
        uint256 residualYesId = PositionId.unwrap(ConditionIdLib.from(residualCid).computePositionId(0));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        combinatorial.extract(to, PositionId.wrap(fullNoId), cIndex, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, fullNoId), 0);
        assertEq(positions.manager.balanceOf(alice, reducedNoId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, residualYesId), AMOUNT);
    }

    function test_revert_extract_wrongToLength() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);
        uint256 cIndex = _indexOf(fullConditions, conditionCY);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](1);
        to[0] = alice;

        vm.expectRevert(InvalidArrayLength.selector);
        combinatorial.extract(to, PositionId.wrap(fullNoId), cIndex, AMOUNT);
        vm.stopPrank();
    }

    function test_extract_fullDecomposition() public {
        // NO(A^B^C) via repeated extract equals flat decomposition
        // Extract C from NO(A^B^C) -> NO(A^B) + YES(A^B^N(C))
        // Extract B from NO(A^B) -> NO(A) + YES(A^N(B))
        // Result: NO(A), YES(A^N(B)), YES(A^B^N(C))

        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        uint256 cIdx = _indexOf(fullConditions, conditionCY);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        combinatorial.extract(to, PositionId.wrap(fullNoId), cIdx, AMOUNT);

        // Now extract B from NO(A^B) -> NO(A) + YES(A^N(B))
        uint256[] memory abConditions = _sorted2(conditionAY, conditionBY);
        uint256 bIdx = _indexOf(abConditions, conditionBY);
        uint256 abNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(abConditions)).computePositionId(1));

        positions.manager.safeTransferFrom(alice, address(combinatorial), abNoId, AMOUNT, "");
        combinatorial.extract(to, PositionId.wrap(abNoId), bIdx, AMOUNT);
        vm.stopPrank();

        // Now alice has: NO(A) + YES(A^N(B)) + YES(A^B^N(C))
        uint256 aNoId = PositionId.unwrap(
            combinatorial.getConditionId(_positionIds(_singleCondition(conditionAY))).computePositionId(1)
        );
        uint256 aNbYesId = PositionId.unwrap(
            combinatorial.getConditionId(_positionIds(_sorted2(conditionAY, conditionBN))).computePositionId(0)
        );
        uint256 abNcYesId = PositionId.unwrap(
            combinatorial.getConditionId(_positionIds(_sorted3(conditionAY, conditionBY, conditionCN)))
                .computePositionId(0)
        );

        assertEq(positions.manager.balanceOf(alice, aNoId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, aNbYesId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, abNcYesId), AMOUNT);
    }

    function test_revert_singleCondition() public {
        uint256[] memory conditions = _singleCondition(conditionAY);
        (, uint256 fullNoId) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(InvalidConditionSet.selector);
        combinatorial.extract(to, PositionId.wrap(fullNoId), 0, AMOUNT);
        vm.stopPrank();
    }

    function test_revert_indexOutOfRange() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 fullNoId) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(ConditionIndexOutOfRange.selector);
        combinatorial.extract(to, PositionId.wrap(fullNoId), 5, AMOUNT);
        vm.stopPrank();
    }

    function test_revert_extract_requiresNoSide() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (uint256 fullYesId,) = _splitForAlice(fullConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullYesId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(InvalidOutcomeIndex.selector);
        combinatorial.extract(to, PositionId.wrap(fullYesId), 0, AMOUNT);
        vm.stopPrank();
    }

    function test_revert_extract_unprepared() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _mintLegacyUnpreparedPairForAlice(fullConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.extract(to, PositionId.wrap(fullNoId), 0, AMOUNT);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                           INJECT
--------------------------------------------------------------*/

contract CombinatorialModuleTest_inject is CombinatorialModuleTest {
    function test_inject() public {
        // Extract C from NO(A^B^C), then inject back -> should roundtrip
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        uint256 cIdx = _indexOf(fullConditions, conditionCY);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);

        // Extract C
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        combinatorial.extract(to, PositionId.wrap(fullNoId), cIdx, AMOUNT);

        assertEq(positions.manager.balanceOf(alice, fullNoId), 0);

        // Inject back: NO(A^B) + YES(A^B^N(C)) -> NO(A^B^C)
        uint256[] memory reducedConditions = _sorted2(conditionAY, conditionBY);
        uint256[] memory residualConditions = _sorted3(conditionAY, conditionBY, conditionCN);
        uint256 reducedNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(reducedConditions)).computePositionId(1));
        uint256 residualYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(residualConditions)).computePositionId(0));

        positions.manager.safeTransferFrom(alice, address(combinatorial), reducedNoId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), residualYesId, AMOUNT, "");
        combinatorial.inject(alice, PositionId.wrap(fullNoId), cIdx, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, fullNoId), AMOUNT);
    }

    function test_revert_inject_requiresNoSide() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (uint256 fullYesId,) = _splitForAlice(fullConditions, AMOUNT);

        vm.expectRevert(InvalidOutcomeIndex.selector);
        combinatorial.inject(alice, PositionId.wrap(fullYesId), 0, AMOUNT);
    }

    function test_revert_inject_unprepared() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _mintLegacyUnpreparedPairForAlice(fullConditions, AMOUNT);

        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.inject(alice, PositionId.wrap(fullNoId), 0, AMOUNT);
    }
}

/*--------------------------------------------------------------
                    CONVERT TO YES BASKET / MERGE FROM YES BASKET
--------------------------------------------------------------*/

contract CombinatorialModuleTest_convertToYesBasket is CombinatorialModuleTest {
    function test_convertToYesBasket() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);
        uint256[] memory basketYesIds = _yesBasketIds(fullConditions);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](3);
        to[0] = alice;
        to[1] = alice;
        to[2] = alice;

        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, fullNoId), 0);
        for (uint256 i; i < basketYesIds.length; ++i) {
            assertEq(positions.manager.balanceOf(alice, basketYesIds[i]), AMOUNT);
        }
    }

    function test_revert_convertToYesBasket_wrongToLength() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(InvalidArrayLength.selector);
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();
    }

    function test_convertToYesBasket_singleCondition() public {
        uint256[] memory fullConditions = _singleCondition(conditionAY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);
        uint256 basketYesId = PositionId.unwrap(
            combinatorial.getConditionId(_positionIds(_singleCondition(conditionAN))).computePositionId(0)
        );

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](1);
        to[0] = alice;
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, basketYesId), AMOUNT);
    }

    function test_revert_convertToYesBasket_requiresNoSide() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (uint256 fullYesId,) = _splitForAlice(fullConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullYesId, AMOUNT, "");

        address[] memory to = new address[](3);
        to[0] = alice;
        to[1] = alice;
        to[2] = alice;

        vm.expectRevert(InvalidOutcomeIndex.selector);
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullYesId), AMOUNT);
        vm.stopPrank();
    }

    function test_revert_convertToYesBasket_unprepared() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _mintLegacyUnpreparedPairForAlice(fullConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](3);
        to[0] = alice;
        to[1] = alice;
        to[2] = alice;

        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();
    }
}

contract CombinatorialModuleTest_mergeFromYesBasket is CombinatorialModuleTest {
    function test_mergeFromYesBasket() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);
        uint256[] memory basketYesIds = _yesBasketIds(fullConditions);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](3);
        to[0] = alice;
        to[1] = alice;
        to[2] = alice;
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);

        for (uint256 i; i < basketYesIds.length; ++i) {
            positions.manager.safeTransferFrom(alice, address(combinatorial), basketYesIds[i], AMOUNT, "");
        }
        combinatorial.mergeFromYesBasket(alice, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, fullNoId), AMOUNT);
        for (uint256 i; i < basketYesIds.length; ++i) {
            assertEq(positions.manager.balanceOf(alice, basketYesIds[i]), 0);
        }
    }

    function test_revert_mergeFromYesBasket_requiresNoSide() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (uint256 fullYesId,) = _splitForAlice(fullConditions, AMOUNT);

        vm.expectRevert(InvalidOutcomeIndex.selector);
        combinatorial.mergeFromYesBasket(alice, PositionId.wrap(fullYesId), AMOUNT);
    }

    function test_revert_mergeFromYesBasket_unprepared() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _mintLegacyUnpreparedPairForAlice(fullConditions, AMOUNT);

        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.mergeFromYesBasket(alice, PositionId.wrap(fullNoId), AMOUNT);
    }
}

/*--------------------------------------------------------------
                          COMPRESS
--------------------------------------------------------------*/

contract CombinatorialModuleTest_compress is CombinatorialModuleTest {
    function test_compress_yesPosition_trueConditionRemoved() public {
        // YES(A^B), A resolves YES -> YES(B)
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);

        uint256[] memory bConditions = _singleCondition(conditionBY);
        bytes32 bCid = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(bConditions))));
        uint256 compressedYesId = PositionId.unwrap(ConditionIdLib.from(bCid).computePositionId(0));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        combinatorial.compress(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), 0);
        assertEq(positions.manager.balanceOf(alice, compressedYesId), AMOUNT);
    }

    function test_compress_yesPosition_falseConditionMakesWorthless() public {
        // YES(A^B), A resolves NO -> worthless
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, false);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        combinatorial.compress(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), 0);
        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_compress_yesPosition_allTrue_collateral() public {
        // YES(A^B), both resolve YES -> collateral
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, true);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        combinatorial.compress(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_compress_noPosition_falseConditionMakesCollateral() public {
        // NO(A^B), A resolves NO -> collateral (NO wins)
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, false);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.compress(alice, PositionId.wrap(noId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_compress_noPosition_trueConditionReduces() public {
        // NO(A^B), A resolves YES -> NO(B)
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);

        uint256[] memory bConditions = _singleCondition(conditionBY);
        bytes32 bCid = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(bConditions))));
        uint256 compressedNoId = PositionId.unwrap(ConditionIdLib.from(bCid).computePositionId(1));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.compress(alice, PositionId.wrap(noId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, compressedNoId), AMOUNT);
    }

    function test_compress_noPosition_allTrueWorthless() public {
        // NO(A^B), both resolve YES -> NO is worthless
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, true);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.compress(alice, PositionId.wrap(noId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_revert_nothingToCompress() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        // Neither resolved -> nothing to compress
        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");

        vm.expectRevert(PositionNotCompressible.selector);
        combinatorial.compress(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();
    }

    function test_compress_yesPosition_fractionalConditionScalesDown() public {
        uint256 amount = 100;
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, amount);

        _resolveFractional(condA, 400_000);

        uint256[] memory bConditions = _singleCondition(conditionBY);
        uint256 compressedYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(bConditions)).computePositionId(0));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, amount, "");
        combinatorial.compress(alice, PositionId.wrap(yesId), amount);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), 0);
        assertEq(positions.manager.balanceOf(alice, compressedYesId), 40);
        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_compress_yesPosition_fractionalConditionAfterUnresolvedScalesDown() public {
        uint256 amount = 100;
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, amount);

        _resolveFractional(bytes32(ConditionId.unwrap(PositionId.wrap(conditions[1]).conditionId())), 400_000);

        uint256[] memory remainingConditions = _singleCondition(conditions[0]);
        uint256 compressedYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(remainingConditions)).computePositionId(0));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, amount, "");
        combinatorial.compress(alice, PositionId.wrap(yesId), amount);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, yesId), 0);
        assertEq(positions.manager.balanceOf(alice, compressedYesId), 40);
    }

    function test_compress_noPosition_fractionalConditionMintsCollateralAndReducedNo() public {
        uint256 amount = 100;
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, amount);

        _resolveFractional(condA, 400_000);

        uint256[] memory bConditions = _singleCondition(conditionBY);
        uint256 compressedNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(bConditions)).computePositionId(1));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, amount, "");
        combinatorial.compress(alice, PositionId.wrap(noId), amount);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, noId), 0);
        assertEq(collateral.token.balanceOf(alice), 60);
        assertEq(positions.manager.balanceOf(alice, compressedNoId), 40);
    }

    function test_compress_fractionalDustDoesNotLeakCollateral() public {
        uint256 amount = 101;
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId, uint256 noId) = _splitForAlice(conditions, amount);

        _resolveFractional(condA, 400_000);

        uint256[] memory bConditions = _singleCondition(conditionBY);
        bytes32 bCid = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(bConditions))));
        uint256 compressedYesId = PositionId.unwrap(ConditionIdLib.from(bCid).computePositionId(0));
        uint256 compressedNoId = PositionId.unwrap(ConditionIdLib.from(bCid).computePositionId(1));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);

        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, amount, "");
        combinatorial.compress(alice, PositionId.wrap(yesId), amount);

        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, amount, "");
        combinatorial.compress(alice, PositionId.wrap(noId), amount);

        positions.manager.safeTransferFrom(alice, address(combinatorial), compressedYesId, 40, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), compressedNoId, 40, "");
        combinatorial.merge(alice, ConditionIdLib.from(bCid), 40);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 100);
        assertEq(positions.manager.balanceOf(alice, compressedNoId), 1);
    }

    function test_compress_fractionalDustCannotExtractAfterRemainingLegResolves() public {
        uint256 amount = 101;
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId, uint256 noId) = _splitForAlice(conditions, amount);

        _resolveFractional(condA, 400_000);

        uint256[] memory bConditions = _singleCondition(conditionBY);
        bytes32 bCid = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(bConditions))));
        uint256 compressedYesId = PositionId.unwrap(ConditionIdLib.from(bCid).computePositionId(0));
        uint256 compressedNoId = PositionId.unwrap(ConditionIdLib.from(bCid).computePositionId(1));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, amount, "");
        combinatorial.compress(alice, PositionId.wrap(yesId), amount);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, amount, "");
        combinatorial.compress(alice, PositionId.wrap(noId), amount);
        vm.stopPrank();

        _resolve(condB, false);

        vm.startPrank(alice);
        positions.manager.safeTransferFrom(alice, address(combinatorial), compressedYesId, 40, "");
        combinatorial.redeem(alice, PositionId.wrap(compressedYesId), 40);
        positions.manager.safeTransferFrom(alice, address(combinatorial), compressedNoId, 41, "");
        combinatorial.redeem(alice, PositionId.wrap(compressedNoId), 41);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), amount);
    }
}

/*--------------------------------------------------------------
                           REDEEM
--------------------------------------------------------------*/

contract CombinatorialModuleTest_redeem is CombinatorialModuleTest {
    function test_redeem_yesPosition_allTrue() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, true);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");

        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit PositionRedeemed(alice, PositionId.wrap(yesId), alice, AMOUNT, AMOUNT);

        combinatorial.redeem(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_redeem_yesPosition_anyFalse() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, false);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        combinatorial.redeem(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_redeem_yesPosition_laterFalseBeforeAllResolved() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condB, false);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");
        combinatorial.redeem(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_redeem_noPosition_anyFalse() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, false);
        _resolve(condB, true);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.redeem(alice, PositionId.wrap(noId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_redeem_noPosition_laterFalseBeforeAllResolved() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condB, false);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.redeem(alice, PositionId.wrap(noId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_redeem_noPosition_allTrue() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, true);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");
        combinatorial.redeem(alice, PositionId.wrap(noId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 0);
    }

    function test_revert_notFullyResolved() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        // condB not resolved

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");

        vm.expectRevert(PositionNotRedeemable.selector);
        combinatorial.redeem(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();
    }

    function test_redeem_yesPosition_fractionalProduct() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolveFractional(condA, 700_000);
        _resolveFractional(condB, 500_000);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");

        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit PositionRedeemed(alice, PositionId.wrap(yesId), alice, AMOUNT, 350_000_000);

        combinatorial.redeem(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 350_000_000);
    }

    function test_redeem_noPosition_fractionalComplement() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolveFractional(condA, 700_000);
        _resolveFractional(condB, 500_000);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, AMOUNT, "");

        vm.expectEmit(true, true, true, true, address(combinatorial));
        emit PositionRedeemed(alice, PositionId.wrap(noId), alice, AMOUNT, 650_000_000);

        combinatorial.redeem(alice, PositionId.wrap(noId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 650_000_000);
    }

    function test_redeem_fractionalYesNoPairCannotExtractDust() public {
        uint256 amount = 3;
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId, uint256 noId) = _splitForAlice(conditions, amount);

        _resolveFractional(bytes32(ConditionId.unwrap(PositionId.wrap(conditions[0]).conditionId())), 500_000);
        _resolveFractional(bytes32(ConditionId.unwrap(PositionId.wrap(conditions[1]).conditionId())), 700_000);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, amount, "");
        combinatorial.redeem(alice, PositionId.wrap(yesId), amount);
        positions.manager.safeTransferFrom(alice, address(combinatorial), noId, amount, "");
        combinatorial.redeem(alice, PositionId.wrap(noId), amount);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), 2);
    }
}

/*--------------------------------------------------------------
                          UNWRAP
--------------------------------------------------------------*/

contract CombinatorialModuleTest_unwrap is CombinatorialModuleTest {
    function test_unwrap_yesPosition() public {
        // YES combinatorial of [Y(A)] -> unwrap to binary YES(A)
        uint256[] memory conditions = _singleCondition(conditionAY);
        (uint256 combinatorialYesId,) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), combinatorialYesId, AMOUNT, "");
        combinatorial.unwrap(alice, PositionId.wrap(combinatorialYesId), AMOUNT);
        vm.stopPrank();

        // Should have the binary YES position
        assertEq(positions.manager.balanceOf(alice, conditionAY), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, combinatorialYesId), 0);
    }

    function test_unwrap_noPosition() public {
        // NO combinatorial of [Y(A)] -> unwrap to binary NO(A)
        uint256[] memory conditions = _singleCondition(conditionAY);
        (, uint256 combinatorialNoId) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), combinatorialNoId, AMOUNT, "");
        combinatorial.unwrap(alice, PositionId.wrap(combinatorialNoId), AMOUNT);
        vm.stopPrank();

        // Should have the binary NO position (flipped from Y(A) -> N(A))
        assertEq(positions.manager.balanceOf(alice, conditionAN), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, combinatorialNoId), 0);
    }

    function test_unwrap_yesPosition_ofNCondition() public {
        // YES combinatorial of [N(A)] -> unwrap to binary NO(A)
        uint256[] memory conditions = _singleCondition(conditionAN);
        (uint256 combinatorialYesId,) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), combinatorialYesId, AMOUNT, "");
        combinatorial.unwrap(alice, PositionId.wrap(combinatorialYesId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, conditionAN), AMOUNT);
    }

    function test_revert_unwrap_multiCondition() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesId, AMOUNT, "");

        vm.expectRevert(SingleConditionRequired.selector);
        combinatorial.unwrap(alice, PositionId.wrap(yesId), AMOUNT);
        vm.stopPrank();
    }
}

/*--------------------------------------------------------------
                            WRAP
--------------------------------------------------------------*/

contract CombinatorialModuleTest_wrap is CombinatorialModuleTest {
    function test_wrap() public {
        // Get a binary YES position, then wrap it
        _dealCollateral(alice, AMOUNT);

        // Split on binary module to get YES(A) and NO(A)
        vm.startPrank(alice);
        collateral.token.transfer(address(positions.binaryModule), AMOUNT);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        positions.binaryModule.split(to, ConditionIdLib.from(condA), AMOUNT);

        // Wrap YES(A) into a combinatorial
        positions.manager.safeTransferFrom(alice, address(combinatorial), conditionAY, AMOUNT, "");
        combinatorial.wrap(alice, PositionId.wrap(conditionAY), AMOUNT);
        vm.stopPrank();

        uint256[] memory conditions = _singleCondition(conditionAY);
        bytes32 combinatorialConditionId =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(conditions))));
        uint256 combinatorialYesId =
            PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(0));

        assertEq(positions.manager.balanceOf(alice, combinatorialYesId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, conditionAY), 0);
    }

    function test_wrapUnwrap_roundtrip() public {
        _dealCollateral(alice, AMOUNT);

        vm.startPrank(alice);
        collateral.token.transfer(address(positions.binaryModule), AMOUNT);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        positions.binaryModule.split(to, ConditionIdLib.from(condA), AMOUNT);

        // Wrap then unwrap
        positions.manager.safeTransferFrom(alice, address(combinatorial), conditionAY, AMOUNT, "");
        combinatorial.wrap(alice, PositionId.wrap(conditionAY), AMOUNT);

        uint256[] memory conditions = _singleCondition(conditionAY);
        uint256 combinatorialYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(conditions)).computePositionId(0));

        positions.manager.safeTransferFrom(alice, address(combinatorial), combinatorialYesId, AMOUNT, "");
        combinatorial.unwrap(alice, PositionId.wrap(combinatorialYesId), AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, conditionAY), AMOUNT);
    }
}

/*--------------------------------------------------------------
                        GET PAYOUT
--------------------------------------------------------------*/

contract CombinatorialModuleTest_getPayout is CombinatorialModuleTest {
    function _resolveMany(bytes32[] memory _conditionIds, uint256 _yesPayout) internal {
        uint256[] memory result = new uint256[](2);
        result[0] = _yesPayout;
        result[1] = RESULT_DENOMINATOR - _yesPayout;

        for (uint256 i; i < _conditionIds.length;) {
            vm.prank(oracle);
            positions.binaryModule.reportResult(ConditionIdLib.from(_conditionIds[i]), result);

            unchecked {
                ++i;
            }
        }
    }

    function test_getPayout_yesAllTrue() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, true);

        assertEq(combinatorial.getPayout(PositionId.wrap(yesId), AMOUNT), AMOUNT);
    }

    function test_getPayout_yesAnyFalse() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, false);

        assertEq(combinatorial.getPayout(PositionId.wrap(yesId), AMOUNT), 0);
    }

    function test_getPayout_yesLaterFalseBeforeAllResolved() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condB, false);

        assertEq(combinatorial.getPayout(PositionId.wrap(yesId), AMOUNT), 0);
    }

    function test_getPayout_noAnyFalse() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, false);
        _resolve(condB, true);

        assertEq(combinatorial.getPayout(PositionId.wrap(noId), AMOUNT), AMOUNT);
    }

    function test_getPayout_noLaterFalseBeforeAllResolved() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condB, false);

        assertEq(combinatorial.getPayout(PositionId.wrap(noId), AMOUNT), AMOUNT);
    }

    function test_getPayout_noAllTrue() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);
        _resolve(condB, true);

        assertEq(combinatorial.getPayout(PositionId.wrap(noId), AMOUNT), 0);
    }

    function test_revert_unresolved() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolve(condA, true);

        vm.expectRevert(PositionNotRedeemable.selector);
        combinatorial.getPayout(PositionId.wrap(yesId), AMOUNT);
    }

    function test_getPayout_yesFractionalProduct() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, AMOUNT);

        _resolveFractional(condA, 700_000);
        _resolveFractional(condB, 500_000);

        assertEq(combinatorial.getPayout(PositionId.wrap(yesId), AMOUNT), 350_000_000);
    }

    function test_getPayout_noFractionalComplement() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (, uint256 noId) = _splitForAlice(conditions, AMOUNT);

        _resolveFractional(condA, 700_000);
        _resolveFractional(condB, 500_000);

        assertEq(combinatorial.getPayout(PositionId.wrap(noId), AMOUNT), 650_000_000);
    }

    function test_getPayout_yesFractionalRoundsAtEnd() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        (uint256 yesId,) = _splitForAlice(conditions, 3);

        _resolveFractional(bytes32(ConditionId.unwrap(PositionId.wrap(conditions[0]).conditionId())), 500_000);
        _resolveFractional(bytes32(ConditionId.unwrap(PositionId.wrap(conditions[1]).conditionId())), 700_000);

        assertEq(combinatorial.getPayout(PositionId.wrap(yesId), 3), 1);
    }

    function test_getPayout_supportsThirteenFractionalLegs() public {
        (uint256[] memory conditions, bytes32[] memory conditionIds) = _manyBinaryYesConditions(13);
        bytes32 combinatorialConditionId = _prepareCondition(conditions);
        uint256 yesId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(1));

        _resolveMany(conditionIds, 500_000);

        assertEq(combinatorial.getPayout(PositionId.wrap(yesId), AMOUNT), AMOUNT / 8192);
        assertEq(combinatorial.getPayout(PositionId.wrap(noId), AMOUNT), AMOUNT - ((AMOUNT + 8191) / 8192));
    }

    function test_getPayout_supportsManyFullPayoutLegs() public {
        (uint256[] memory conditions, bytes32[] memory conditionIds) = _manyBinaryYesConditions(20);
        bytes32 combinatorialConditionId = _prepareCondition(conditions);
        uint256 yesId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(0));
        uint256 noId = PositionId.unwrap(ConditionIdLib.from(combinatorialConditionId).computePositionId(1));

        _resolveMany(conditionIds, RESULT_DENOMINATOR);

        assertEq(combinatorial.getPayout(PositionId.wrap(yesId), AMOUNT), AMOUNT);
        assertEq(combinatorial.getPayout(PositionId.wrap(noId), AMOUNT), 0);
    }
}

/*--------------------------------------------------------------
                    CANONICALIZATION
--------------------------------------------------------------*/

contract CombinatorialModuleTest_canonicalization is CombinatorialModuleTest {
    function test_permutationYieldsSameId() public view {
        // Regardless of input order, the canonical sort should produce the same ID
        uint256[] memory sorted = _sorted3(conditionAY, conditionBY, conditionCY);
        bytes32 id = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(sorted))));

        // The function requires canonical input, so we just verify
        // that the ID is deterministic
        bytes32 id2 = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(sorted))));
        assertEq(uint256(id), uint256(id2));
    }

    function test_revert_invalidModule() public {
        // Create a condition with moduleId=0 (invalid)
        uint256[] memory conditions = new uint256[](1);
        conditions[0] = 42; // moduleId=0

        vm.expectRevert(InvalidConditionModule.selector);
        bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));
    }

    function test_revert_invalidOutcomeIndex() public {
        // Create a condition with outcomeIndex=2
        uint256[] memory conditions = new uint256[](1);
        conditions[0] = conditionAY | 2; // outcomeIndex=2

        vm.expectRevert(InvalidOutcomeIndex.selector);
        bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));
    }
}

/*--------------------------------------------------------------
                    PATH INDEPENDENCE
--------------------------------------------------------------*/

contract CombinatorialModuleTest_pathIndependence is CombinatorialModuleTest {
    function _extractPropertyPayouts(uint256 amount, uint256 aYesPayout, uint256 bYesPayout, uint256 cYesPayout)
        internal
        returns (uint256 fullPayout, uint256 decomposedPayout)
    {
        uint256 fullNoId;
        uint256 reducedNoId;
        uint256 residualYesId;
        {
            uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
            uint256[] memory reducedConditions = _sorted2(conditionAY, conditionBY);
            uint256[] memory residualConditions = _sorted3(conditionAY, conditionBY, conditionCN);

            fullNoId = PositionId.unwrap(ConditionIdLib.from(_prepareCondition(fullConditions)).computePositionId(1));
            reducedNoId =
                PositionId.unwrap(ConditionIdLib.from(_prepareCondition(reducedConditions)).computePositionId(1));
            residualYesId =
                PositionId.unwrap(ConditionIdLib.from(_prepareCondition(residualConditions)).computePositionId(0));
        }

        _resolveFractional(condA, aYesPayout);
        _resolveFractional(condB, bYesPayout);
        _resolveFractional(condC, cYesPayout);

        fullPayout = combinatorial.getPayout(PositionId.wrap(fullNoId), amount);
        decomposedPayout = combinatorial.getPayout(PositionId.wrap(reducedNoId), amount)
            + combinatorial.getPayout(PositionId.wrap(residualYesId), amount);
    }

    function _yesBasketPropertyPayouts(uint256 amount, uint256 aYesPayout, uint256 bYesPayout, uint256 cYesPayout)
        internal
        returns (uint256 fullPayout, uint256 basketPayout)
    {
        uint256 fullNoId;
        uint256[] memory basketPositionIds;
        {
            uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
            fullNoId = PositionId.unwrap(ConditionIdLib.from(_prepareCondition(fullConditions)).computePositionId(1));
            basketPositionIds = _yesBasketIds(fullConditions);
            _prepareYesBasketConditions(fullConditions);
        }

        _resolveFractional(condA, aYesPayout);
        _resolveFractional(condB, bYesPayout);
        _resolveFractional(condC, cYesPayout);

        fullPayout = combinatorial.getPayout(PositionId.wrap(fullNoId), amount);
        basketPayout = _sumPayouts(basketPositionIds, amount);
    }

    function test_splitMergeValuePreservation() public {
        // Split from collateral, then split on condition, then merge on condition,
        // then merge to collateral. Should end with exact same collateral.
        uint256[] memory abConditions = _sorted2(conditionAY, conditionBY);
        _dealCollateral(alice, AMOUNT);

        vm.startPrank(alice);
        collateral.token.transfer(address(combinatorial), AMOUNT);
        positions.manager.setApprovalForAll(address(combinatorial), true);

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        // Split collateral -> YES(A^B) + NO(A^B)
        bytes32 abCid = _prepareCondition(abConditions);
        combinatorial.split(to, ConditionIdLib.from(abCid), AMOUNT);

        // Refine YES(A^B) on C -> YES(A^B^Y(C)) + YES(A^B^N(C))
        uint256 abYesId = PositionId.unwrap(ConditionIdLib.from(abCid).computePositionId(0));

        positions.manager.safeTransferFrom(alice, address(combinatorial), abYesId, AMOUNT, "");
        combinatorial.splitOnCondition(to, PositionId.wrap(abYesId), ConditionIdLib.from(condC), AMOUNT);

        // Merge children back -> YES(A^B)
        uint256[] memory abcYesConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        uint256[] memory abcNoConditions = _sorted3(conditionAY, conditionBY, conditionCN);
        uint256 childYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(abcYesConditions)).computePositionId(0));
        uint256 childNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(abcNoConditions)).computePositionId(0));

        positions.manager.safeTransferFrom(alice, address(combinatorial), childYesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), childNoId, AMOUNT, "");
        combinatorial.mergeOnCondition(alice, PositionId.wrap(abYesId), ConditionIdLib.from(condC), AMOUNT);

        // Merge YES(A^B) + NO(A^B) -> collateral
        uint256 abNoId = PositionId.unwrap(ConditionIdLib.from(abCid).computePositionId(1));
        positions.manager.safeTransferFrom(alice, address(combinatorial), abYesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), abNoId, AMOUNT, "");
        combinatorial.merge(alice, ConditionIdLib.from(abCid), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice), AMOUNT);
    }

    function test_extractInjectRoundtrip() public {
        uint256[] memory conditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(conditions, AMOUNT);

        uint256 cIdx = _indexOf(conditions, conditionCY);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);

        // Extract C
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        combinatorial.extract(to, PositionId.wrap(fullNoId), cIdx, AMOUNT);

        // Inject C back
        uint256[] memory reducedConditions = _sorted2(conditionAY, conditionBY);
        uint256[] memory residualConditions = _sorted3(conditionAY, conditionBY, conditionCN);
        uint256 reducedNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(reducedConditions)).computePositionId(1));
        uint256 residualYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(residualConditions)).computePositionId(0));

        positions.manager.safeTransferFrom(alice, address(combinatorial), reducedNoId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), residualYesId, AMOUNT, "");
        combinatorial.inject(alice, PositionId.wrap(fullNoId), cIdx, AMOUNT);
        vm.stopPrank();

        assertEq(positions.manager.balanceOf(alice, fullNoId), AMOUNT);
    }

    function test_extractPayoutIdentity_boolean() public {
        uint256 amount = 9;
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        uint256[] memory reducedConditions = _sorted2(conditionAY, conditionBY);
        uint256[] memory residualConditions = _sorted3(conditionAY, conditionBY, conditionCN);

        bytes32 fullConditionId = _prepareCondition(fullConditions);
        bytes32 reducedConditionId = _prepareCondition(reducedConditions);
        bytes32 residualConditionId = _prepareCondition(residualConditions);

        uint256 fullNoId = PositionId.unwrap(ConditionIdLib.from(fullConditionId).computePositionId(1));
        uint256 reducedNoId = PositionId.unwrap(ConditionIdLib.from(reducedConditionId).computePositionId(1));
        uint256 residualYesId = PositionId.unwrap(ConditionIdLib.from(residualConditionId).computePositionId(0));

        _resolve(condA, true);
        _resolve(condB, true);
        _resolve(condC, false);

        uint256 fullPayout = combinatorial.getPayout(PositionId.wrap(fullNoId), amount);
        uint256 decomposedPayout = combinatorial.getPayout(PositionId.wrap(reducedNoId), amount)
            + combinatorial.getPayout(PositionId.wrap(residualYesId), amount);

        assertEq(fullPayout, decomposedPayout);
    }

    function test_extractPayoutWeakInequality_fractional() public {
        uint256 amount = 9;
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        uint256[] memory reducedConditions = _sorted2(conditionAY, conditionBY);
        uint256[] memory residualConditions = _sorted3(conditionAY, conditionBY, conditionCN);

        bytes32 fullConditionId = _prepareCondition(fullConditions);
        bytes32 reducedConditionId = _prepareCondition(reducedConditions);
        bytes32 residualConditionId = _prepareCondition(residualConditions);

        uint256 fullNoId = PositionId.unwrap(ConditionIdLib.from(fullConditionId).computePositionId(1));
        uint256 reducedNoId = PositionId.unwrap(ConditionIdLib.from(reducedConditionId).computePositionId(1));
        uint256 residualYesId = PositionId.unwrap(ConditionIdLib.from(residualConditionId).computePositionId(0));

        _resolveFractional(condA, 700_000);
        _resolveFractional(condB, 500_000);
        _resolveFractional(condC, 500_000);

        uint256 fullPayout = combinatorial.getPayout(PositionId.wrap(fullNoId), amount);
        uint256 decomposedPayout = combinatorial.getPayout(PositionId.wrap(reducedNoId), amount)
            + combinatorial.getPayout(PositionId.wrap(residualYesId), amount);

        assertLt(decomposedPayout, fullPayout);
    }

    function testFuzz_extractPayoutProperty(
        uint96 _amountRaw,
        uint256 _aYesPayoutRaw,
        uint256 _bYesPayoutRaw,
        uint256 _cYesPayoutRaw
    ) public {
        uint256 amount = bound(uint256(_amountRaw), 1, 1_000_000e6);
        uint256 aYesPayout = bound(_aYesPayoutRaw, 0, RESULT_DENOMINATOR);
        uint256 bYesPayout = bound(_bYesPayoutRaw, 0, RESULT_DENOMINATOR);
        uint256 cYesPayout = bound(_cYesPayoutRaw, 0, RESULT_DENOMINATOR);
        (uint256 fullPayout, uint256 decomposedPayout) =
            _extractPropertyPayouts(amount, aYesPayout, bYesPayout, cYesPayout);

        if (_isBinaryPayout(aYesPayout) && _isBinaryPayout(bYesPayout) && _isBinaryPayout(cYesPayout)) {
            assertEq(decomposedPayout, fullPayout);
        } else {
            assertLe(decomposedPayout, fullPayout);
        }
    }

    function test_collateralReturnViaPartialPeel() public {
        // Portfolio: NO(A^B^C) + NO(A^N(B)^D)
        // Show that via local operations we can recover collateral
        // using the strategy from spec section 15.7

        uint256[] memory abcConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        uint256[] memory aNbdConditions = _sorted3(conditionAY, conditionBN, conditionDY);

        // Split to get both NO positions
        (, uint256 abcNoId) = _splitForAlice(abcConditions, AMOUNT);
        (, uint256 aNbdNoId) = _splitForAlice(aNbdConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        // Step 1: NO(A^B^C) -> NO(A^B) + YES(A^B^N(C))
        uint256 cIdx;
        for (uint256 i; i < abcConditions.length; ++i) {
            if (abcConditions[i] == conditionCY) {
                cIdx = i;
                break;
            }
        }
        positions.manager.safeTransferFrom(alice, address(combinatorial), abcNoId, AMOUNT, "");
        combinatorial.extract(to, PositionId.wrap(abcNoId), cIdx, AMOUNT);

        // Step 2: NO(A^N(B)^D) -> NO(A^N(B)) + YES(A^N(B)^N(D))
        uint256 dIdx;
        for (uint256 i; i < aNbdConditions.length; ++i) {
            if (aNbdConditions[i] == conditionDY) {
                dIdx = i;
                break;
            }
        }
        uint256 aNbdNoIdBal = positions.manager.balanceOf(alice, aNbdNoId);
        assertEq(aNbdNoIdBal, AMOUNT);
        positions.manager.safeTransferFrom(alice, address(combinatorial), aNbdNoId, AMOUNT, "");
        combinatorial.extract(to, PositionId.wrap(aNbdNoId), dIdx, AMOUNT);

        // Step 3: NO(A^B) -> NO(A) + YES(A^N(B))
        uint256[] memory abConditions = _sorted2(conditionAY, conditionBY);
        uint256 bIdx;
        for (uint256 i; i < abConditions.length; ++i) {
            if (abConditions[i] == conditionBY) {
                bIdx = i;
                break;
            }
        }
        uint256 abNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(abConditions)).computePositionId(1));
        positions.manager.safeTransferFrom(alice, address(combinatorial), abNoId, AMOUNT, "");
        combinatorial.extract(to, PositionId.wrap(abNoId), bIdx, AMOUNT);

        // Step 4: NO(A^N(B)) -> NO(A) + YES(A^B)
        uint256[] memory aNbConditions = _sorted2(conditionAY, conditionBN);
        uint256 nbIdx;
        for (uint256 i; i < aNbConditions.length; ++i) {
            if (aNbConditions[i] == conditionBN) {
                nbIdx = i;
                break;
            }
        }
        uint256 aNbNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(aNbConditions)).computePositionId(1));
        positions.manager.safeTransferFrom(alice, address(combinatorial), aNbNoId, AMOUNT, "");
        combinatorial.extract(to, PositionId.wrap(aNbNoId), nbIdx, AMOUNT);

        // Step 5: YES(A^N(B)) + YES(A^B) -> merge on condition B back to YES(A)
        // First check we have both
        uint256[] memory aConditions = _singleCondition(conditionAY);
        uint256[] memory aNbYesConditions = _sorted2(conditionAY, conditionBN);
        uint256[] memory abYesConditions = _sorted2(conditionAY, conditionBY);
        bytes32 aCid = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(aConditions))));
        uint256 aYesId = PositionId.unwrap(ConditionIdLib.from(aCid).computePositionId(0));
        uint256 aNbYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(aNbYesConditions)).computePositionId(0));
        uint256 abYesId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(abYesConditions)).computePositionId(0));

        assertGt(positions.manager.balanceOf(alice, aNbYesId), 0);
        assertGt(positions.manager.balanceOf(alice, abYesId), 0);

        positions.manager.safeTransferFrom(alice, address(combinatorial), aNbYesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), abYesId, AMOUNT, "");
        combinatorial.mergeOnCondition(alice, PositionId.wrap(aYesId), ConditionIdLib.from(condB), AMOUNT);

        // Step 6: YES(A) + NO(A) -> merge to collateral
        // We have 2x NO(A) from steps 3 and 4, and 1x YES(A) from step 5
        uint256 aNoId = PositionId.unwrap(ConditionIdLib.from(aCid).computePositionId(1));

        assertEq(positions.manager.balanceOf(alice, aYesId), AMOUNT);
        assertEq(positions.manager.balanceOf(alice, aNoId), 2 * AMOUNT);

        positions.manager.safeTransferFrom(alice, address(combinatorial), aYesId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), aNoId, AMOUNT, "");
        combinatorial.merge(alice, ConditionIdLib.from(aCid), AMOUNT);
        vm.stopPrank();

        // Recovered 1x AMOUNT collateral from the partial decomposition
        assertEq(collateral.token.balanceOf(alice), AMOUNT);
        // Still have 1x NO(A) left over, plus the YES residuals from steps 1 and 2
        assertEq(positions.manager.balanceOf(alice, aNoId), AMOUNT);
    }

    function test_convertToYesBasket_matches_repeatedExtract() public {
        uint256[] memory conditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(conditions, 2 * AMOUNT);
        uint256[] memory basketYesIds = _yesBasketIds(conditions);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);

        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");
        address[] memory basketRecipients = new address[](3);
        basketRecipients[0] = alice;
        basketRecipients[1] = alice;
        basketRecipients[2] = alice;
        combinatorial.convertToYesBasket(basketRecipients, PositionId.wrap(fullNoId), AMOUNT);

        uint256[] memory currentConditions = conditions;
        while (currentConditions.length > 1) {
            uint256 currentNoId = PositionId.unwrap(
                combinatorial.getConditionId(_positionIds(currentConditions)).computePositionId(1)
            );

            positions.manager.safeTransferFrom(alice, address(combinatorial), currentNoId, AMOUNT, "");

            address[] memory to = new address[](2);
            to[0] = alice;
            to[1] = alice;
            combinatorial.extract(to, PositionId.wrap(currentNoId), currentConditions.length - 1, AMOUNT);

            currentConditions = _removeLast(currentConditions);
        }

        uint256 finalNoId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(currentConditions)).computePositionId(1));
        positions.manager.safeTransferFrom(alice, address(combinatorial), finalNoId, AMOUNT, "");

        address[] memory finalRecipient = new address[](1);
        finalRecipient[0] = alice;
        combinatorial.convertToYesBasket(finalRecipient, PositionId.wrap(finalNoId), AMOUNT);
        vm.stopPrank();

        for (uint256 i; i < basketYesIds.length; ++i) {
            assertEq(positions.manager.balanceOf(alice, basketYesIds[i]), 2 * AMOUNT);
        }
    }

    function test_yesBasketPayoutIdentity_boolean() public {
        uint256 amount = 9;
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        bytes32 fullConditionId = _prepareCondition(fullConditions);
        uint256 fullNoId = PositionId.unwrap(ConditionIdLib.from(fullConditionId).computePositionId(1));

        uint256[] memory basketPositionIds = _yesBasketIds(fullConditions);
        _prepareYesBasketConditions(fullConditions);

        _resolve(condA, true);
        _resolve(condB, true);
        _resolve(condC, false);

        uint256 fullPayout = combinatorial.getPayout(PositionId.wrap(fullNoId), amount);
        uint256 basketPayout = _sumPayouts(basketPositionIds, amount);

        assertEq(fullPayout, basketPayout);
    }

    function test_yesBasketPayoutWeakInequality_fractional() public {
        uint256 amount = 9;
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        bytes32 fullConditionId = _prepareCondition(fullConditions);
        uint256 fullNoId = PositionId.unwrap(ConditionIdLib.from(fullConditionId).computePositionId(1));

        uint256[] memory basketPositionIds = _yesBasketIds(fullConditions);
        _prepareYesBasketConditions(fullConditions);

        _resolveFractional(condA, 700_000);
        _resolveFractional(condB, 500_000);
        _resolveFractional(condC, 500_000);

        uint256 fullPayout = combinatorial.getPayout(PositionId.wrap(fullNoId), amount);
        uint256 basketPayout = _sumPayouts(basketPositionIds, amount);

        assertLt(basketPayout, fullPayout);
    }

    function testFuzz_yesBasketPayoutProperty(
        uint96 _amountRaw,
        uint256 _aYesPayoutRaw,
        uint256 _bYesPayoutRaw,
        uint256 _cYesPayoutRaw
    ) public {
        uint256 amount = bound(uint256(_amountRaw), 1, 1_000_000e6);
        uint256 aYesPayout = bound(_aYesPayoutRaw, 0, RESULT_DENOMINATOR);
        uint256 bYesPayout = bound(_bYesPayoutRaw, 0, RESULT_DENOMINATOR);
        uint256 cYesPayout = bound(_cYesPayoutRaw, 0, RESULT_DENOMINATOR);
        (uint256 fullPayout, uint256 basketPayout) =
            _yesBasketPropertyPayouts(amount, aYesPayout, bYesPayout, cYesPayout);

        if (_isBinaryPayout(aYesPayout) && _isBinaryPayout(bYesPayout) && _isBinaryPayout(cYesPayout)) {
            assertEq(basketPayout, fullPayout);
        } else {
            assertLe(basketPayout, fullPayout);
        }
    }
}

/*--------------------------------------------------------------
                            GET LEGS
--------------------------------------------------------------*/

contract CombinatorialModuleTest_getLegs is CombinatorialModuleTest {
    function test_getLegs() public {
        uint256[] memory conditions = _sorted3(conditionAY, conditionBY, conditionCY);
        bytes32 combinatorialConditionId =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(conditions))));

        // Before split, no legs stored
        assertEq(_rawPositionIds(combinatorial.getLegs(ConditionIdLib.from(combinatorialConditionId))).length, 0);
        assertFalse(combinatorial.isConditionPrepared(ConditionIdLib.from(combinatorialConditionId)));

        _splitForAlice(conditions, AMOUNT);

        // After split, legs are stored and match input
        uint256[] memory stored = _rawPositionIds(combinatorial.getLegs(ConditionIdLib.from(combinatorialConditionId)));
        assertTrue(combinatorial.isConditionPrepared(ConditionIdLib.from(combinatorialConditionId)));
        assertEq(stored.length, conditions.length);
        for (uint256 i; i < conditions.length; ++i) {
            assertEq(stored[i], conditions[i]);
        }
    }
}

/*--------------------------------------------------------------
                            BRIDGE
--------------------------------------------------------------*/

contract CombinatorialModuleTest_bridge is CombinatorialModuleTest {
    // Selectors from the v1.1.1 ABI, hardcoded rather than derived from the contract so that
    // re-adding a function with the same signature is caught instead of silently satisfying them.
    bytes4 private constant _MINT_FROM_BRIDGE = bytes4(keccak256("mintFromBridge(address,uint256,uint256)"));
    bytes4 private constant _BURN_FROM_BRIDGE = bytes4(keccak256("burnFromBridge(uint256[],uint256[])"));
    bytes4 private constant _ADD_BRIDGE = bytes4(keccak256("addBridge(address)"));
    bytes4 private constant _REMOVE_BRIDGE = bytes4(keccak256("removeBridge(address)"));

    /// @dev The module declares no fallback, so an unroutable selector reverts. Asserting on the
    ///      low-level result rather than `vm.expectRevert` distinguishes "no such function" from a
    ///      function that exists and reverts for its own reasons.
    function _assertSelectorAbsent(bytes memory _callData, string memory _what) internal {
        (bool ok,) = address(combinatorial).call(_callData);
        assertFalse(ok, _what);
    }

    function _bridgeYesPositionId() internal view returns (uint256) {
        return PositionId.unwrap(ConditionIdLib.from(_getBridgeConditionId()).computePositionId(0));
    }

    /*----------------------------------------------------------
      Combinatorial positions are deliberately not bridgeable: a leg definition is per-chain state
      and the conditionId commits to it in only 128 bits, so two chains can bind different arrays
      to one id as legitimate first writes, and a position payload cannot carry enough to detect
      that. The module therefore exposes no bridge entry point at all, rather than relying on
      BridgeBase to refuse -- no transport, no mis-granted role and no future IBridge
      implementation can reach a mint that would bypass the binding invariant.
    ----------------------------------------------------------*/

    function test_mintFromBridge_removed() public {
        _assertSelectorAbsent(
            abi.encodeWithSelector(_MINT_FROM_BRIDGE, alice, _bridgeYesPositionId(), AMOUNT), "mintFromBridge routable"
        );
    }

    function test_burnFromBridge_removed() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = _bridgeYesPositionId();
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = AMOUNT;

        _assertSelectorAbsent(abi.encodeWithSelector(_BURN_FROM_BRIDGE, ids, amounts), "burnFromBridge routable");
    }

    /// @notice The role plumbing is gone too, so BRIDGE_ROLE cannot be granted on this module even
    ///         by an admin -- there is no holder for a re-added bridge entry point to authorise.
    function test_addBridge_removed() public {
        vm.startPrank(admin);
        _assertSelectorAbsent(abi.encodeWithSelector(_ADD_BRIDGE, bridge), "addBridge routable");
        _assertSelectorAbsent(abi.encodeWithSelector(_REMOVE_BRIDGE, bridge), "removeBridge routable");
        vm.stopPrank();
    }

    /// @notice No path mints a combinatorial position at an unprepared conditionId. `split` is
    ///         gated, every derivation binds, and with the bridge surface removed there is no
    ///         longer an unbinding mint at all.
    function test_noUnbindingMintPathRemains() public {
        uint256 positionId = _bridgeYesPositionId();

        assertEq(positions.manager.balanceOf(alice, positionId), 0, "no supply");
        assertEq(combinatorial.getLegs(ConditionIdLib.from(_getBridgeConditionId())).length, 0, "no definition");

        vm.prank(bridge);
        _assertSelectorAbsent(
            abi.encodeWithSelector(_MINT_FROM_BRIDGE, alice, positionId, AMOUNT), "bridge minted at unbound id"
        );

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        // Resolved before arming the cheatcode: `_getBridgeConditionId` is an external staticcall,
        // and as an inline argument it would consume the expectRevert instead of `split`.
        ConditionId conditionId = ConditionIdLib.from(_getBridgeConditionId());

        vm.prank(alice);
        vm.expectRevert(ConditionNotPrepared.selector);
        combinatorial.split(to, conditionId, AMOUNT);

        assertEq(positions.manager.balanceOf(alice, positionId), 0, "still no supply");
    }
}

/*--------------------------------------------------------------
                       ERC1155 RECEIVER
--------------------------------------------------------------*/

contract CombinatorialModuleTest_erc1155Receiver is CombinatorialModuleTest {
    /// @notice The module accepts direct position transfers, which is what the pre-transfer
    ///         pattern depends on for every split/merge/redeem entry point.
    function test_onERC1155Received_normalTransfer() public {
        (uint256 yesPositionId,) = _splitForAlice(_singleCondition(conditionAY), AMOUNT);

        vm.prank(alice);
        positions.manager.safeTransferFrom(alice, address(combinatorial), yesPositionId, AMOUNT, "");

        assertEq(positions.manager.balanceOf(alice, yesPositionId), 0);
        assertEq(positions.manager.balanceOf(address(combinatorial), yesPositionId), AMOUNT);
    }

    function test_onERC1155BatchReceived_normalTransfer() public {
        (uint256 yesPositionId, uint256 noPositionId) = _splitForAlice(_singleCondition(conditionAY), AMOUNT);

        uint256[] memory ids = new uint256[](2);
        ids[0] = yesPositionId;
        ids[1] = noPositionId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = AMOUNT;
        amounts[1] = AMOUNT;

        vm.prank(alice);
        positions.manager.safeBatchTransferFrom(alice, address(combinatorial), ids, amounts, "");

        assertEq(positions.manager.balanceOf(alice, yesPositionId), 0);
        assertEq(positions.manager.balanceOf(alice, noPositionId), 0);
        assertEq(positions.manager.balanceOf(address(combinatorial), yesPositionId), AMOUNT);
        assertEq(positions.manager.balanceOf(address(combinatorial), noPositionId), AMOUNT);
    }
}

contract CombinatorialModuleTest_initialize is CombinatorialModuleTest {
    function test_revert_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        combinatorial.initialize(owner, admin);
    }
}

/*--------------------------------------------------------------
                            UUPS
--------------------------------------------------------------*/

contract CombinatorialModuleTest_upgrade is CombinatorialModuleTest {
    function test_upgradeToAndCall_preservesState() public {
        // Prepare a condition
        uint256[] memory conds = _sorted2(conditionAY, conditionBY);
        bytes32 conditionId = bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conds))));

        // Upgrade
        address newImpl = address(new CombinatorialModule(address(positions.manager)));
        vm.prank(owner);
        combinatorial.upgradeToAndCall(newImpl, "");

        // Verify state preserved
        uint256[] memory stored = _rawPositionIds(combinatorial.getLegs(ConditionIdLib.from(conditionId)));
        assertEq(stored.length, 2);
        assertEq(stored[0], conds[0]);
        assertEq(stored[1], conds[1]);
    }

    function test_revert_upgrade_unauthorized() public {
        address newImpl = address(new CombinatorialModule(address(positions.manager)));

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        combinatorial.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_incompatibleModuleId() public {
        address newImpl = address(
            new BinaryModule(
                address(positions.manager),
                address(positions.binaryModule.CONDITIONAL_TOKENS()),
                positions.binaryModule.USDCE(),
                ResolutionChain.POLYGON
            )
        );

        vm.prank(owner);
        vm.expectRevert(CombinatorialModuleErrors.IncompatibleImplementation.selector);
        combinatorial.upgradeToAndCall(newImpl, "");
    }

    function test_revert_upgrade_incompatiblePositionManager() public {
        // Deploy a fresh PositionManager to get a different address
        (Positions memory otherPositions,,) = PositionManagerSetup._deploy(owner, admin, creator);
        address newImpl = address(new CombinatorialModule(address(otherPositions.manager)));

        vm.prank(owner);
        vm.expectRevert(CombinatorialModuleErrors.IncompatibleImplementation.selector);
        combinatorial.upgradeToAndCall(newImpl, "");
    }
}

/*--------------------------------------------------------------
                  CONDITION DEFINITION BINDING
--------------------------------------------------------------*/

contract CombinatorialModuleTest_conditionDefinitionBinding is CombinatorialModuleTest {
    /// @dev Writes `_rawLegs` directly into `legs[_conditionId]` (slot 0). Used to stage the state
    ///      a base-hash collision would produce, which cannot be reached by calling the module.
    function _plantLegs(bytes32 _conditionId, uint256[] memory _rawLegs) internal {
        bytes32 valueSlot = keccak256(abi.encode(_conditionId, uint256(0)));
        vm.store(address(combinatorial), valueSlot, bytes32(_rawLegs.length));
        bytes32 dataStart = keccak256(abi.encode(valueSlot));
        for (uint256 i; i < _rawLegs.length; ++i) {
            vm.store(address(combinatorial), bytes32(uint256(dataStart) + i), bytes32(_rawLegs[i]));
        }
    }

    /// @dev Stage `_planted` under the conditionId that `_incoming` hashes to, as a collision would.
    function _plantCollision(uint256[] memory _incoming, uint256[] memory _planted)
        internal
        returns (bytes32 conditionId)
    {
        conditionId = bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(_incoming))));
        _plantLegs(conditionId, _planted);

        // Confirm the staging landed where the module reads from.
        assertEq(combinatorial.getLegs(ConditionIdLib.from(conditionId)).length, _planted.length);
    }

    function test_prepareCondition_idempotentForSameDefinition() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        bytes32 conditionId = _prepareCondition(conditions);

        // Re-preparing the same definition stays a no-op rather than reverting.
        bytes32 repeated = _prepareCondition(conditions);

        assertEq(repeated, conditionId);
        PositionId[] memory stored = combinatorial.getLegs(ConditionIdLib.from(conditionId));
        assertEq(stored.length, 2);
        assertEq(PositionId.unwrap(stored[0]), conditions[0]);
        assertEq(PositionId.unwrap(stored[1]), conditions[1]);
    }

    function test_revert_prepareConditionCollidingDefinition() public {
        uint256[] memory incoming = _sorted2(conditionAY, conditionBY);
        uint256[] memory planted = _sorted2(conditionCY, conditionDY);
        _plantCollision(incoming, planted);

        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.prepareCondition(_positionIds(incoming));
    }

    function test_revert_prepareConditionCollidingDefinitionOfDifferentLength() public {
        uint256[] memory incoming = _sorted2(conditionAY, conditionBY);
        _plantCollision(incoming, _singleCondition(conditionCY));

        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.prepareCondition(_positionIds(incoming));
    }

    /// @notice A definition staged before this module existed still binds: re-preparing the exact
    ///         same legs is accepted, so conditions stored by an earlier implementation keep working.
    function test_prepareCondition_acceptsPreexistingIdenticalDefinition() public {
        uint256[] memory conditions = _sorted2(conditionAY, conditionBY);
        bytes32 conditionId = _plantCollision(conditions, conditions);

        bytes32 returned = bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));

        assertEq(returned, conditionId);
    }

    /// @notice The exploit path: a colliding all-winning definition staged at the derived child
    ///         conditionId must not be minted to the splitter.
    function test_revert_splitOnConditionAdoptsCollidingChildDefinition() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);

        // Stage a different, fully-winning definition under the child YES conditionId.
        uint256[] memory childYesConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        _plantCollision(childYesConditions, _singleCondition(conditionDY));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");

        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;

        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.splitOnCondition(to, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
        vm.stopPrank();
    }

    /// @notice Same for the wrap path, which stores a single-leg definition.
    function test_revert_wrapAdoptsCollidingDefinition() public {
        uint256[] memory wrapped = _singleCondition(conditionAY);
        _plantCollision(wrapped, _singleCondition(conditionDY));

        _dealCollateral(alice, AMOUNT);
        vm.startPrank(alice);
        collateral.token.transfer(address(positions.binaryModule), AMOUNT);
        address[] memory to = new address[](2);
        to[0] = alice;
        to[1] = alice;
        positions.binaryModule.split(to, ConditionIdLib.from(condA), AMOUNT);

        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), conditionAY, AMOUNT, "");

        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.wrap(alice, PositionId.wrap(conditionAY), AMOUNT);
        vm.stopPrank();
    }
    /*----------------------------------------------------------
      Inverse operations derive child conditionIds and commit them via `_storeLegsFromMemory`,
      so the write-path guard runs for them too. They must also refuse to consume positions at
      a conditionId whose stored definition is a different basket.
    ----------------------------------------------------------*/

    function test_revert_mergeOnConditionAdoptsCollidingChildDefinition() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        (uint256 parentYesId,) = _splitForAlice(parentConditions, AMOUNT);

        // Stage a different definition under the derived child YES conditionId.
        _plantCollision(_sorted3(conditionAY, conditionBY, conditionCY), _singleCondition(conditionDY));

        vm.prank(alice);
        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.mergeOnCondition(alice, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
    }

    function test_revert_injectAdoptsCollidingReducedDefinition() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);
        uint256 cIdx = _indexOf(fullConditions, conditionCY);

        // inject derives the reduced basket (full minus the extracted leg); stage a collision there.
        _plantCollision(_sorted2(conditionAY, conditionBY), _singleCondition(conditionDY));

        vm.prank(alice);
        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.inject(alice, PositionId.wrap(fullNoId), cIdx, AMOUNT);
    }

    function test_revert_mergeFromYesBasketAdoptsCollidingBasketDefinition() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        // The first basket definition is [flip(fullLegs[0])]; stage a collision under its id.
        _plantCollision(_singleCondition(fullConditions[0] ^ 1), _singleCondition(conditionDY));

        vm.prank(alice);
        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.mergeFromYesBasket(alice, PositionId.wrap(fullNoId), AMOUNT);
    }

    /// @notice Finding #742's literal PoC path. Plant a valuable definition under a basket
    ///         conditionId that `convertToYesBasket` derives, then feed the module a worthless NO
    ///         and try to have it mint YES at that id. The derived basket must bind to its own
    ///         definition rather than adopt the planted one.
    function test_revert_convertToYesBasketAdoptsCollidingBasketDefinition() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        // The first basket definition is [flip(fullLegs[0])]; stage a collision under its id.
        _plantCollision(_singleCondition(fullConditions[0] ^ 1), _singleCondition(conditionDY));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](3);
        to[0] = alice;
        to[1] = alice;
        to[2] = alice;

        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();
    }

    /// @notice The guard covers every basket prefix, not just the first: a collision staged under
    ///         the *last* prefix still aborts the whole conversion.
    function test_revert_convertToYesBasketAdoptsCollidingLaterBasketDefinition() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        // The last basket definition is [fullLegs[0], fullLegs[1], flip(fullLegs[2])]. Flipping the
        // largest leg only sets its outcome bit, so the array stays canonically ordered.
        uint256[] memory lastBasket = new uint256[](3);
        lastBasket[0] = fullConditions[0];
        lastBasket[1] = fullConditions[1];
        lastBasket[2] = fullConditions[2] ^ 1;
        _plantCollision(lastBasket, _singleCondition(conditionDY));

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](3);
        to[0] = alice;
        to[1] = alice;
        to[2] = alice;

        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();
    }

    /// @notice Success-path coverage for the basket prefixes: a conversion that completes leaves
    ///         prefix i bound to exactly [fullLegs[0..i-1], flip(fullLegs[i])], with the basket YES
    ///         minted at that id -- so each one is operable straight away. Exercises the flip and
    ///         the memory-length juggling in _prepareYesBasketPositionIds, which nothing else does
    ///         on a call that succeeds.
    /// @dev    No bind/mint ordering is asserted, deliberately. `PositionManager.mint` is a raw
    ///         balance bump with no receiver hook, so bind-all-then-mint and an interleaved bind
    ///         are indistinguishable by end state. Ordering only becomes load-bearing if the mint
    ///         path ever gains a callout.
    function test_convertToYesBasketBindsEveryPrefix() public {
        uint256[] memory fullConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        (, uint256 fullNoId) = _splitForAlice(fullConditions, AMOUNT);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), fullNoId, AMOUNT, "");

        address[] memory to = new address[](3);
        to[0] = alice;
        to[1] = alice;
        to[2] = alice;
        combinatorial.convertToYesBasket(to, PositionId.wrap(fullNoId), AMOUNT);
        vm.stopPrank();

        // Prefix i is [fullLegs[0..i-1], flip(fullLegs[i])].
        for (uint256 i; i < 3; ++i) {
            uint256[] memory prefix = new uint256[](i + 1);
            for (uint256 j; j < i; ++j) {
                prefix[j] = fullConditions[j];
            }
            prefix[i] = fullConditions[i] ^ 1;

            ConditionId prefixId = combinatorial.getConditionId(_positionIds(prefix));
            assertEq(_rawPositionIds(combinatorial.getLegs(prefixId)), prefix, "prefix bound to its own array");
            assertEq(
                positions.manager.balanceOf(alice, PositionId.unwrap(prefixId.computePositionId(0))),
                AMOUNT,
                "basket YES minted at the bound id"
            );
        }
    }

    /// @notice A derived conditionId must be bound at the moment an inverse op consumes positions
    ///         at it. Otherwise: legacy supply at an unprepared derived child id lets the inverse
    ///         op consume only the YES side, then plant a colliding all-losing definition so the
    ///         leftover NO redeems for full collateral -- an unbacked mint with no capital at risk.
    function test_inverseOpBindsDerivedDefinition() public {
        uint256[] memory parentConditions = _sorted2(conditionAY, conditionBY);
        bytes32 parentConditionId = _prepareCondition(parentConditions);
        uint256 parentYesId = PositionId.unwrap(ConditionIdLib.from(parentConditionId).computePositionId(0));

        // Legacy outstanding positions at both derived child ids while their definitions are still unstored.
        uint256[] memory childYesConditions = _sorted3(conditionAY, conditionBY, conditionCY);
        uint256[] memory childNoConditions = _sorted3(conditionAY, conditionBY, conditionCN);
        (uint256 childYesPositionId,) = _mintLegacyUnpreparedPairForAlice(childYesConditions, AMOUNT);
        (uint256 childNoPositionId,) = _mintLegacyUnpreparedPairForAlice(childNoConditions, AMOUNT);

        ConditionId childYesConditionId = combinatorial.getConditionId(_positionIds(childYesConditions));
        ConditionId childNoConditionId = combinatorial.getConditionId(_positionIds(childNoConditions));
        assertFalse(combinatorial.isConditionPrepared(childYesConditionId), "child yes unprepared");
        assertFalse(combinatorial.isConditionPrepared(childNoConditionId), "child no unprepared");

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), childYesPositionId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), childNoPositionId, AMOUNT, "");
        combinatorial.mergeOnCondition(alice, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
        vm.stopPrank();

        // Both derived definitions must now be committed, so no colliding array can be planted later.
        assertTrue(combinatorial.isConditionPrepared(childYesConditionId), "child yes bound by merge");
        assertTrue(combinatorial.isConditionPrepared(childNoConditionId), "child no bound by merge");

        PositionId[] memory storedYes = combinatorial.getLegs(childYesConditionId);
        assertEq(storedYes.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(PositionId.unwrap(storedYes[i]), childYesConditions[i]);
        }
    }

    /// @notice `mergeOnEvent` derives one child per event outcome. Completes the inverse-op set:
    ///         the other three each have a staged-collision case above.
    function test_revert_mergeOnEventAdoptsCollidingChildDefinition() public {
        EventId eventId = positions.negRiskModule.getEventId(3, "merge-on-event-collision");
        (uint256 parentYesId,) = _splitForAlice(_singleCondition(conditionAY), AMOUNT);

        // Stage a collision under the first derived child, which the loop reaches before any mint.
        uint256 eventYesId = PositionId.unwrap(eventId.computeConditionId(0).computePositionId(0));
        _plantCollision(_sorted2(conditionAY, eventYesId), _singleCondition(conditionDY));

        vm.prank(alice);
        vm.expectRevert(ConditionDefinitionMismatch.selector);
        combinatorial.mergeOnEvent(alice, PositionId.wrap(parentYesId), eventId, AMOUNT);
    }

    /// @notice The economic invariant behind binding at consumption time, rather than merely
    ///         comparing when a definition happens to be present: once an inverse op consumes one
    ///         side of a derived conditionId, the *other* side must already be priceable. If the
    ///         id were left unbound the leftover NO could be retro-priced by a colliding
    ///         definition planted afterwards, turning a break-even sequence into an unbacked mint.
    ///         Compare-only binding fails this test -- `getPayout` on the leftover NO reverts
    ///         `ConditionNotPrepared` because nothing was committed.
    function test_inverseOpPricesUnconsumedSideImmediately() public {
        _resolve(condA, true);
        _resolve(condC, true);

        bytes32 parentConditionId = _prepareCondition(_singleCondition(conditionAY));
        uint256 parentYesId = PositionId.unwrap(ConditionIdLib.from(parentConditionId).computePositionId(0));

        // Legacy outstanding positions at both derived child ids while their definitions are still unstored.
        uint256[] memory childYesConditions = _sorted2(conditionAY, conditionCY);
        uint256[] memory childNoConditions = _sorted2(conditionAY, conditionCN);
        (uint256 childYesPositionId, uint256 childYesNoId) =
            _mintLegacyUnpreparedPairForAlice(childYesConditions, AMOUNT);
        (uint256 childNoPositionId, uint256 childNoNoId) = _mintLegacyUnpreparedPairForAlice(childNoConditions, AMOUNT);

        uint256 committed = 2 * AMOUNT; // collateral burned when simulating the two legacy pairs
        uint256 balanceBefore = collateral.token.balanceOf(alice);

        vm.startPrank(alice);
        positions.manager.setApprovalForAll(address(combinatorial), true);
        positions.manager.safeTransferFrom(alice, address(combinatorial), childYesPositionId, AMOUNT, "");
        positions.manager.safeTransferFrom(alice, address(combinatorial), childNoPositionId, AMOUNT, "");
        combinatorial.mergeOnCondition(alice, PositionId.wrap(parentYesId), ConditionIdLib.from(condC), AMOUNT);
        vm.stopPrank();

        // The leftover NO sides are priceable right away, at their true value under the derived
        // definitions. [A_yes, C_yes] both win so its NO is worth zero; [A_yes, C_no] is false so
        // its NO is worth the full amount. Neither can be repriced later.
        assertEq(combinatorial.getPayout(PositionId.wrap(childYesNoId), AMOUNT), 0, "NO(childYes) priced at zero");
        assertEq(combinatorial.getPayout(PositionId.wrap(childNoNoId), AMOUNT), AMOUNT, "NO(childNo) priced at full");

        // Redeeming everything returns exactly what was committed: the sequence is break-even.
        vm.startPrank(alice);
        positions.manager.safeTransferFrom(alice, address(combinatorial), childNoNoId, AMOUNT, "");
        combinatorial.redeem(alice, PositionId.wrap(childNoNoId), AMOUNT);
        positions.manager.safeTransferFrom(alice, address(combinatorial), parentYesId, AMOUNT, "");
        combinatorial.redeem(alice, PositionId.wrap(parentYesId), AMOUNT);
        vm.stopPrank();

        assertEq(collateral.token.balanceOf(alice) - balanceBefore, committed, "no value created");
    }
}

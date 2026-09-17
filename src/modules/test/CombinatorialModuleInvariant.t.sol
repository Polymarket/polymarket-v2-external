// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";
import { FixedPointMathLib } from "@solady/src/utils/FixedPointMathLib.sol";
import { Vm } from "lib/forge-std/src/Vm.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { Collateral } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { ConditionId, ConditionIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import {
    Positions,
    Legacy,
    PositionManagerSetup
} from "@polymarket-v2/src/positionManager/dev/PositionManagerSetup.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

contract CombinatorialValueHandler is TestHelper {
    uint256 internal constant RESULT_DENOMINATOR = 1_000_000;
    uint256 internal constant PAYOUT_FACTOR_DENOMINATOR = 1e36;
    uint256 internal constant MAX_MARKETS = 4;
    uint256 internal constant MAX_SLOTS = 192;
    uint256 internal constant MAX_SEEN = 192;
    uint256 internal constant MAX_OPEN_AMOUNT = 1_000_000e6;
    uint256 internal constant _OUTCOME_MASK = 0xFF;
    uint256 internal constant _CONDITION_MASK = ~uint256(0xFF);

    bytes32 internal constant COMPRESSED_TOPIC =
        keccak256("Compressed(address,uint256,uint256,address,uint256,uint256,uint256)");

    struct Slot {
        uint256 positionId;
        uint256 amount;
    }

    CombinatorialModule public immutable combinatorial;
    PositionManager public immutable positionManager;
    CollateralToken public immutable collateralToken;
    address public immutable binaryModule;
    address public immutable resolver;

    bytes32[MAX_MARKETS] public conditionIds;
    bool[MAX_MARKETS] public resolved;
    uint256 public resolvedCount;
    uint256 public initialCollateral;

    Slot[MAX_SLOTS] public slots;
    uint256 public activeSlots;
    uint256[MAX_SEEN] public seenPositionIds;
    uint256 public seenCount;

    constructor(
        CombinatorialModule _combinatorial,
        Positions memory _positions,
        Collateral memory _collateral,
        address _resolver
    ) {
        combinatorial = _combinatorial;
        positionManager = _positions.manager;
        collateralToken = _collateral.token;
        binaryModule = _positions.manager.moduleById(ModuleIds.BINARY);
        resolver = _resolver;

        conditionIds[0] = bytes32(ConditionId.unwrap(_positions.binaryModule.getConditionId("invariant A")));
        conditionIds[1] = bytes32(ConditionId.unwrap(_positions.binaryModule.getConditionId("invariant B")));
        conditionIds[2] = bytes32(ConditionId.unwrap(_positions.binaryModule.getConditionId("invariant C")));
        conditionIds[3] = bytes32(ConditionId.unwrap(_positions.binaryModule.getConditionId("invariant D")));
    }

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

    function open(uint256 maskSeed, uint256 outcomeSeed, uint256 amountSeed) external {
        if (activeSlots > MAX_SLOTS - 2) return;

        uint256 amount = bound(amountSeed, 1, MAX_OPEN_AMOUNT);
        uint256[] memory conditions = _conditionsFromSeed(maskSeed);
        bytes32 conditionId = bytes32(ConditionId.unwrap(combinatorial.prepareCondition(_positionIds(conditions))));

        vm.prank(address(combinatorial));
        collateralToken.mint(address(this), amount);
        collateralToken.transfer(address(combinatorial), amount);

        address[] memory to = new address[](2);
        to[0] = address(this);
        to[1] = address(this);
        combinatorial.split(to, ConditionIdLib.from(conditionId), amount);

        uint256 yesPositionId = PositionId.unwrap(ConditionIdLib.from(conditionId).computePositionId(0));
        uint256 noPositionId = PositionId.unwrap(ConditionIdLib.from(conditionId).computePositionId(1));
        initialCollateral += amount;

        if (outcomeSeed & 1 == 0) {
            _addSlot(yesPositionId, amount);
            _addSlot(noPositionId, amount);
        } else {
            _addSlot(noPositionId, amount);
            _addSlot(yesPositionId, amount);
        }
    }

    function openUnderlying(uint256 marketSeed, uint256 amountSeed) external {
        if (activeSlots > MAX_SLOTS - 2) return;

        uint256 market = bound(marketSeed, 0, MAX_MARKETS - 1);
        uint256 amount = bound(amountSeed, 1, MAX_OPEN_AMOUNT);
        bytes32 conditionId = conditionIds[market];

        vm.prank(binaryModule);
        collateralToken.mint(address(this), amount);
        collateralToken.transfer(binaryModule, amount);

        address[] memory to = new address[](2);
        to[0] = address(this);
        to[1] = address(this);
        BaseModule(binaryModule).split(to, ConditionIdLib.from(conditionId), amount);

        initialCollateral += amount;
        _addSlot(PositionId.unwrap(ConditionIdLib.from(conditionId).computePositionId(0)), amount);
        _addSlot(PositionId.unwrap(ConditionIdLib.from(conditionId).computePositionId(1)), amount);
    }

    function resolve(uint256 marketSeed, uint256 yesPayoutSeed) external {
        uint256 market = bound(marketSeed, 0, MAX_MARKETS - 1);
        if (resolved[market]) return;

        uint256 yesPayout = bound(yesPayoutSeed, 0, RESULT_DENOMINATOR);
        uint256[] memory result = new uint256[](2);
        result[0] = yesPayout;
        result[1] = RESULT_DENOMINATOR - yesPayout;

        address binaryModule = positionManager.moduleById(ModuleIds.BINARY);
        vm.prank(resolver);
        BaseModule(binaryModule).reportResult(ConditionIdLib.from(conditionIds[market]), result);

        resolved[market] = true;
        resolvedCount++;
    }

    function resolveAll(uint256 yesPayoutSeed) external {
        for (uint256 market; market < MAX_MARKETS; ++market) {
            if (resolved[market]) continue;

            uint256 yesPayout = uint256(keccak256(abi.encode(yesPayoutSeed, market))) % (RESULT_DENOMINATOR + 1);
            uint256[] memory result = new uint256[](2);
            result[0] = yesPayout;
            result[1] = RESULT_DENOMINATOR - yesPayout;

            vm.prank(resolver);
            BaseModule(binaryModule).reportResult(ConditionIdLib.from(conditionIds[market]), result);

            resolved[market] = true;
            resolvedCount++;
        }
    }

    function compress(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _slotIndex(slotSeed);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        uint256 amount = bound(amountSeed, 1, slot.amount);
        (bool compressible, uint256 expectedNewPositionId) = _previewCompress(slot.positionId, amount);
        if (!compressible) return;
        if (expectedNewPositionId != 0 && !_hasSlot(expectedNewPositionId) && activeSlots == MAX_SLOTS) return;

        vm.recordLogs();
        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");
        combinatorial.compress(address(this), PositionId.wrap(slot.positionId), amount);
        uint256 newPositionId = _compressedNewPositionId(vm.getRecordedLogs());

        _removeFromSlot(slotIndex, amount);

        if (newPositionId != 0) {
            uint256 moduleBalance = positionManager.balanceOf(address(this), newPositionId);
            uint256 trackedBalance = _trackedBalance(newPositionId);
            if (moduleBalance > trackedBalance) _addSlot(newPositionId, moduleBalance - trackedBalance);
        }
    }

    function redeem(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _combinatorialSlotIndex(slotSeed, 2, 1, MAX_MARKETS);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        if (!_isRedeemable(slot.positionId)) return;

        uint256 amount = bound(amountSeed, 1, slot.amount);
        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");
        combinatorial.redeem(address(this), PositionId.wrap(slot.positionId), amount);

        _removeFromSlot(slotIndex, amount);
    }

    function merge(uint256 firstSlotSeed, uint256 secondSlotSeed, uint256 amountSeed) external {
        uint256 first = _combinatorialSlotIndex(firstSlotSeed, 2, 1, MAX_MARKETS);
        uint256 second = _combinatorialSlotIndex(secondSlotSeed, 2, 1, MAX_MARKETS);
        if (first == type(uint256).max || second == type(uint256).max || first == second) return;

        uint256 firstPositionId = slots[first].positionId;
        uint256 secondPositionId = slots[second].positionId;
        bytes32 firstConditionId = bytes32(ConditionId.unwrap(PositionId.wrap(firstPositionId).conditionId()));
        if (firstConditionId != bytes32(ConditionId.unwrap(PositionId.wrap(secondPositionId).conditionId()))) return;
        if ((PositionId.wrap(firstPositionId).outcomeIndex() ^ PositionId.wrap(secondPositionId).outcomeIndex()) != 1) {
            return;
        }

        uint256 amount = slots[first].amount < slots[second].amount ? slots[first].amount : slots[second].amount;
        amount = bound(amountSeed, 1, amount);

        positionManager.safeTransferFrom(address(this), address(combinatorial), firstPositionId, amount, "");
        positionManager.safeTransferFrom(address(this), address(combinatorial), secondPositionId, amount, "");
        combinatorial.merge(address(this), ConditionIdLib.from(firstConditionId), amount);

        _removeFromSlot(first, amount);
        _removeFromSlot(second, amount);
    }

    function splitOnCondition(uint256 slotSeed, uint256 marketSeed, uint256 amountSeed) external {
        uint256 slotIndex = _combinatorialSlotIndex(slotSeed, 0, 1, MAX_MARKETS - 1);
        if (slotIndex == type(uint256).max || activeSlots > MAX_SLOTS - 2) return;

        Slot memory slot = slots[slotIndex];
        uint256[] memory parentConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slot.positionId).conditionId())))
            )
        );
        bytes32 conditionId = _availableConditionReference(parentConditions, marketSeed);
        if (conditionId == bytes32(0)) return;

        uint256 amount = bound(amountSeed, 1, slot.amount);
        uint256 childYesPositionId = PositionId.unwrap(
            combinatorial.getConditionId(_positionIds(_insertCondition(parentConditions, uint256(conditionId))))
                .computePositionId(0)
        );
        uint256 childNoPositionId = PositionId.unwrap(
            combinatorial.getConditionId(_positionIds(_insertCondition(parentConditions, uint256(conditionId) | 1)))
                .computePositionId(0)
        );

        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");

        address[] memory to = new address[](2);
        to[0] = address(this);
        to[1] = address(this);
        combinatorial.splitOnCondition(to, PositionId.wrap(slot.positionId), ConditionIdLib.from(conditionId), amount);

        _removeFromSlot(slotIndex, amount);
        _addSlot(childYesPositionId, amount);
        _addSlot(childNoPositionId, amount);
    }

    function mergeOnCondition(uint256 slotSeed, uint256 conditionIndexSeed, uint256 amountSeed) external {
        uint256 slotIndex = _combinatorialSlotIndex(slotSeed, 0, 2, MAX_MARKETS);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        uint256[] memory childConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slot.positionId).conditionId())))
            )
        );
        uint256 conditionIndex = conditionIndexSeed % childConditions.length;
        uint256[] memory siblingConditions =
            _replaceCondition(childConditions, conditionIndex, _flipCondition(childConditions[conditionIndex]));
        uint256 siblingPositionId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(siblingConditions)).computePositionId(0));
        uint256 siblingSlotIndex = _findSlot(siblingPositionId);
        if (siblingSlotIndex == type(uint256).max) return;

        uint256[] memory parentConditions = _removeCondition(childConditions, conditionIndex);
        bytes32 parentConditionId =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(parentConditions))));
        if (!combinatorial.isConditionPrepared(ConditionIdLib.from(parentConditionId))) return;

        uint256 amount = slots[slotIndex].amount < slots[siblingSlotIndex].amount
            ? slots[slotIndex].amount
            : slots[siblingSlotIndex].amount;
        amount = bound(amountSeed, 1, amount);

        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");
        positionManager.safeTransferFrom(address(this), address(combinatorial), siblingPositionId, amount, "");
        combinatorial.mergeOnCondition(
            address(this),
            ConditionIdLib.from(parentConditionId).computePositionId(0),
            ConditionIdLib.from(bytes32(childConditions[conditionIndex] & _CONDITION_MASK)),
            amount
        );

        _removeFromSlot(slotIndex, amount);
        _removeFromSlot(siblingSlotIndex, amount);
        _addSlot(PositionId.unwrap(ConditionIdLib.from(parentConditionId).computePositionId(0)), amount);
    }

    function extract(uint256 slotSeed, uint256 conditionIndexSeed, uint256 amountSeed) external {
        uint256 slotIndex = _combinatorialSlotIndex(slotSeed, 1, 2, MAX_MARKETS);
        if (slotIndex == type(uint256).max || activeSlots > MAX_SLOTS - 2) return;

        Slot memory slot = slots[slotIndex];
        uint256[] memory fullConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slot.positionId).conditionId())))
            )
        );
        uint256 conditionIndex = conditionIndexSeed % fullConditions.length;
        uint256[] memory reducedConditions = _removeCondition(fullConditions, conditionIndex);
        uint256[] memory residualConditions =
            _insertCondition(reducedConditions, _flipCondition(fullConditions[conditionIndex]));

        uint256 reducedNoPositionId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(reducedConditions)).computePositionId(1));
        uint256 residualYesPositionId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(residualConditions)).computePositionId(0));
        uint256 amount = bound(amountSeed, 1, slot.amount);

        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");

        address[] memory to = new address[](2);
        to[0] = address(this);
        to[1] = address(this);
        combinatorial.extract(to, PositionId.wrap(slot.positionId), conditionIndex, amount);

        _removeFromSlot(slotIndex, amount);
        _addSlot(reducedNoPositionId, amount);
        _addSlot(residualYesPositionId, amount);
    }

    function inject(uint256 residualSlotSeed, uint256 conditionIndexSeed, uint256 amountSeed) external {
        uint256 residualSlotIndex = _combinatorialSlotIndex(residualSlotSeed, 0, 2, MAX_MARKETS);
        if (residualSlotIndex == type(uint256).max) return;

        Slot memory residualSlot = slots[residualSlotIndex];
        uint256[] memory residualConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(residualSlot.positionId).conditionId())))
            )
        );
        uint256 conditionIndex = conditionIndexSeed % residualConditions.length;
        uint256[] memory fullConditions =
            _replaceCondition(residualConditions, conditionIndex, _flipCondition(residualConditions[conditionIndex]));
        bytes32 fullConditionId =
            bytes32(ConditionId.unwrap(combinatorial.getConditionId(_positionIds(fullConditions))));
        if (!combinatorial.isConditionPrepared(ConditionIdLib.from(fullConditionId))) return;

        uint256 reducedNoPositionId = PositionId.unwrap(
            combinatorial.getConditionId(_positionIds(_removeCondition(residualConditions, conditionIndex)))
                .computePositionId(1)
        );
        uint256 reducedSlotIndex = _findSlot(reducedNoPositionId);
        if (reducedSlotIndex == type(uint256).max) return;

        uint256 amount =
            residualSlot.amount < slots[reducedSlotIndex].amount ? residualSlot.amount : slots[reducedSlotIndex].amount;
        amount = bound(amountSeed, 1, amount);

        positionManager.safeTransferFrom(address(this), address(combinatorial), reducedNoPositionId, amount, "");
        positionManager.safeTransferFrom(address(this), address(combinatorial), residualSlot.positionId, amount, "");
        combinatorial.inject(
            address(this), ConditionIdLib.from(fullConditionId).computePositionId(1), conditionIndex, amount
        );

        _removeFromSlot(reducedSlotIndex, amount);
        _removeFromSlot(residualSlotIndex, amount);
        _addSlot(PositionId.unwrap(ConditionIdLib.from(fullConditionId).computePositionId(1)), amount);
    }

    function convertToYesBasket(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _combinatorialSlotIndex(slotSeed, 1, 1, MAX_MARKETS);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        uint256[] memory fullConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slot.positionId).conditionId())))
            )
        );
        if (activeSlots > MAX_SLOTS - fullConditions.length) return;

        uint256 amount = bound(amountSeed, 1, slot.amount);
        uint256[] memory basketPositionIds = _yesBasketPositionIds(fullConditions);

        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");

        address[] memory to = new address[](fullConditions.length);
        for (uint256 i; i < to.length; ++i) {
            to[i] = address(this);
        }
        combinatorial.convertToYesBasket(to, PositionId.wrap(slot.positionId), amount);

        _removeFromSlot(slotIndex, amount);
        for (uint256 i; i < basketPositionIds.length; ++i) {
            _addSlot(basketPositionIds[i], amount);
        }
    }

    function mergeFromYesBasket(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _combinatorialSlotIndex(slotSeed, 2, 1, MAX_MARKETS);
        if (slotIndex == type(uint256).max) return;

        uint256[] memory fullConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(
                    bytes32(ConditionId.unwrap(PositionId.wrap(slots[slotIndex].positionId).conditionId()))
                )
            )
        );
        uint256[] memory basketPositionIds = _yesBasketPositionIds(fullConditions);
        uint256[] memory basketSlotIndexes = new uint256[](basketPositionIds.length);
        uint256 amount = type(uint256).max;

        for (uint256 i; i < basketPositionIds.length; ++i) {
            basketSlotIndexes[i] = _findSlot(basketPositionIds[i]);
            if (basketSlotIndexes[i] == type(uint256).max) return;
            if (slots[basketSlotIndexes[i]].amount < amount) amount = slots[basketSlotIndexes[i]].amount;
        }

        amount = bound(amountSeed, 1, amount);
        for (uint256 i; i < basketPositionIds.length; ++i) {
            positionManager.safeTransferFrom(address(this), address(combinatorial), basketPositionIds[i], amount, "");
        }

        uint256 fullNoPositionId = PositionId.unwrap(
            ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slots[slotIndex].positionId).conditionId())))
                .computePositionId(1)
        );
        combinatorial.mergeFromYesBasket(address(this), PositionId.wrap(fullNoPositionId), amount);

        for (uint256 i; i < basketSlotIndexes.length; ++i) {
            _removeFromSlot(basketSlotIndexes[i], amount);
        }
        _addSlot(fullNoPositionId, amount);
    }

    function unwrap(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _combinatorialSlotIndex(slotSeed, 2, 1, 1);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        uint256[] memory storedConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slot.positionId).conditionId())))
            )
        );
        uint256 underlyingPositionId = PositionId.wrap(slot.positionId).outcomeIndex() == 0
            ? storedConditions[0]
            : _flipCondition(storedConditions[0]);
        uint256 amount = bound(amountSeed, 1, slot.amount);

        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");
        combinatorial.unwrap(address(this), PositionId.wrap(slot.positionId), amount);

        _removeFromSlot(slotIndex, amount);
        _addSlot(underlyingPositionId, amount);
    }

    function wrap(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _underlyingSlotIndex(slotSeed);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        uint256[] memory wrappedConditions = new uint256[](1);
        wrappedConditions[0] = slot.positionId;
        uint256 wrappedPositionId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(wrappedConditions)).computePositionId(0));
        if (!_hasSlot(wrappedPositionId) && activeSlots == MAX_SLOTS) return;

        uint256 amount = bound(amountSeed, 1, slot.amount);
        positionManager.safeTransferFrom(address(this), address(combinatorial), slot.positionId, amount, "");
        combinatorial.wrap(address(this), PositionId.wrap(slot.positionId), amount);

        _removeFromSlot(slotIndex, amount);
        _addSlot(wrappedPositionId, amount);
    }

    function redeemUnderlying(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _underlyingSlotIndex(slotSeed);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        if (!_underlyingResolved(slot.positionId)) return;

        uint256 amount = bound(amountSeed, 1, slot.amount);
        positionManager.safeTransferFrom(address(this), binaryModule, slot.positionId, amount, "");
        BaseModule(binaryModule).redeem(address(this), PositionId.wrap(slot.positionId), amount);

        _removeFromSlot(slotIndex, amount);
    }

    function mergeUnderlying(uint256 slotSeed, uint256 amountSeed) external {
        uint256 slotIndex = _underlyingSlotIndex(slotSeed);
        if (slotIndex == type(uint256).max) return;

        Slot memory slot = slots[slotIndex];
        uint256 siblingPositionId =
            (slot.positionId & _CONDITION_MASK) | (PositionId.wrap(slot.positionId).outcomeIndex() ^ 1);
        uint256 siblingSlotIndex = _findSlot(siblingPositionId);
        if (siblingSlotIndex == type(uint256).max) return;

        uint256 amount = slot.amount < slots[siblingSlotIndex].amount ? slot.amount : slots[siblingSlotIndex].amount;
        amount = bound(amountSeed, 1, amount);

        positionManager.safeTransferFrom(address(this), binaryModule, slot.positionId, amount, "");
        positionManager.safeTransferFrom(address(this), binaryModule, siblingPositionId, amount, "");
        BaseModule(binaryModule)
            .merge(address(this), ConditionIdLib.from(bytes32(slot.positionId & _CONDITION_MASK)), amount);

        _removeFromSlot(slotIndex, amount);
        _removeFromSlot(siblingSlotIndex, amount);
    }

    function allResolved() external view returns (bool) {
        return resolvedCount == MAX_MARKETS;
    }

    function currentCollateral() external view returns (uint256) {
        return collateralToken.balanceOf(address(this));
    }

    function exactValueAfterResolution() external view returns (uint256 value) {
        value = collateralToken.balanceOf(address(this));
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (slots[i].amount == 0) continue;

            uint256 moduleId = PositionId.wrap(slots[i].positionId).moduleId();
            if (moduleId == ModuleIds.COMBINATORIAL) {
                value += combinatorial.getPayout(PositionId.wrap(slots[i].positionId), slots[i].amount);
            } else {
                value += BaseModule(positionManager.moduleById(moduleId))
                    .getPayout(PositionId.wrap(slots[i].positionId), slots[i].amount);
            }
        }
    }

    function trackedBalancesMatchPositionManager() external view returns (bool) {
        for (uint256 i; i < seenCount; ++i) {
            uint256 positionId = seenPositionIds[i];
            if (positionManager.balanceOf(address(this), positionId) != _trackedBalance(positionId)) return false;
            if (positionManager.balanceOf(address(combinatorial), positionId) != 0) return false;
            if (positionManager.balanceOf(binaryModule, positionId) != 0) return false;
        }
        return true;
    }

    function moduleCollateralBalance() external view returns (uint256) {
        return collateralToken.balanceOf(address(combinatorial)) + collateralToken.balanceOf(binaryModule);
    }

    function _conditionsFromSeed(uint256 seed) internal view returns (uint256[] memory conditions) {
        uint256 mask = (seed % ((1 << MAX_MARKETS) - 1)) + 1;
        uint256 length;
        for (uint256 i; i < MAX_MARKETS; ++i) {
            if ((mask & (1 << i)) != 0) ++length;
        }

        conditions = new uint256[](length);
        uint256 index;
        for (uint256 i; i < MAX_MARKETS; ++i) {
            if ((mask & (1 << i)) == 0) continue;
            uint256 outcome = (seed >> (MAX_MARKETS + i)) & 1;
            conditions[index++] = uint256(conditionIds[i]) | outcome;
        }

        for (uint256 i = 1; i < length; ++i) {
            uint256 value = conditions[i];
            uint256 j = i;
            while (j > 0 && conditions[j - 1] > value) {
                conditions[j] = conditions[j - 1];
                unchecked {
                    --j;
                }
            }
            conditions[j] = value;
        }
    }

    function _availableConditionReference(uint256[] memory existingConditions, uint256 seed)
        internal
        view
        returns (bytes32 conditionId)
    {
        uint256 available;
        for (uint256 i; i < MAX_MARKETS; ++i) {
            if (!_conditionPresent(existingConditions, conditionIds[i])) ++available;
        }
        if (available == 0) return bytes32(0);

        uint256 target = seed % available;
        for (uint256 i; i < MAX_MARKETS; ++i) {
            if (_conditionPresent(existingConditions, conditionIds[i])) continue;
            if (target == 0) return conditionIds[i];
            --target;
        }
    }

    function _conditionPresent(uint256[] memory conditions, bytes32 conditionId) internal pure returns (bool) {
        uint256 conditionBits = uint256(conditionId) & _CONDITION_MASK;
        for (uint256 i; i < conditions.length; ++i) {
            if ((conditions[i] & _CONDITION_MASK) == conditionBits) return true;
        }
        return false;
    }

    function _insertCondition(uint256[] memory base, uint256 condition)
        internal
        pure
        returns (uint256[] memory result)
    {
        result = new uint256[](base.length + 1);
        uint256 insertIndex = base.length;
        for (uint256 i; i < base.length; ++i) {
            if (condition < base[i]) {
                insertIndex = i;
                break;
            }
        }

        for (uint256 i; i < insertIndex; ++i) {
            result[i] = base[i];
        }
        result[insertIndex] = condition;
        for (uint256 i = insertIndex; i < base.length; ++i) {
            result[i + 1] = base[i];
        }
    }

    function _removeCondition(uint256[] memory base, uint256 index) internal pure returns (uint256[] memory result) {
        result = new uint256[](base.length - 1);
        for (uint256 i; i < index; ++i) {
            result[i] = base[i];
        }
        for (uint256 i = index + 1; i < base.length; ++i) {
            result[i - 1] = base[i];
        }
    }

    function _replaceCondition(uint256[] memory base, uint256 index, uint256 condition)
        internal
        pure
        returns (uint256[] memory result)
    {
        result = new uint256[](base.length);
        for (uint256 i; i < base.length; ++i) {
            result[i] = i == index ? condition : base[i];
        }
    }

    function _yesBasketPositionIds(uint256[] memory fullConditions)
        internal
        view
        returns (uint256[] memory basketPositionIds)
    {
        basketPositionIds = new uint256[](fullConditions.length);
        for (uint256 i; i < fullConditions.length; ++i) {
            uint256[] memory basketConditions = new uint256[](i + 1);
            for (uint256 j; j < i; ++j) {
                basketConditions[j] = fullConditions[j];
            }
            basketConditions[i] = _flipCondition(fullConditions[i]);
            basketPositionIds[i] =
                PositionId.unwrap(combinatorial.getConditionId(_positionIds(basketConditions)).computePositionId(0));
        }
    }

    function _flipCondition(uint256 condition) internal pure returns (uint256) {
        return (condition & _CONDITION_MASK) | ((condition & _OUTCOME_MASK) ^ 1);
    }

    function _previewCompress(uint256 positionId, uint256 amount)
        internal
        view
        returns (bool compressible, uint256 newPositionId)
    {
        bytes32 conditionId = bytes32(ConditionId.unwrap(PositionId.wrap(positionId).conditionId()));
        uint256 outcomeIndex = PositionId.wrap(positionId).outcomeIndex();
        uint256[] memory storedConditions = _rawPositionIds(combinatorial.getLegs(ConditionIdLib.from(conditionId)));

        uint256[] memory remaining = new uint256[](storedConditions.length);
        uint256 remainingCount;
        uint256 payoutFactor = PAYOUT_FACTOR_DENOMINATOR;
        uint256 payoutFactorUp = PAYOUT_FACTOR_DENOMINATOR;

        for (uint256 i; i < storedConditions.length; ++i) {
            (bool conditionResolved, uint256 conditionPayout) = _conditionPayout(storedConditions[i]);
            if (!conditionResolved) {
                remaining[remainingCount++] = storedConditions[i];
                continue;
            }

            compressible = true;
            if (conditionPayout == 0) {
                payoutFactor = 0;
                payoutFactorUp = 0;
                break;
            }
            if (conditionPayout != RESULT_DENOMINATOR) {
                payoutFactor = FixedPointMathLib.mulDiv(payoutFactor, conditionPayout, RESULT_DENOMINATOR);
                payoutFactorUp = FixedPointMathLib.mulDivUp(payoutFactorUp, conditionPayout, RESULT_DENOMINATOR);
            }
        }

        if (!compressible || remainingCount == 0) return (compressible, 0);

        uint256 positionAmount = outcomeIndex == 0
            ? FixedPointMathLib.mulDiv(amount, payoutFactor, PAYOUT_FACTOR_DENOMINATOR)
            : FixedPointMathLib.mulDivUp(amount, payoutFactorUp, PAYOUT_FACTOR_DENOMINATOR);
        if (positionAmount == 0) return (compressible, 0);

        uint256[] memory trimmed = new uint256[](remainingCount);
        for (uint256 i; i < remainingCount; ++i) {
            trimmed[i] = remaining[i];
        }
        newPositionId =
            PositionId.unwrap(combinatorial.getConditionId(_positionIds(trimmed)).computePositionId(outcomeIndex));
    }

    function _conditionPayout(uint256 condition) internal view returns (bool conditionResolved, uint256 payout) {
        bytes32 conditionId = bytes32(condition & _CONDITION_MASK);
        uint256[] memory result = BaseModule(positionManager.moduleById(PositionId.wrap(condition).moduleId()))
            .getResult(ConditionIdLib.from(conditionId));
        if (result.length == 0) return (false, 0);
        return (true, result[condition & _OUTCOME_MASK]);
    }

    function _isRedeemable(uint256 positionId) internal view returns (bool) {
        uint256[] memory storedConditions = _rawPositionIds(
            combinatorial.getLegs(
                ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(positionId).conditionId())))
            )
        );
        if (PositionId.wrap(positionId).outcomeIndex() == 0) {
            for (uint256 i; i < storedConditions.length; ++i) {
                (bool conditionResolved,) = _conditionPayout(storedConditions[i]);
                if (!conditionResolved) return false;
            }
            return true;
        }

        bool unresolved;
        for (uint256 i; i < storedConditions.length; ++i) {
            (bool conditionResolved, uint256 conditionPayout) = _conditionPayout(storedConditions[i]);
            if (!conditionResolved) unresolved = true;
            else if (conditionPayout == 0) return true;
        }
        return !unresolved;
    }

    function _underlyingResolved(uint256 positionId) internal view returns (bool) {
        uint256[] memory result = BaseModule(positionManager.moduleById(PositionId.wrap(positionId).moduleId()))
            .getResult(PositionId.wrap(positionId).conditionId());
        return result.length != 0;
    }

    function _slotIndex(uint256 seed) internal view returns (uint256) {
        if (activeSlots == 0) return type(uint256).max;
        uint256 target = seed % activeSlots;
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (slots[i].amount == 0) continue;
            if (target == 0) return i;
            --target;
        }
        return type(uint256).max;
    }

    function _combinatorialSlotIndex(uint256 seed, uint256 outcomeIndex, uint256 minLength, uint256 maxLength)
        internal
        view
        returns (uint256)
    {
        uint256 matches;
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (!_isCombinatorialSlot(i)) continue;
            if (outcomeIndex < 2 && PositionId.wrap(slots[i].positionId).outcomeIndex() != outcomeIndex) continue;

            uint256 length =
                _rawPositionIds(
                combinatorial.getLegs(
                    ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slots[i].positionId).conditionId())))
                )
            )
            .length;
            if (length < minLength || length > maxLength) continue;
            ++matches;
        }
        if (matches == 0) return type(uint256).max;

        uint256 target = seed % matches;
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (!_isCombinatorialSlot(i)) continue;
            if (outcomeIndex < 2 && PositionId.wrap(slots[i].positionId).outcomeIndex() != outcomeIndex) continue;

            uint256 length =
                _rawPositionIds(
                combinatorial.getLegs(
                    ConditionIdLib.from(bytes32(ConditionId.unwrap(PositionId.wrap(slots[i].positionId).conditionId())))
                )
            )
            .length;
            if (length < minLength || length > maxLength) continue;
            if (target == 0) return i;
            --target;
        }
        return type(uint256).max;
    }

    function _underlyingSlotIndex(uint256 seed) internal view returns (uint256) {
        uint256 matches;
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (_isUnderlyingSlot(i)) ++matches;
        }
        if (matches == 0) return type(uint256).max;

        uint256 target = seed % matches;
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (!_isUnderlyingSlot(i)) continue;
            if (target == 0) return i;
            --target;
        }
        return type(uint256).max;
    }

    function _isCombinatorialSlot(uint256 index) internal view returns (bool) {
        return
            slots[index].amount != 0 && PositionId.wrap(slots[index].positionId).moduleId() == ModuleIds.COMBINATORIAL;
    }

    function _isUnderlyingSlot(uint256 index) internal view returns (bool) {
        return slots[index].amount != 0 && PositionId.wrap(slots[index].positionId).moduleId() == ModuleIds.BINARY;
    }

    function _findSlot(uint256 positionId) internal view returns (uint256) {
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (slots[i].positionId == positionId && slots[i].amount != 0) return i;
        }
        return type(uint256).max;
    }

    function _addSlot(uint256 positionId, uint256 amount) internal {
        if (amount == 0) return;
        _rememberPosition(positionId);

        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (slots[i].positionId == positionId && slots[i].amount != 0) {
                slots[i].amount += amount;
                return;
            }
        }

        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (slots[i].amount == 0) {
                slots[i] = Slot(positionId, amount);
                activeSlots++;
                return;
            }
        }

        revert("slot overflow");
    }

    function _rememberPosition(uint256 positionId) internal {
        for (uint256 i; i < seenCount; ++i) {
            if (seenPositionIds[i] == positionId) return;
        }
        require(seenCount < MAX_SEEN, "seen overflow");
        seenPositionIds[seenCount++] = positionId;
    }

    function _removeFromSlot(uint256 index, uint256 amount) internal {
        slots[index].amount -= amount;
        if (slots[index].amount == 0) {
            delete slots[index];
            activeSlots--;
        }
    }

    function _hasSlot(uint256 positionId) internal view returns (bool) {
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (slots[i].positionId == positionId && slots[i].amount != 0) return true;
        }
        return false;
    }

    function _trackedBalance(uint256 positionId) internal view returns (uint256 balance) {
        for (uint256 i; i < MAX_SLOTS; ++i) {
            if (slots[i].positionId == positionId) balance += slots[i].amount;
        }
    }

    function _compressedNewPositionId(Vm.Log[] memory entries) internal pure returns (uint256 newPositionId) {
        for (uint256 i = entries.length; i > 0; --i) {
            Vm.Log memory entry = entries[i - 1];
            if (entry.topics.length == 0 || entry.topics[0] != COMPRESSED_TOPIC) continue;
            if (entry.topics.length == 4) return uint256(entry.topics[3]);
            if (entry.topics.length == 2) {
                (, newPositionId,,,,) = abi.decode(entry.data, (uint256, uint256, address, uint256, uint256, uint256));
                return newPositionId;
            }
        }
    }
}

contract CombinatorialModuleInvariantTest is TestHelper {
    Positions internal positions;
    Collateral internal collateral;
    CombinatorialModule internal combinatorial;
    CombinatorialValueHandler internal handler;

    function setUp() public {
        Legacy memory legacy;
        (positions, collateral, legacy) = PositionManagerSetup._deploy(owner, admin, creator);
        legacy;

        address implementation = address(new CombinatorialModule(address(positions.manager)));
        address proxy = LibClone.deployERC1967(implementation);
        combinatorial = CombinatorialModule(proxy);
        combinatorial.initialize(owner, admin);

        vm.prank(owner);
        collateral.token.addMinter(address(combinatorial));

        vm.startPrank(admin);
        positions.manager.addModule(address(combinatorial));
        positions.manager.setCrossModuleAuth(address(combinatorial), true);
        positions.binaryModule.addResolver(oracle);
        vm.stopPrank();

        handler = new CombinatorialValueHandler(combinatorial, positions, collateral, oracle);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](17);
        selectors[0] = CombinatorialValueHandler.open.selector;
        selectors[1] = CombinatorialValueHandler.openUnderlying.selector;
        selectors[2] = CombinatorialValueHandler.resolve.selector;
        selectors[3] = CombinatorialValueHandler.resolveAll.selector;
        selectors[4] = CombinatorialValueHandler.compress.selector;
        selectors[5] = CombinatorialValueHandler.redeem.selector;
        selectors[6] = CombinatorialValueHandler.merge.selector;
        selectors[7] = CombinatorialValueHandler.splitOnCondition.selector;
        selectors[8] = CombinatorialValueHandler.mergeOnCondition.selector;
        selectors[9] = CombinatorialValueHandler.extract.selector;
        selectors[10] = CombinatorialValueHandler.inject.selector;
        selectors[11] = CombinatorialValueHandler.convertToYesBasket.selector;
        selectors[12] = CombinatorialValueHandler.mergeFromYesBasket.selector;
        selectors[13] = CombinatorialValueHandler.unwrap.selector;
        selectors[14] = CombinatorialValueHandler.wrap.selector;
        selectors[15] = CombinatorialValueHandler.redeemUnderlying.selector;
        selectors[16] = CombinatorialValueHandler.mergeUnderlying.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @dev Collateral already realized by arbitrary compress/redeem/merge paths must never exceed
    ///      the collateral used to open the portfolio.
    function invariant_realizedCollateralNeverExceedsFunding() public view {
        assertLe(handler.currentCollateral(), handler.initialCollateral());
    }

    function invariant_trackedBalancesMatchPositionManager() public view {
        assertTrue(handler.trackedBalancesMatchPositionManager());
    }

    function invariant_modulesDoNotRetainEscrowedAssets() public view {
        assertEq(handler.moduleCollateralBalance(), 0);
    }

    function test_handlerResolvePath() public {
        handler.resolve(0, 500_000);
        assertFalse(handler.allResolved());
    }

    /// @dev Once every underlying leg is resolved, the remaining redeemable value plus already
    ///      realized collateral must be no more than the original collateral funding.
    function invariant_noValueExtractionAfterFullResolution() public view {
        if (!handler.allResolved()) return;
        assertLe(handler.exactValueAfterResolution(), handler.initialCollateral());
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ConditionId, EventId, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

/// @title RouterEvents
/// @notice Events emitted by the Router.
abstract contract RouterEvents {
    /// @notice Emitted when collateral is split into YES/NO positions.
    /// @param initiator The address that initiated the split.
    /// @param conditionId The condition that was split.
    /// @param amount The amount of collateral that was split.
    event RouterPositionSplit(address indexed initiator, ConditionId indexed conditionId, uint256 amount);

    /// @notice Emitted when YES/NO positions are merged back into collateral.
    /// @param initiator The address that initiated the merge.
    /// @param conditionId The condition that was merged.
    /// @param amount The amount of each position that was merged.
    event RouterPositionsMerged(address indexed initiator, ConditionId indexed conditionId, uint256 amount);

    /// @notice Emitted when a position is redeemed for collateral payout.
    /// @param initiator The address that initiated the redemption.
    /// @param positionId The position that was redeemed.
    /// @param amount The amount of position that was redeemed.
    event RouterPositionRedeemed(address indexed initiator, PositionId indexed positionId, uint256 amount);

    /// @notice Emitted when collateral is split into YES positions across all neg-risk conditions.
    /// @param initiator The address that initiated the split.
    /// @param eventId The neg-risk event that was split.
    /// @param amount The amount of collateral that was split.
    event RouterHorizontalSplit(address indexed initiator, EventId indexed eventId, uint256 amount);

    /// @notice Emitted when YES positions across all neg-risk conditions are merged into collateral.
    /// @param initiator The address that initiated the merge.
    /// @param eventId The neg-risk event that was merged.
    /// @param amount The amount per condition that was merged.
    event RouterHorizontalMerge(address indexed initiator, EventId indexed eventId, uint256 amount);

    /// @notice Emitted when a NO position is converted into YES positions for all other conditions.
    /// @param initiator The address that initiated the conversion.
    /// @param eventId The neg-risk event.
    /// @param conditionIndex The condition whose NO was converted.
    /// @param amount The amount converted.
    event RouterPositionConverted(
        address indexed initiator, EventId indexed eventId, uint256 conditionIndex, uint256 amount
    );

    /// @notice Emitted after a complete combinatorial collateral-return sequence.
    /// @param initiator The address whose collateral and positions were used.
    /// @param operationCount The number of operations executed.
    event CombinatorialCollateralReturned(address indexed initiator, uint256 operationCount);
}

/// @title RouterErrors
/// @notice Errors thrown by the Router.
abstract contract RouterErrors {
    /// @notice Thrown when an outcome index outside the valid binary range (0 or 1) is supplied.
    error InvalidOutcomeIndex();

    /// @notice Thrown when the initializer is invoked with the zero address as the owner.
    error InvalidOwner();

    /// @notice Thrown when collateral-return inputs are malformed.
    error InvalidCombinatorialReturnOperation();

    /// @notice Thrown when the PositionManager has no combinatorial module registered.
    error CombinatorialModuleNotConfigured();
}

/// @notice All wallet inputs for a combinatorial collateral return.
struct CombinatorialReturnTransfers {
    uint256 collateralAmount;
    PositionId[] positionIds;
    uint256[] positionAmounts;
}

/// @title Router
/// @author Polymarket
/// @notice Entry point for split/merge/redeem, NegRisk horizontal operations, and
///         CombinatorialModule operations, including combinatorial collateral return.
/// @dev UUPS-upgradeable; owner authorizes upgrades. Immutables are bytecode-bound on the
///      implementation, so each implementation deployment is parameterized for one
///      (positionManager, collateralToken) pair.
contract Router is UUPSUpgradeable, Initializable, OwnableRoles, RouterEvents, RouterErrors {
    using SafeTransferLib for address;

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The PositionManager contract.
    PositionManager public immutable POSITION_MANAGER;

    /// @notice The collateral token address.
    address public immutable COLLATERAL_TOKEN;

    /// @dev Reserved storage gap for future Router state. Downstream inheritors (e.g.
    ///      `BridgeRouter`) begin their storage layout after slot 49.
    uint256[50] private __gap;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploy the Router implementation
    /// @param _positionManager Address of the PositionManager contract
    constructor(address _positionManager) {
        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = POSITION_MANAGER.COLLATERAL_TOKEN();

        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the Router proxy with the given owner.
    /// @dev Replaces the constructor for proxy deployments. Owner authorizes upgrades.
    ///      Rejects the zero address explicitly because Solady's `_initializeOwner` would
    ///      otherwise silently set owner to zero and permanently brick the proxy. `onlyProxy`
    ///      adds defense in depth on top of `_disableInitializers()` in the constructor.
    /// @param _owner The address to set as the owner of the contract.
    function initialize(address _owner) external onlyProxy initializer {
        if (_owner == address(0)) revert InvalidOwner();
        _initializeOwner(_owner);
    }

    /*--------------------------------------------------------------
                         SPLIT / MERGE / REDEEM
    --------------------------------------------------------------*/

    /// @notice Split collateral into YES/NO positions
    /// @param _conditionId The condition to split on
    /// @param _amount Amount of collateral to split
    function split(ConditionId _conditionId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_conditionId.moduleId());

        // Transfer collateral from user to module
        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, moduleAddr, _amount);

        // Build address[] without zero-init overhead.
        address[] memory to;
        assembly ("memory-safe") {
            to := mload(0x40)
            mstore(to, 2)
            mstore(add(to, 0x20), caller())
            mstore(add(to, 0x40), caller())
            mstore(0x40, add(to, 0x60))
        }

        BaseModule(moduleAddr).split(to, _conditionId, _amount);

        emit RouterPositionSplit(msg.sender, _conditionId, _amount);
    }

    /// @notice Merge YES/NO positions back into collateral
    /// @param _conditionId The condition to merge
    /// @param _amount Amount per position to merge
    function merge(ConditionId _conditionId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_conditionId.moduleId());

        PositionId positionId0 = _conditionId.computePositionId(0);
        PositionId positionId1 = _conditionId.computePositionId(1);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, positionId0, _amount);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, positionId1, _amount);

        BaseModule(moduleAddr).merge(msg.sender, _conditionId, _amount);

        emit RouterPositionsMerged(msg.sender, _conditionId, _amount);
    }

    /// @notice Redeem resolved position for collateral payout
    /// @dev Reverts with `InvalidOutcomeIndex` for values >= 2; the underlying position ID
    /// encoding would otherwise alias non-binary inputs (e.g. 256, 257) to outcomes 0 and 1.
    /// @param _conditionId The condition to redeem
    /// @param _outcomeIndex The outcome index (0=YES, 1=NO)
    /// @param _amount Amount of position to redeem
    function redeem(ConditionId _conditionId, uint256 _outcomeIndex, uint256 _amount) external {
        if (_outcomeIndex > 1) revert InvalidOutcomeIndex();
        PositionId positionId = _conditionId.computePositionId(_outcomeIndex);
        address moduleAddr = POSITION_MANAGER.moduleById(positionId.moduleId());

        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, positionId, _amount);

        BaseModule(moduleAddr).redeem(msg.sender, positionId, _amount);

        emit RouterPositionRedeemed(msg.sender, positionId, _amount);
    }

    /*--------------------------------------------------------------
                         NEGRISK HORIZONTAL OPERATIONS
    --------------------------------------------------------------*/

    /// @notice Split collateral into YES positions across all real conditions and the synthetic Other
    /// @param _eventId The neg-risk event ID
    /// @param _amount Amount of collateral to split
    function horizontalSplit(EventId _eventId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_eventId.moduleId());
        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, moduleAddr, _amount);
        NegRiskModule(moduleAddr).horizontalSplit(msg.sender, _eventId, _amount);

        emit RouterHorizontalSplit(msg.sender, _eventId, _amount);
    }

    /// @notice Merge YES positions across all real conditions and the synthetic Other into collateral
    /// @param _eventId The neg-risk event ID
    /// @param _amount Amount per condition to merge
    function horizontalMerge(EventId _eventId, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_eventId.moduleId());
        uint256 conditionCount_ = NegRiskModule(moduleAddr).conditionCount(_eventId);
        PositionId[] memory positionIds = new PositionId[](conditionCount_ + 1);
        uint256[] memory amounts = new uint256[](conditionCount_ + 1);
        // Including the synthetic fallback condition
        for (uint256 i = 0; i <= conditionCount_; ++i) {
            positionIds[i] = _eventId.computeConditionId(i).computePositionId(0);
            amounts[i] = _amount;
        }

        POSITION_MANAGER.unsafeBatchTransferFrom(msg.sender, moduleAddr, positionIds, amounts);
        NegRiskModule(moduleAddr).horizontalMerge(msg.sender, _eventId, _amount);

        emit RouterHorizontalMerge(msg.sender, _eventId, _amount);
    }

    /// @notice Convert a NO position into YES positions for all other conditions.
    /// @dev `_conditionIndex` is typed `uint16` to mirror the 16-bit conditionIndex field in
    ///      position IDs (see `CONDITION_INDEX_MASK` in `Ids.sol`). Valid range is
    ///      `[0, conditionCount(eventId)]`, where `conditionCount` is the synthetic Other index.
    /// @param _eventId The neg-risk event ID.
    /// @param _conditionIndex Index of the condition whose NO to convert (0..65535).
    /// @param _amount Amount to convert
    function convert(EventId _eventId, uint16 _conditionIndex, uint256 _amount) external {
        address moduleAddr = POSITION_MANAGER.moduleById(_eventId.moduleId());
        ConditionId conditionId = _eventId.computeConditionId(_conditionIndex);
        PositionId noPositionId = conditionId.computePositionId(1);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, noPositionId, _amount);

        NegRiskModule(moduleAddr).convert(msg.sender, _eventId, _conditionIndex, _amount);

        emit RouterPositionConverted(msg.sender, _eventId, _conditionIndex, _amount);
    }

    /*--------------------------------------------------------------
                      COMBINATORIAL MODULE OPERATIONS
    --------------------------------------------------------------*/

    /// @notice Split a YES combinatorial position on a new condition, sending both children to the caller.
    function splitOnCondition(PositionId _parentYesPositionId, ConditionId _conditionId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _parentYesPositionId, _amount);
        module.splitOnCondition(_recipients(2), _parentYesPositionId, _conditionId, _amount);
    }

    /// @notice Merge two condition-split children into their parent YES combinatorial position.
    function mergeOnCondition(PositionId _parentYesPositionId, ConditionId _conditionId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        PositionId[] memory parentLegs = module.getLegs(_parentYesPositionId.conditionId());
        PositionId childYesPositionId =
            module.getConditionId(_insertLeg(parentLegs, _conditionId.computePositionId(0))).computePositionId(0);
        PositionId childNoPositionId =
            module.getConditionId(_insertLeg(parentLegs, _conditionId.computePositionId(1))).computePositionId(0);

        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), childYesPositionId, _amount);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), childNoPositionId, _amount);
        module.mergeOnCondition(msg.sender, _parentYesPositionId, _conditionId, _amount);
    }

    /// @notice Split a YES combinatorial position across every neg-risk event outcome, sending children to the caller.
    function splitOnEvent(PositionId _parentYesPositionId, EventId _eventId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _parentYesPositionId, _amount);
        module.splitOnEvent(_recipients(_eventId.arity() + 1), _parentYesPositionId, _eventId, _amount);
    }

    /// @notice Merge event-split children into their parent YES combinatorial position.
    function mergeOnEvent(PositionId _parentYesPositionId, EventId _eventId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        _transferEqualPositions(
            address(module), _eventChildPositionIds(module, _parentYesPositionId, _eventId), _amount
        );
        module.mergeOnEvent(msg.sender, _parentYesPositionId, _eventId, _amount);
    }

    /// @notice Convert a neg-risk NO leg in a YES combinatorial position into every other event outcome.
    function convertOnEvent(PositionId _parentYesPositionId, uint256 _conditionIndex, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        PositionId[] memory parentLegs = module.getLegs(_parentYesPositionId.conditionId());
        EventId eventId_ = parentLegs[_conditionIndex].conditionId().eventId();

        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _parentYesPositionId, _amount);
        module.convertOnEvent(_recipients(eventId_.arity()), _parentYesPositionId, _conditionIndex, _amount);
    }

    /// @notice Extract one leg from a NO combinatorial position, sending both outputs to the caller.
    function extract(PositionId _fullNoPositionId, uint256 _conditionIndex, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _fullNoPositionId, _amount);
        module.extract(_recipients(2), _fullNoPositionId, _conditionIndex, _amount);
    }

    /// @notice Inject a reduced NO position and residual YES position into a full NO combinatorial position.
    function inject(PositionId _fullNoPositionId, uint256 _conditionIndex, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        PositionId[] memory fullLegs = module.getLegs(_fullNoPositionId.conditionId());
        PositionId[] memory reducedLegs = _removeLeg(fullLegs, _conditionIndex);
        PositionId[] memory residualLegs = _insertLeg(reducedLegs, _flipLeg(fullLegs[_conditionIndex]));

        POSITION_MANAGER.unsafeTransferFrom(
            msg.sender, address(module), module.getConditionId(reducedLegs).computePositionId(1), _amount
        );
        POSITION_MANAGER.unsafeTransferFrom(
            msg.sender, address(module), module.getConditionId(residualLegs).computePositionId(0), _amount
        );
        module.inject(msg.sender, _fullNoPositionId, _conditionIndex, _amount);
    }

    /// @notice Convert a NO combinatorial position to its canonical YES basket, sending outputs to the caller.
    function convertToYesBasket(PositionId _fullNoPositionId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        uint256 length = module.getLegs(_fullNoPositionId.conditionId()).length;
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _fullNoPositionId, _amount);
        module.convertToYesBasket(_recipients(length), _fullNoPositionId, _amount);
    }

    /// @notice Merge a canonical YES basket into its full NO combinatorial position.
    function mergeFromYesBasket(PositionId _fullNoPositionId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        PositionId[] memory basketPositionIds =
            _yesBasketPositionIds(module, module.getLegs(_fullNoPositionId.conditionId()));

        _transferEqualPositions(address(module), basketPositionIds, _amount);
        module.mergeFromYesBasket(msg.sender, _fullNoPositionId, _amount);
    }

    /// @notice Compress a combinatorial position, sending all outputs to the caller.
    function compress(PositionId _positionId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _positionId, _amount);
        module.compress(msg.sender, _positionId, _amount);
    }

    /// @notice Wrap an underlying binary or neg-risk position as a single-leg combinatorial position.
    function wrap(PositionId _underlyingPositionId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _underlyingPositionId, _amount);
        module.wrap(msg.sender, _underlyingPositionId, _amount);
    }

    /// @notice Unwrap a single-leg combinatorial position into its underlying position.
    function unwrap(PositionId _positionId, uint256 _amount) external {
        CombinatorialModule module = _combinatorialModule();
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, address(module), _positionId, _amount);
        module.unwrap(msg.sender, _positionId, _amount);
    }

    /*--------------------------------------------------------------
                  COMBINATORIAL COLLATERAL RETURN
    --------------------------------------------------------------*/

    /// @notice Transfers all inputs to, then executes an ordered sequence against, the CombinatorialModule.
    /// @dev The target is fixed to the CombinatorialModule. The Router forwards any selector on that module;
    ///      the collateral-return engine determines which operations it emits. At least one
    ///      operation is required; all inputs are validated before any transfer executes.
    /// @param _transfers The aggregate collateral and positions to transfer to the module.
    /// @param _operations The module calls to execute in order.
    function combinatorialCollateralReturn(
        CombinatorialReturnTransfers calldata _transfers,
        bytes[] calldata _operations
    ) external {
        address moduleAddr = address(_combinatorialModule());

        if (_operations.length == 0) revert InvalidCombinatorialReturnOperation();
        if (_transfers.positionIds.length != _transfers.positionAmounts.length) {
            revert InvalidCombinatorialReturnOperation();
        }
        if (_transfers.collateralAmount != 0) {
            COLLATERAL_TOKEN.safeTransferFrom(msg.sender, moduleAddr, _transfers.collateralAmount);
        }
        if (_transfers.positionIds.length != 0) {
            POSITION_MANAGER.unsafeBatchTransferFrom(
                msg.sender, moduleAddr, _transfers.positionIds, _transfers.positionAmounts
            );
        }

        uint256 length = _operations.length;
        for (uint256 i; i < length; ++i) {
            (bool success, bytes memory returnData) = moduleAddr.call(_operations[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }

        emit CombinatorialCollateralReturned(msg.sender, length);
    }

    /*--------------------------------------------------------------
                           INTERNAL FUNCTIONS
    --------------------------------------------------------------*/

    function _combinatorialModule() private view returns (CombinatorialModule module) {
        address moduleAddr = POSITION_MANAGER.moduleById(ModuleIds.COMBINATORIAL);
        if (moduleAddr == address(0)) revert CombinatorialModuleNotConfigured();
        module = CombinatorialModule(moduleAddr);
    }

    function _recipients(uint256 _length) private view returns (address[] memory recipients) {
        recipients = new address[](_length);
        for (uint256 i; i < _length; ++i) {
            recipients[i] = msg.sender;
        }
    }

    function _transferEqualPositions(address _to, PositionId[] memory _positionIds, uint256 _amount) private {
        uint256 length = _positionIds.length;
        uint256[] memory amounts = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            amounts[i] = _amount;
        }
        POSITION_MANAGER.unsafeBatchTransferFrom(msg.sender, _to, _positionIds, amounts);
    }

    function _insertLeg(PositionId[] memory _legs, PositionId _leg) private pure returns (PositionId[] memory result) {
        uint256 length = _legs.length;
        result = new PositionId[](length + 1);
        uint256 resultIndex;
        bool inserted;
        for (uint256 i; i < length; ++i) {
            if (!inserted && PositionId.unwrap(_leg) < PositionId.unwrap(_legs[i])) {
                result[resultIndex] = _leg;
                ++resultIndex;
                inserted = true;
            }
            result[resultIndex] = _legs[i];
            ++resultIndex;
        }
        if (!inserted) result[resultIndex] = _leg;
    }

    function _removeLeg(PositionId[] memory _legs, uint256 _index) private pure returns (PositionId[] memory result) {
        uint256 length = _legs.length;
        result = new PositionId[](length - 1);
        for (uint256 i; i < _index; ++i) {
            result[i] = _legs[i];
        }
        for (uint256 i = _index; i < length - 1; ++i) {
            result[i] = _legs[i + 1];
        }
    }

    function _flipLeg(PositionId _leg) private pure returns (PositionId) {
        return _leg.conditionId().computePositionId(_leg.outcomeIndex() ^ 1);
    }

    function _yesBasketPositionIds(CombinatorialModule _module, PositionId[] memory _fullLegs)
        private
        view
        returns (PositionId[] memory basketPositionIds)
    {
        uint256 length = _fullLegs.length;
        basketPositionIds = new PositionId[](length);

        PositionId[] memory basketLegs = new PositionId[](length);
        for (uint256 i; i < length; ++i) {
            PositionId original = _fullLegs[i];
            basketLegs[i] = _flipLeg(original);

            assembly ("memory-safe") {
                mstore(basketLegs, add(i, 1))
            }

            basketPositionIds[i] = _module.getConditionId(basketLegs).computePositionId(0);

            basketLegs[i] = original;
            assembly ("memory-safe") {
                mstore(basketLegs, length)
            }
        }
    }

    function _eventChildPositionIds(CombinatorialModule _module, PositionId _parentYesPositionId, EventId _eventId)
        private
        view
        returns (PositionId[] memory childPositionIds)
    {
        PositionId[] memory parentLegs = _module.getLegs(_parentYesPositionId.conditionId());
        uint256 conditionCount_ = _eventId.arity();
        childPositionIds = new PositionId[](conditionCount_ + 1);
        for (uint256 i; i <= conditionCount_; ++i) {
            childPositionIds[i] = _module.getConditionId(
                    _insertLeg(parentLegs, _eventId.computeConditionId(i).computePositionId(0))
                ).computePositionId(0);
        }
    }

    /*--------------------------------------------------------------
                       UUPS UPGRADE AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Only the owner can authorize upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner { }
}

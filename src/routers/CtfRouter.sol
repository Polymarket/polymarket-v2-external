// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { OwnableRoles } from "@solady/src/auth/OwnableRoles.sol";
import { Initializable } from "@solady/src/utils/Initializable.sol";
import { SafeTransferLib } from "@solady/src/utils/SafeTransferLib.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { IConditionalTokensMethods } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokensMethods.sol";
import { BaseModule } from "@polymarket-v2/src/modules/abstract/BaseModule.sol";
import { ModuleErrors } from "@polymarket-v2/src/modules/abstract/ModuleErrors.sol";
import { ConditionId, ConditionIdLib, PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

/// @title CtfRouterEvents
/// @notice Events emitted by the CtfRouter.
abstract contract CtfRouterEvents {
    /// @notice Emitted when collateral is split into YES/NO positions.
    /// @param initiator The address that initiated the split.
    /// @param conditionId The condition that was split.
    /// @param amount The amount of collateral that was split.
    event CtfRouterPositionSplit(address indexed initiator, ConditionId indexed conditionId, uint256 amount);

    /// @notice Emitted when YES/NO positions are merged back into collateral.
    /// @param initiator The address that initiated the merge.
    /// @param conditionId The condition that was merged.
    /// @param amount The amount of each position that was merged.
    event CtfRouterPositionsMerged(address indexed initiator, ConditionId indexed conditionId, uint256 amount);

    /// @notice Emitted when a position is redeemed for collateral payout.
    /// @param initiator The address that initiated the redemption.
    /// @param positionId The position that was redeemed.
    /// @param amount The amount of position that was redeemed.
    event CtfRouterPositionRedeemed(address indexed initiator, PositionId indexed positionId, uint256 amount);
}

/// @title CtfRouterErrors
/// @notice Errors thrown by the CtfRouter.
abstract contract CtfRouterErrors {
    /// @notice Thrown when the initializer is invoked with the zero address as the owner.
    error InvalidOwner();
}

/// @title CtfRouter
/// @author Polymarket
/// @notice Mirrors the interface of the CTF for backwards compatibility
/// @dev Pre-transfer pattern: transfers assets to module then invokes the operation atomically.
///      UUPS-upgradeable; owner authorizes upgrades. Immutables are bytecode-bound on the
///      implementation, so each implementation deployment is parameterized for one
///      (positionManager, collateralToken) pair.
contract CtfRouter is
    UUPSUpgradeable,
    Initializable,
    OwnableRoles,
    IConditionalTokensMethods,
    CtfRouterEvents,
    ModuleErrors,
    CtfRouterErrors
{
    using SafeTransferLib for address;

    /*--------------------------------------------------------------
                                 STATE
    --------------------------------------------------------------*/

    /// @notice The collateral token address.
    address public immutable COLLATERAL_TOKEN;

    /// @notice The PositionManager contract.
    PositionManager public immutable POSITION_MANAGER;

    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Deploys the CtfRouter implementation.
    /// @param _positionManager Address of the PositionManager contract.
    /// @param _collateralToken Address of the collateral token.
    constructor(address _positionManager, address _collateralToken) {
        POSITION_MANAGER = PositionManager(_positionManager);
        COLLATERAL_TOKEN = _collateralToken;

        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the CtfRouter proxy with the given owner.
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
                                EXTERNAL
    --------------------------------------------------------------*/

    /// @notice Split collateral into YES and NO positions for a binary condition
    /// @dev Mirrors the legacy CTF splitPosition interface. Transfers CollateralToken from the
    ///      caller to the module, then invokes the module's split function in the same tx.
    ///      The first two parameters (collateralToken, parentCollectionId) and partition are
    /// ignored for compatibility with the legacy CTF interface.
    /// @param _conditionId The condition ID to split on
    /// @param _amount The amount of collateral to split
    function splitPosition(address, bytes32, bytes32 _conditionId, uint256[] calldata, uint256 _amount) external {
        ConditionId conditionId = ConditionIdLib.from(_conditionId);
        address moduleAddr = POSITION_MANAGER.moduleById(conditionId.moduleId());

        COLLATERAL_TOKEN.safeTransferFrom(msg.sender, moduleAddr, _amount);

        address[] memory to = new address[](2);
        to[0] = msg.sender;
        to[1] = msg.sender;

        BaseModule(moduleAddr).split(to, conditionId, _amount);

        emit CtfRouterPositionSplit(msg.sender, conditionId, _amount);
    }

    /// @notice Merge YES and NO positions back into collateral
    /// @dev Mirrors the legacy CTF mergePositions interface. Transfers the YES and NO positions
    ///      from the caller to the module via two unsafeTransferFrom calls, then calls the
    ///      module's merge function. The first two parameters (collateralToken,
    ///      parentCollectionId) and partition are ignored for compatibility with the legacy CTF
    ///      interface.
    /// @param _conditionId The condition ID to merge on
    /// @param _amount The amount of each position to merge
    function mergePositions(address, bytes32, bytes32 _conditionId, uint256[] calldata, uint256 _amount) external {
        ConditionId conditionId = ConditionIdLib.from(_conditionId);
        address moduleAddr = POSITION_MANAGER.moduleById(conditionId.moduleId());

        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, conditionId.computePositionId(0), _amount);
        POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, conditionId.computePositionId(1), _amount);

        BaseModule(moduleAddr).merge(msg.sender, conditionId, _amount);

        emit CtfRouterPositionsMerged(msg.sender, conditionId, _amount);
    }

    /// @notice Redeem resolved positions for collateral payout
    /// @dev Mirrors the legacy CTF redeemPositions interface. Iterates over the provided index
    ///      sets; for each valid index (1 for YES, 2 for NO), transfers the caller's full balance
    ///      of that position to the module and calls redeem. The first two parameters
    ///      (collateralToken, parentCollectionId) are ignored for compatibility with the legacy
    ///      CTF interface.
    /// @param _conditionId The condition ID to redeem positions for
    /// @param _indexSets Array of index sets indicating which outcomes to redeem (1=YES, 2=NO)
    function redeemPositions(address, bytes32, bytes32 _conditionId, uint256[] calldata _indexSets) external {
        ConditionId conditionId = ConditionIdLib.from(_conditionId);
        address moduleAddr = POSITION_MANAGER.moduleById(conditionId.moduleId());

        for (uint256 i = 0; i < _indexSets.length; i++) {
            // Only 1 (YES) and 2 (NO) are valid for binary conditions.
            require(_indexSets[i] == 1 || _indexSets[i] == 2, InvalidIndexSet());

            uint256 index = _indexSets[i] - 1;
            PositionId positionId = conditionId.computePositionId(index);
            uint256 amount = POSITION_MANAGER.balanceOf(msg.sender, PositionId.unwrap(positionId));

            POSITION_MANAGER.unsafeTransferFrom(msg.sender, moduleAddr, positionId, amount);

            BaseModule(moduleAddr).redeem(msg.sender, positionId, amount);

            emit CtfRouterPositionRedeemed(msg.sender, positionId, amount);
        }
    }

    /*--------------------------------------------------------------
                       UUPS UPGRADE AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Only the owner can authorize upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner { }
}

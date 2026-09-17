// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Initializable } from "@solady/src/utils/Initializable.sol";
import { UUPSUpgradeable } from "@solady/src/utils/UUPSUpgradeable.sol";

import { ConditionId, ConditionIdLib, ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";

import { BaseModule } from "./abstract/BaseModule.sol";
import { BinaryMigrationMixin } from "./migration/BinaryMigrationMixin.sol";

/// @title BinaryModule
/// @author Polymarket
/// @notice Unified module for binary markets and legacy binary migration
/// @dev Registered at moduleId=1 (BINARY)
///      ConditionId encodes:
///      [moduleId(8) | baseHash(128) | arity(16) | reserved(64) | resolutionChain(16) |
///      conditionIndex(16) | outcomeIndex(8)]
///      Binary conditions use arity = 0, conditionIndex = 0, outcomeIndex = 0.
contract BinaryModule is UUPSUpgradeable, Initializable, BaseModule, BinaryMigrationMixin {
    /*--------------------------------------------------------------
                              CONSTRUCTOR
    --------------------------------------------------------------*/

    /// @notice Initialize the BinaryModule contract
    /// @param _positionManager The PositionManager contract address
    /// @param _conditionalTokens The legacy CTF contract address
    /// @param _usdceToken The USDC.e token address
    /// @param _moduleResolutionChain Chain enum allowed to resolve module conditions
    constructor(
        address _positionManager,
        address _conditionalTokens,
        address _usdceToken,
        ResolutionChain _moduleResolutionChain
    ) BaseModule(_positionManager, _moduleResolutionChain) BinaryMigrationMixin(_conditionalTokens, _usdceToken) {
        _disableInitializers();
    }

    /*--------------------------------------------------------------
                             INITIALIZER
    --------------------------------------------------------------*/

    /// @notice Initializes the proxied module owner and admin.
    /// @param _owner The owner address.
    /// @param _admin The initial admin address.
    function initialize(address _owner, address _admin) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_admin, _ROLE_0);
    }

    /*--------------------------------------------------------------
                              ONLY RESOLVER
    --------------------------------------------------------------*/

    /// @notice Report result for a binary condition
    /// @param _conditionId The condition ID to report on
    /// @param _result The result array [yes, no] summing to 1e6
    function reportResult(ConditionId _conditionId, uint256[] calldata _result)
        external
        override
        onlyResolver(_conditionId)
    {
        require(_conditionId.moduleId() == ModuleIds.BINARY, InvalidEventId());

        bool isMigrationCondition_ = _isMigrationCondition(_conditionId);
        // Resolver roles cannot resolve migration conditions.
        if (isMigrationCondition_ && hasAllRoles(msg.sender, RESOLVER_ROLE)) revert MigrationNotSupported();

        uint256[] storage storedResult = result[_conditionId];
        if (storedResult.length > 0) {
            // If the result being proposed by the resolver or bridge is different from the stored result, revert.
            // This is catastrophic and should never happen.
            if (_result.length != 2 || _result[0] != storedResult[0] || _result[1] != storedResult[1]) {
                revert ExistingPayoutMismatch();
            }

            // The condition is already resolved; if the caller is a resolver role, revert.
            // Resolvers that are calling should handle possible reverts.
            if (hasAllRoles(msg.sender, RESOLVER_ROLE)) revert ConditionAlreadyResolved();

            // The condition is already resolved; if the caller is a bridge role, return silently.
            return;
        }

        // If the condition is a migration condition, resolve it and return.
        if (isMigrationCondition_) {
            _resolveMigrationCondition(_conditionId);

            // Verify that the result being proposed by the bridge is equal to the result we just got from the CTF.
            // Something is wrong if this is not the case.
            uint256[] storage resolvedResult = result[_conditionId];
            if (_result.length != 2 || _result[0] != resolvedResult[0] || _result[1] != resolvedResult[1]) {
                revert ExistingPayoutMismatch();
            }

            return;
        }

        // The condition is not a migration condition, and has not been resolved yet.
        // (It is a native condition being resolved by a resolver or bridge).
        _storeResult(_conditionId, _result);

        emit ResultReported(msg.sender, _conditionId, _result);
    }

    /*--------------------------------------------------------------
                             MODULE IDENTITY
    --------------------------------------------------------------*/

    /// @notice Returns the module identifier for binary markets
    /// @return The BINARY module ID constant
    function moduleId() external pure override returns (uint256) {
        return ModuleIds.BINARY;
    }

    /*--------------------------------------------------------------
                                 PUBLIC
    --------------------------------------------------------------*/

    /// @notice Get condition ID from data
    /// @dev Uses conditionIndex=0 for binary
    /// @param _data Data used to derive the condition ID
    /// @return The derived condition ID
    function getConditionId(bytes calldata _data) public view returns (ConditionId) {
        return ConditionIdLib.encodeFromData(ModuleIds.BINARY, 0, _data, RESOLUTION_CHAIN);
    }

    /*--------------------------------------------------------------
                          UUPS AUTHORIZATION
    --------------------------------------------------------------*/

    /// @dev Restricts upgrades to the owner and enforces immutable config compatibility.
    /// @param newImplementation The proposed implementation contract.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        BinaryModule newImpl = BinaryModule(newImplementation);

        if (
            newImpl.moduleId() != ModuleIds.BINARY || address(newImpl.POSITION_MANAGER()) != address(POSITION_MANAGER)
                || address(newImpl.COLLATERAL_TOKEN()) != address(COLLATERAL_TOKEN)
                || address(newImpl.CONDITIONAL_TOKENS()) != address(CONDITIONAL_TOKENS) || newImpl.USDCE() != USDCE
                || newImpl.RESOLUTION_CHAIN() != RESOLUTION_CHAIN
        ) revert IncompatibleImplementation();
    }
}

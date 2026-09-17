// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { CombinatorialModule } from "@polymarket-v2/src/modules/CombinatorialModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ResolutionChain } from "@polymarket-v2/src/libraries/Ids.sol";

/// @title ModuleProxyLib
/// @author Polymarket
/// @notice Dev helper for deploying modules behind ERC1967 proxies.
library ModuleProxyLib {
    /// @notice Deploy a proxied BinaryModule.
    /// @param _positionManager The PositionManager address.
    /// @param _owner The module owner.
    /// @param _admin The initial admin.
    /// @param _conditionalTokens The legacy CTF address.
    /// @param _usdceToken The USDC.e address.
    /// @return module_ The initialized BinaryModule proxy.
    function deployBinaryModule(
        address _positionManager,
        address _owner,
        address _admin,
        address _conditionalTokens,
        address _usdceToken
    ) internal returns (BinaryModule module_) {
        address implementation = address(
            new BinaryModule(_positionManager, _conditionalTokens, _usdceToken, ResolutionChain.POLYGON)
        );
        address proxy = LibClone.deployERC1967(implementation);

        module_ = BinaryModule(proxy);
        module_.initialize(_owner, _admin);
    }

    /// @notice Deploy a proxied NegRiskModule.
    /// @param _positionManager The PositionManager address.
    /// @param _owner The module owner.
    /// @param _admin The initial admin.
    /// @param _conditionalTokens The legacy CTF address.
    /// @param _usdceToken The USDC.e address.
    /// @param _negRiskAdapter The legacy NegRisk adapter address.
    /// @return module_ The initialized NegRiskModule proxy.
    function deployNegRiskModule(
        address _positionManager,
        address _owner,
        address _admin,
        address _conditionalTokens,
        address _usdceToken,
        address _negRiskAdapter
    ) internal returns (NegRiskModule module_) {
        address implementation = address(
            new NegRiskModule(
                _positionManager, _conditionalTokens, _usdceToken, _negRiskAdapter, ResolutionChain.POLYGON
            )
        );
        address proxy = LibClone.deployERC1967(implementation);

        module_ = NegRiskModule(proxy);
        module_.initialize(_owner, _admin);
    }

    /// @notice Deploy a proxied CombinatorialModule.
    /// @param _positionManager The PositionManager address.
    /// @param _owner The module owner.
    /// @param _admin The initial admin.
    /// @return module_ The initialized CombinatorialModule proxy.
    function deployCombinatorialModule(address _positionManager, address _owner, address _admin)
        internal
        returns (CombinatorialModule module_)
    {
        address implementation = address(new CombinatorialModule(_positionManager));
        address proxy = LibClone.deployERC1967(implementation);

        module_ = CombinatorialModule(proxy);
        module_.initialize(_owner, _admin);
    }
}

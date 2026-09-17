// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { BridgeRouter } from "@polymarket-v2/src/routers/BridgeRouter.sol";
import { CtfRouter } from "@polymarket-v2/src/routers/CtfRouter.sol";
import { Router } from "@polymarket-v2/src/routers/Router.sol";

/// @title RouterSetup
/// @author Polymarket
/// @notice Dev helper for deploying routers behind ERC1967 proxies.
library RouterSetup {
    /// @notice Deploy a proxied Router.
    /// @param _positionManager The PositionManager address.
    /// @param _owner The router owner (authorizes upgrades).
    /// @return router_ The initialized Router proxy.
    function deployRouter(address _positionManager, address _owner) internal returns (Router router_) {
        address implementation = address(new Router(_positionManager));
        address proxy = LibClone.deployERC1967(implementation);

        router_ = Router(proxy);
        router_.initialize(_owner);
    }

    /// @notice Deploy a proxied BridgeRouter.
    /// @param _positionManager The PositionManager address.
    /// @param _bridge The bridge contract address.
    /// @param _owner The router owner (authorizes upgrades).
    /// @return router_ The initialized BridgeRouter proxy.
    function deployBridgeRouter(address _positionManager, address _bridge, address _owner)
        internal
        returns (BridgeRouter router_)
    {
        address implementation = address(new BridgeRouter(_positionManager, _bridge));
        address proxy = LibClone.deployERC1967(implementation);

        router_ = BridgeRouter(payable(proxy));
        router_.initialize(_owner);
    }

    /// @notice Deploy a proxied CtfRouter.
    /// @param _positionManager The PositionManager address.
    /// @param _collateralToken The collateral token address.
    /// @param _owner The router owner (authorizes upgrades).
    /// @return router_ The initialized CtfRouter proxy.
    function deployCtfRouter(address _positionManager, address _collateralToken, address _owner)
        internal
        returns (CtfRouter router_)
    {
        address implementation = address(new CtfRouter(_positionManager, _collateralToken));
        address proxy = LibClone.deployERC1967(implementation);

        router_ = CtfRouter(proxy);
        router_.initialize(_owner);
    }
}

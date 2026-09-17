// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { vm } from "@polymarket-v2/src/dev/Vm.sol";
import { USDC } from "@polymarket-v2/src/mocks/USDC.sol";
import { USDCe } from "@polymarket-v2/src/mocks/USDCe.sol";

import { DepositWallet } from "@polymarket-v2/src/collateral/mocks/DepositWallet.sol";
import { CollateralToken } from "@polymarket-v2/src/collateral/CollateralToken.sol";
import { CollateralOnramp } from "@polymarket-v2/src/collateral/CollateralOnramp.sol";
import { CollateralOfframp } from "@polymarket-v2/src/collateral/CollateralOfframp.sol";
import { PermissionedRamp } from "@polymarket-v2/src/collateral/PermissionedRamp.sol";

struct Collateral {
    CollateralToken token;
    CollateralOnramp onramp;
    CollateralOfframp offramp;
    PermissionedRamp permissionedRamp;
    USDC usdc;
    USDCe usdce;
    address vault;
}

library CollateralSetup {
    uint256 internal constant ADMIN_ROLE = 1 << 0;

    function _deploy(address _owner) internal returns (Collateral memory) {
        return _deploy(_owner, _owner);
    }

    function _deploy(address _owner, address _admin) internal returns (Collateral memory) {
        Collateral memory collateral;

        collateral.usdc = new USDC();
        collateral.usdce = new USDCe();

        collateral.vault = address(new DepositWallet(_owner));

        address collateralImplementation = address(
            new CollateralToken(address(collateral.usdc), address(collateral.usdce), address(collateral.vault))
        );

        address collateralProxy = LibClone.deployERC1967(collateralImplementation);

        vm.label(collateralImplementation, "CollateralTokenImplementation");
        vm.label(collateralProxy, "CollateralToken");

        collateral.token = CollateralToken(collateralProxy);
        collateral.token.initialize(_owner);

        collateral.onramp = new CollateralOnramp(_owner, _admin, address(collateral.token));
        collateral.offramp = new CollateralOfframp(_owner, _admin, address(collateral.token));
        collateral.permissionedRamp = new PermissionedRamp(_owner, _admin, address(collateral.token));

        vm.startPrank(_owner);
        collateral.token.addWrapper(address(collateral.onramp));
        collateral.token.addWrapper(address(collateral.offramp));
        collateral.token.addWrapper(address(collateral.permissionedRamp));

        DepositWallet(collateral.vault).approve(address(collateral.usdc), address(collateral.token), type(uint256).max);
        DepositWallet(collateral.vault).approve(address(collateral.usdce), address(collateral.token), type(uint256).max);
        vm.stopPrank();

        return collateral;
    }
}

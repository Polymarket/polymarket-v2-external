// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { LibClone } from "@solady/src/utils/LibClone.sol";

import { Collateral, CollateralSetup } from "@polymarket-v2/src/collateral/dev/CollateralSetup.sol";
import { vm } from "@polymarket-v2/src/dev/Vm.sol";
import { INegRiskAdapter } from "@polymarket-v2/src/legacy/interfaces/INegRiskAdapter.sol";
import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { NegRiskAdapterSetUp } from "@polymarket-v2/src/legacy/dev/NegRiskAdapterSetUp.sol";
import { ModuleIds } from "@polymarket-v2/src/libraries/ModuleIds.sol";
import { BinaryModule } from "@polymarket-v2/src/modules/BinaryModule.sol";
import { NegRiskModule } from "@polymarket-v2/src/modules/NegRiskModule.sol";
import { ModuleProxyLib } from "@polymarket-v2/src/modules/dev/ModuleProxyLib.sol";

import { PositionManager } from "@polymarket-v2/src/positionManager/PositionManager.sol";

struct Positions {
    PositionManager manager;
    BinaryModule binaryModule;
    NegRiskModule negRiskModule;
}

struct Legacy {
    IConditionalTokens conditionalTokens;
    INegRiskAdapter negRiskAdapter;
    address wrappedCollateral;
}

library PositionManagerSetup {
    function _deploy(address _owner, address _admin, address _creator)
        internal
        returns (Positions memory, Collateral memory, Legacy memory)
    {
        Collateral memory collateral = CollateralSetup._deploy(_owner);

        Legacy memory legacy;
        Positions memory positions;

        // legacy
        {
            (INegRiskAdapter negRiskAdapter, IConditionalTokens conditionalTokens, address wrappedCollateral) =
                NegRiskAdapterSetUp.deploy(_owner, address(collateral.usdce));

            legacy = Legacy(conditionalTokens, negRiskAdapter, wrappedCollateral);
        }

        // positions
        {
            address positionManagerImplementation = address(new PositionManager(address(collateral.token)));
            address positionManagerProxy = LibClone.deployERC1967(positionManagerImplementation);

            vm.label(positionManagerImplementation, "PositionManagerImplementation");
            vm.label(positionManagerProxy, "PositionManager");

            positions.manager = PositionManager(positionManagerProxy);
            positions.manager.initialize(_owner, _admin);

            positions.binaryModule = ModuleProxyLib.deployBinaryModule(
                address(positions.manager), _owner, _admin, address(legacy.conditionalTokens), address(collateral.usdce)
            );
            positions.negRiskModule = ModuleProxyLib.deployNegRiskModule(
                address(positions.manager),
                _owner,
                _admin,
                address(legacy.conditionalTokens),
                address(collateral.usdce),
                address(legacy.negRiskAdapter)
            );
        }

        vm.startPrank(_owner);
        collateral.token.addMinter(address(positions.binaryModule));
        collateral.token.addMinter(address(positions.negRiskModule));

        vm.stopPrank();

        vm.startPrank(_admin);

        positions.manager.addModule(address(positions.binaryModule));
        positions.manager.addModule(address(positions.negRiskModule));

        positions.binaryModule.addCreator(_creator);
        positions.negRiskModule.addCreator(_creator);
        vm.stopPrank();

        return (positions, collateral, legacy);
    }
}

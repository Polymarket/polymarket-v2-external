// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { DeployLib } from "@polymarket-v2/src/dev/DeployLib.sol";
import { vm } from "@polymarket-v2/src/dev/Vm.sol";
import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";
import { INegRiskAdapter } from "@polymarket-v2/src/legacy/interfaces/INegRiskAdapter.sol";

library NegRiskAdapterSetUp {
    function deploy(address _admin, address _usdce) public returns (INegRiskAdapter, IConditionalTokens, address) {
        address vault = vm.createWallet("vault").addr;

        IConditionalTokens conditionalTokens = IConditionalTokens(DeployLib.deployConditionalTokens());

        INegRiskAdapter negRiskAdapter =
            INegRiskAdapter(DeployLib.deployNegRiskAdapter(address(conditionalTokens), _usdce, vault));
        negRiskAdapter.addAdmin(_admin);
        negRiskAdapter.renounceAdmin();

        address wrappedCollateralToken = negRiskAdapter.wcol();

        return (negRiskAdapter, conditionalTokens, wrappedCollateralToken);
    }
}

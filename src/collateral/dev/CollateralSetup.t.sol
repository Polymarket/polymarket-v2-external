// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";

import { TestHelper } from "@polymarket-v2/src/dev/TestHelper.sol";
import { Collateral, CollateralSetup } from "./CollateralSetup.sol";

contract CollateralSetupTest is TestHelper {
    Collateral collateral;

    function setUp() public {
        collateral = CollateralSetup._deploy(owner);
    }

    function test_setup() public view {
        assertEq(collateral.token.name(), "Polymarket USD");
        assertEq(collateral.token.symbol(), "pUSD");
        assertEq(collateral.token.decimals(), 6);

        assertEq(ERC20(collateral.token.USDC()).name(), "USDC");
        assertEq(ERC20(collateral.token.USDC()).symbol(), "USDC");
        assertEq(ERC20(collateral.token.USDC()).decimals(), 6);

        assertEq(ERC20(collateral.token.USDCE()).name(), "USDCe");
        assertEq(ERC20(collateral.token.USDCE()).symbol(), "USDCe");
        assertEq(ERC20(collateral.token.USDCE()).decimals(), 6);
    }
}

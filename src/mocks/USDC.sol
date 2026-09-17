// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { ERC20Mintable } from "./ERC20Mintable.sol";

contract USDC is ERC20Mintable {
    function name() public pure override returns (string memory) {
        return "USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "USDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

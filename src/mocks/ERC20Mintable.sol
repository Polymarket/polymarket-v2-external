// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { ERC20 } from "@solady/src/tokens/ERC20.sol";

abstract contract ERC20Mintable is ERC20 {
    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Test } from "forge-std/Test.sol";

/// @title BridgeTestBase
/// @notice Shared test infrastructure for bridge tests (LZ and CCIP)
abstract contract BridgeTestBase is Test {
    /*--------------------------------------------------------------
                          CHAIN CONFIGURATION
    --------------------------------------------------------------*/

    uint256 constant HUB_CHAIN_ID = 137;
    uint256 constant SPOKE_A_CHAIN_ID = 42161;
    uint256 constant SPOKE_B_CHAIN_ID = 8453;

    /*--------------------------------------------------------------
                                 ROLES
    --------------------------------------------------------------*/

    uint256 internal constant MINTER_ROLE = 1 << 0;

    /*--------------------------------------------------------------
                             TEST ADDRESSES
    --------------------------------------------------------------*/

    address public owner;
    address public admin;
    address public creator;
    address public oracle;
    address public user;
    address public recipient;

    /*--------------------------------------------------------------
                             SETUP HELPERS
    --------------------------------------------------------------*/

    /// @notice Initialize common test addresses and fund them with ETH
    function _initTestAddresses() internal {
        owner = address(this);
        admin = vm.createWallet("admin").addr;
        creator = vm.createWallet("creator").addr;
        oracle = vm.createWallet("oracle").addr;
        user = vm.createWallet("user").addr;
        recipient = vm.createWallet("recipient").addr;

        // Fund users with ETH for bridge fees
        vm.deal(user, 100 ether);
        vm.deal(recipient, 100 ether);
        vm.deal(owner, 100 ether);
    }

    /// @notice Convert an address to bytes32 for bridge recipient params
    function _toBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Test } from "lib/forge-std/src/Test.sol";

abstract contract Addresses is Test {
    address public owner;
    address public admin;
    address public creator;
    address public oracle;
    address public operator;
    address public manager;

    address public alice;
    address public brian;
    address public carly;
    address public devin;

    constructor() {
        owner = vm.createWallet("owner").addr;
        admin = vm.createWallet("admin").addr;
        creator = vm.createWallet("creator").addr;
        oracle = vm.createWallet("oracle").addr;
        operator = vm.createWallet("operator").addr;
        manager = vm.createWallet("manager").addr;

        alice = vm.createWallet("alice").addr;
        brian = vm.createWallet("brian").addr;
        carly = vm.createWallet("carly").addr;
        devin = vm.createWallet("devin").addr;
    }
}

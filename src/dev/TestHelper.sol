// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Test } from "lib/forge-std/src/Test.sol";

import { Addresses } from "./Addresses.sol";

abstract contract TestHelper is Test, Addresses { }

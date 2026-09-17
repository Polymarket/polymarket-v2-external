// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { IConditionalTokens } from "@polymarket-v2/src/legacy/interfaces/IConditionalTokens.sol";

/// @notice Test-only recipient for the Cantina #10 regression test. If
///         `failOnReceive` is true, any ERC-1155 receiver callback reverts.
///         Used to prove that `BaseMigrationMixin`'s mint path does not
///         invoke the receiver hook (and therefore has no reentrancy
///         surface).
contract MigrationReentrancyMock {
    bool public failOnReceive;

    function setFailOnReceive(bool _fail) external {
        failOnReceive = _fail;
    }

    function approveLegacyCt(IConditionalTokens _ct, address _operator) external {
        _ct.setApprovalForAll(_operator, true);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        require(!failOnReceive, "unexpected onERC1155Received");
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        require(!failOnReceive, "unexpected onERC1155BatchReceived");
        return 0xbc197c81;
    }
}

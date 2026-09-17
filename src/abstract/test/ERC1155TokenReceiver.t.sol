// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { Test } from "lib/forge-std/src/Test.sol";

import { ERC1155TokenReceiver } from "@polymarket-v2/src/abstract/ERC1155TokenReceiver.sol";

/// @dev Concrete instance of the abstract receiver so the selectors are reachable.
contract ConcreteERC1155TokenReceiver is ERC1155TokenReceiver { }

contract ERC1155TokenReceiverTest is Test {
    ConcreteERC1155TokenReceiver internal receiver;

    function setUp() public {
        receiver = new ConcreteERC1155TokenReceiver();
    }
}

/*--------------------------------------------------------------
                       onERC1155Received
--------------------------------------------------------------*/

contract ERC1155TokenReceiverTest_onERC1155Received is ERC1155TokenReceiverTest {
    function test_returnsAcceptanceSelector() public {
        bytes4 selector =
            receiver.onERC1155Received(address(0xA1), address(0xA2), uint256(1), uint256(2), bytes("payload"));
        assertEq(selector, ERC1155TokenReceiver.onERC1155Received.selector);
    }
}

/*--------------------------------------------------------------
                    onERC1155BatchReceived
--------------------------------------------------------------*/

contract ERC1155TokenReceiverTest_onERC1155BatchReceived is ERC1155TokenReceiverTest {
    function test_returnsAcceptanceSelector() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10;
        amounts[1] = 20;

        bytes4 selector = receiver.onERC1155BatchReceived(address(0xA1), address(0xA2), ids, amounts, bytes("payload"));
        assertEq(selector, ERC1155TokenReceiver.onERC1155BatchReceived.selector);
    }
}

/*--------------------------------------------------------------
                      supportsInterface
--------------------------------------------------------------*/

contract ERC1155TokenReceiverTest_supportsInterface is ERC1155TokenReceiverTest {
    function test_supportsERC1155TokenReceiver() public view {
        assertTrue(receiver.supportsInterface(0x4e2312e0));
    }

    function test_supportsERC165() public view {
        assertTrue(receiver.supportsInterface(0x01ffc9a7));
    }

    function test_rejectsUnknown() public view {
        assertFalse(receiver.supportsInterface(0xdeadbeef));
        assertFalse(receiver.supportsInterface(bytes4(0)));
    }
}

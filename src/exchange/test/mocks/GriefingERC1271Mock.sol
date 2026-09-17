// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ECDSA } from "@solady/src/utils/ECDSA.sol";

/// @notice Test-only ERC-1271 signer that returns the magic value in the first
///         word and pads the returndata out to 1 MB. Used to verify the
///         Exchange caps returndata copies during signature validation.
contract GriefingERC1271Mock {
    address public immutable SIGNER;

    bytes4 internal constant MAGIC_VALUE_1271 = 0x1626ba7e;

    constructor(address _signer) {
        SIGNER = _signer;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (ECDSA.recover(hash, signature) != SIGNER) return bytes4(0);

        assembly {
            // Magic value in the first 4 bytes of the returned word.
            mstore(0x00, 0x1626ba7e00000000000000000000000000000000000000000000000000000000)
            // Return 1 MB: a naive caller that copies the full returndata pays
            // ~2M gas of memory expansion on top of the regular call.
            return(0x00, 0x100000)
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xbc197c81;
    }
}

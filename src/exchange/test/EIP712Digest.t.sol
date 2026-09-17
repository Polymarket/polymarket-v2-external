// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import { PositionId } from "@polymarket-v2/src/libraries/Ids.sol";
import { ORDER_TYPEHASH, Order, Side, SignatureType } from "@polymarket-v2/src/exchange/OrderStructs.sol";

import { BaseExchangeTest } from "./BaseExchangeTest.sol";

/// @notice Locks in the EIP-712 Order digest under wire-schema-level scrutiny. The Order
///         struct's Solidity field types may evolve (e.g. `uint256 tokenId` → `PositionId
///         tokenId`), but the typehash string and the abi-encoded struct hash must NEVER drift
///         without an explicit, coordinated signature-breaking deploy. These tests fail loud
///         if anything about the on-the-wire encoding changes.
contract Exchange_EIP712DigestStability is BaseExchangeTest {
    /// @dev Independent reconstruction of the EIP-712 hash. If `Exchange.hashOrder`'s assembly
    ///      ever produces something different from `keccak256(abi.encode(...))`, this fails.
    function test_orderHash_matchesIndependentComputation() public view {
        Order memory order = _fixedOrder();

        bytes32 structHash = _independentStructHash(order);
        bytes32 expected =
            keccak256(abi.encodePacked(hex"1901", _domainSeparator(address(exchange), block.chainid), structHash));

        bytes32 actual = exchange.hashOrder(order);
        assertEq(actual, expected, "Exchange.hashOrder drift");
    }

    /// @dev Locks the struct hash to a fixed value. UDVT-as-underlying refactors keep the
    ///      abi-encoded bytes byte-identical; this constant therefore must not change.
    function test_orderStructHash_baseline() public pure {
        Order memory order = _fixedOrder();
        bytes32 structHash = _independentStructHash(order);

        // Baseline captured on the current Order schema:
        //   "Order(uint256 salt,address maker,address signer,uint256 tokenId,uint256 makerAmount,"
        //   "uint256 takerAmount,uint8 side,uint8 signatureType,uint256 timestamp,bytes32 metadata,"
        //   "bytes32 builder)"
        bytes32 expected = 0x08b5c2f163715a48f38ae24e8d1b9ab97bb3d457245b854c1b6cb2a69142742a;
        assertEq(structHash, expected, "Order struct hash drift");
    }

    /*--------------------------------------------------------------
                              HELPERS
    --------------------------------------------------------------*/

    function _fixedOrder() internal pure returns (Order memory) {
        return Order({
            salt: 12345,
            maker: address(0x1234567890123456789012345678901234567890),
            signer: address(0x2345678901234567890123456789012345678901),
            tokenId: PositionId.wrap(0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20),
            makerAmount: 1_000_000,
            takerAmount: 500_000,
            side: Side.BUY,
            signatureType: SignatureType.EOA,
            timestamp: 1_700_000_000,
            metadata: bytes32(uint256(0xDEADBEEF)),
            builder: bytes32(uint256(0xFEEDFACE)),
            signature: ""
        });
    }

    function _independentStructHash(Order memory _order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                _order.salt,
                _order.maker,
                _order.signer,
                _order.tokenId,
                _order.makerAmount,
                _order.takerAmount,
                _order.side,
                _order.signatureType,
                _order.timestamp,
                _order.metadata,
                _order.builder
            )
        );
    }

    function _domainSeparator(address _verifyingContract, uint256 _chainId) internal pure returns (bytes32) {
        // EIP-712 v3 domain separator used by Exchange: name="Polymarket CTF Exchange", version="3".
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Polymarket CTF Exchange")),
                keccak256(bytes("3")),
                _chainId,
                _verifyingContract
            )
        );
    }
}

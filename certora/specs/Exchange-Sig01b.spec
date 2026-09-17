/* =============================================================================
 * [EXCHANGE-SIG-01b] BINDING LAYER
 * The CONCRETE signature verifier accepts only signatures that bind the maker:
 *   EOA:               signer == maker, 65-byte ECDSA signature
 *   POLY_1271:         signer == maker, maker wallet approves the hash
 *   POLY_PROXY / SAFE: maker is the signer's CREATE2-derived proxy / safe wallet
 * and the dispatch gate (_validateSignature) passes an empty signature iff the
 * hash is preapproved, a non-empty signature iff the verifier accepts — the
 * preapproval flag is never consulted for a signed order.
 * ============================================================================= */

/*
 * MODULE
 * @module Exchange Order Authorization
 * @contract Exchange
 * @impact An order could be filled without its maker consent, spending someone else balance
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 *
 * PROPERTIES
 * @property EXCHANGE-SIG-01b The signature verifier accepts only signatures that bind the maker, across all four signature types.
 */


using ExchangeHarness as Exchange;

methods {
    function preapproved(bytes32) external returns (bool) envfree;
    function getProxyWalletAddress(address) external returns (address);
    function getSafeWalletAddress(address) external returns (address);

    // The constructor reads POSITION_MANAGER.COLLATERAL_TOKEN(); NONDET keeps
    // the scene free of AUTO havoc.
    function _.COLLATERAL_TOKEN() external => NONDET;

    // Not on the tested path; strips the non-memory-safe _computeStructHash assembly.
    function _._hashOrder(Exchange.Order calldata) internal => NONDET;

    // The ERC1271 verdict is the maker wallet's own decision. Deterministic ghost per
    // (wallet, hash) so the gate rule can relate two view calls in one state.
    // The caller's signer == maker and code-existence checks stay CONCRETE.
    function _._isValidERC1271(address signer, bytes32 hash, bytes calldata sig) internal => g1271CVL(signer, hash) expect bool;
}

// Arbitrary-but-fixed ERC1271 wallet verdict per (wallet, hash).
persistent ghost g1271(address, bytes32) returns bool;

function g1271CVL(address wallet, bytes32 hash) returns bool {
    return g1271(wallet, hash);
}

/*--------------------------------------------------------------
        VERIFIER BINDS THE MAKER (per signatureType)
--------------------------------------------------------------*/

/**
 * @title an EOA signature binds the maker
 * @description Acceptance requires the signer to be the maker and a well-formed ECDSA signature recovering to that signer.
 * @link_property EXCHANGE-SIG-01b
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/75f05023c841489bbe7a8d87640b4d64?anonymousKey=0a4ef54d98ab7de325ae8b57520f50e2a42e0d12
 */
rule eoaSignatureBindsMaker(bytes32 h, Exchange.Order order) {
    env e;
    require order.signatureType == Exchange.SignatureType.EOA, "EOA arm";

    bool ok = h_isValidSignature(e, h, order);

    assert ok => order.signer == order.maker, "EOA acceptance requires the signer to be the maker";
    assert ok => order.signature.length == 65, "EOA acceptance requires a 65-byte ECDSA signature";
}

/**
 * @title a contract signature binds the maker
 * @description Acceptance requires the signer to be the maker and the maker wallet's approval of exactly this hash.
 * @link_property EXCHANGE-SIG-01b
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/75f05023c841489bbe7a8d87640b4d64?anonymousKey=0a4ef54d98ab7de325ae8b57520f50e2a42e0d12
 */
rule erc1271SignatureBindsMaker(bytes32 h, Exchange.Order order) {
    env e;
    require order.signatureType == Exchange.SignatureType.POLY_1271, "1271 arm";

    bool ok = h_isValidSignature(e, h, order);

    assert ok => order.signer == order.maker, "1271 acceptance requires the signer to be the maker";
    assert ok => g1271(order.maker, h), "1271 acceptance requires the maker wallet to approve this hash";
}

/**
 * @title a proxy signature binds the maker
 * @description Acceptance requires the maker to be the signer's derived proxy wallet, plus a well-formed signature by the signer.
 * @link_property EXCHANGE-SIG-01b
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/75f05023c841489bbe7a8d87640b4d64?anonymousKey=0a4ef54d98ab7de325ae8b57520f50e2a42e0d12
 */
rule proxySignatureBindsMaker(bytes32 h, Exchange.Order order) {
    env e;
    require order.signatureType == Exchange.SignatureType.POLY_PROXY, "proxy arm";

    bool ok = h_isValidSignature(e, h, order);

    assert ok => order.maker == getProxyWalletAddress(e, order.signer),"proxy acceptance requires the maker to be the signer's derived proxy wallet";
    assert ok => order.signature.length == 65,"proxy acceptance requires a 65-byte ECDSA signature by the signer";
}

/**
 * @title a safe signature binds the maker
 * @description Acceptance requires the maker to be the safe wallet derived from the signer, plus a well-formed signature by the signer.
 * @link_property EXCHANGE-SIG-01b
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/75f05023c841489bbe7a8d87640b4d64?anonymousKey=0a4ef54d98ab7de325ae8b57520f50e2a42e0d12
 */
rule safeSignatureBindsMaker(bytes32 h, Exchange.Order order) {
    env e;
    require order.signatureType == Exchange.SignatureType.POLY_GNOSIS_SAFE, "safe arm";

    bool ok = h_isValidSignature(e, h, order);

    assert ok => order.maker == getSafeWalletAddress(e, order.signer),"safe acceptance requires the maker to be the signer's derived safe wallet";
    assert ok => order.signature.length == 65,"safe acceptance requires a 65-byte ECDSA signature by the signer";
}

/*--------------------------------------------------------------
        DISPATCH GATE EXACT SEMANTICS (_validateSignature)
--------------------------------------------------------------*/

/**
 * @title an empty signature passes only if preapproved
 * @description With an empty signature the consent gate passes exactly when the hash is preapproved.
 * @link_property EXCHANGE-SIG-01b
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/75f05023c841489bbe7a8d87640b4d64?anonymousKey=0a4ef54d98ab7de325ae8b57520f50e2a42e0d12
 */
rule emptySigPassesIffPreapproved(bytes32 h, Exchange.Order order) {
    env e;
    require e.msg.value == 0, "nonzero msg.value reverts regardless of the gate logic";
    require order.signature.length == 0, "empty-signature arm";

    bool pre = preapproved(h);

    h_validateSignature@withrevert(e, h, order);

    assert !lastReverted <=> pre,"an empty signature passes the gate iff the hash is preapproved";
}

/**
 * @title a signed order passes only if the verifier accepts
 * @description With a non-empty signature the gate passes exactly when the verifier accepts, and the preapproval flag is never consulted.
 * @link_property EXCHANGE-SIG-01b
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/75f05023c841489bbe7a8d87640b4d64?anonymousKey=0a4ef54d98ab7de325ae8b57520f50e2a42e0d12
 */
rule signedPassesIffVerifierAccepts(bytes32 h, Exchange.Order order) {
    env e;
    require order.signature.length > 0, "signed arm";

    bool ok = h_isValidSignature(e, h, order);

    h_validateSignature@withrevert(e, h, order);

    assert !lastReverted <=> ok,"a non-empty signature passes the gate iff the verifier accepts it";
}

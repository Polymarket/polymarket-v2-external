// ============================================================
// Properties:
//   OO-PRICE-01   `_isValidBinaryPrice` accepts EXACTLY {YES, NO} for every market type,
//                 plus P3 only under BINARY, and rejects every negative price (P4).
//   OO-PAYOUT-01  `OptimisticOraclePayoutLib.priceToPayouts` lemmas, stated on the
//                 library's own domain: n == 1 maps YES -> D, P3 -> D/2 and EVERY other
//                 price -> 0 (total, never reverts); n > 1 is winner-takes-all and
//                 conserving (length n, slot floor(p/1e18) holds RESULT_DENOMINATOR,
//                 every other slot zero) whenever the price is non-negative with an
//                 in-range winner index.
//
// The atomic-neg-risk branch is deliberately NOT covered here: it bypasses
// `_isValidBinaryPrice` entirely, so its exact acceptance set (OO-ATOMIC-01) is proved
// against the real relay in OOReporterRelay.spec.
//
// Bound: rules that call `priceToPayouts` are stated for outcome counts n <= 3.
// ============================================================


/*
 * MODULE
 * @module OOReporterModule Result Translation
 * @contract OOReporterModule
 * @impact A settled price could translate into the wrong payout vector, settling the market on the wrong outcome
 *
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * PROPERTIES
 * @property OO-PRICE-01 The binary price validator accepts a limited set of prices for every market type.
 * @property OO-PAYOUT-01 The price-to-payouts conversion is winner-takes-all and conserving.
 */

import "../summaries/OptimisticOraclePayout_constants.spec";

methods {
    // ---- pure harness wrappers (certora/harnesses/OOReporterModule.sol) ----
    function isValidBinaryPriceExt(int256, uint8) external returns (bool) envfree;
    function priceToPayoutsLen(int256, uint16) external returns (uint256) envfree;
    function priceToPayoutsAt(int256, uint16, uint256) external returns (uint256) envfree;
    function arityOfRequestId(bytes32) external returns (uint256) envfree;
    function isCanonicalRequestId(bytes32) external returns (bool) envfree;
    function asUint(bytes32) external returns (uint256) envfree;
}

definition PAYOUT_BOUND() returns mathint = 3;

// ------------------------------------------------------------
// Reference specification of the acceptance set
// ------------------------------------------------------------

// The exact set `_isValidBinaryPrice` is supposed to accept, restated independently of the
// implementation: {YES, NO} for every market type, plus P3 only under BINARY. The guard
// takes no outcome count — the request shape is enforced separately by the aggregator
// (`resultLength == 1` at init, `_validateResult` on every report).
function validPriceSpec(mathint p, uint8 mt) returns bool {
    return p == YES_PRICE() || p == NO_PRICE() || (mt == BINARY() && p == P3_PRICE());
}

// ------------------------------------------------------------
// OO-PRICE-01 — exact acceptance set
// ------------------------------------------------------------

/**
 * @title valid prices are exactly the catalogued set
 * @description The binary price validator accepts exactly the catalogued price set and nothing else.
 * @link_property OO-PRICE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d662747b72a2401cbb42d0c19f44dec8?anonymousKey=3b31f7ba908696ded3c4ce271d9553c7dec49be0
 */
rule validPriceExactSet(int256 p, uint8 mt) {
    assert isValidBinaryPriceExt(p, mt) <=> validPriceSpec(to_mathint(p), mt),
        "the accepted price set differs from the specification";
}

/**
 * @title P3 is accepted only for binary
 * @description The unresolvable price is accepted under the binary market type and rejected under every other, so an incremental neg-risk subcondition cannot resolve to it.
 * @link_property OO-PRICE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d662747b72a2401cbb42d0c19f44dec8?anonymousKey=3b31f7ba908696ded3c4ce271d9553c7dec49be0
 */
rule p3AcceptedOnlyForBinary(uint8 mt) {
    int256 p3;
    require to_mathint(p3) == P3_PRICE(), "the P3 price";

    assert isValidBinaryPriceExt(p3, mt) <=> mt == BINARY(),
        "P3 acceptance is not exclusive to BINARY requests";
}

/**
 * @title negative prices are rejected
 * @description Every negative price is rejected for every market type.
 * @link_property OO-PRICE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d662747b72a2401cbb42d0c19f44dec8?anonymousKey=3b31f7ba908696ded3c4ce271d9553c7dec49be0
 */
rule negativePricesRejected(int256 p, uint8 mt) {
    require p < 0, "negative prices, P4 = type(int256).min included";

    assert !isValidBinaryPriceExt(p, mt), "a negative price was accepted";
}

// ------------------------------------------------------------
// OO-PAYOUT-01 — well-formedness and conservation
// ------------------------------------------------------------

/**
 * @title payouts are winner-takes-all pointwise
 * @description Multi-outcome conversion puts the full denominator in the winner slot and zero in every other slot.
 * @link_property OO-PAYOUT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d662747b72a2401cbb42d0c19f44dec8?anonymousKey=3b31f7ba908696ded3c4ce271d9553c7dec49be0
 */
rule payoutsPointwiseShape(int256 p, uint16 n, uint256 k) {
    require n > 1 && to_mathint(n) <= PAYOUT_BOUND(), "bounded proof: n <= 3";
    require to_mathint(p) >= 0 && to_mathint(p) / YES_PRICE() < to_mathint(n),
        "the library's n > 1 domain: non-negative price with an in-range winner index";

    mathint winner = to_mathint(p) / YES_PRICE();
    mathint expected = to_mathint(k) == winner ? RESULT_DENOMINATOR() : 0;

    assert to_mathint(priceToPayoutsAt(p, n, k)) == expected,
        "a payout slot holds neither the full denomination at the winner index nor zero";
}

/**
 * @title single-outcome payout shape
 * @description Single-outcome conversion is total: it maps YES and the unresolvable price to their denominations and every other price to zero.
 * @link_property OO-PAYOUT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d662747b72a2401cbb42d0c19f44dec8?anonymousKey=3b31f7ba908696ded3c4ce271d9553c7dec49be0
 */
rule payoutsSingleOutcomeShape(int256 p) {
    // The initial 0 is the expectation for every price that is neither YES nor P3.
    // `priceToPayouts` writes nothing on that branch, leaving the zero.
    mathint expected = 0;
    if (to_mathint(p) == YES_PRICE()) {
        expected = RESULT_DENOMINATOR();
    } else if (to_mathint(p) == P3_PRICE()) {
        expected = RESULT_DENOMINATOR() / 2;
    }

    assert priceToPayoutsLen(p, 1) == 1, "a single-outcome conversion produced the wrong length";
    assert to_mathint(priceToPayoutsAt(p, 1, 0)) == expected,
        "the single payout slot does not hold the YES/NO/P3 denomination";
}

/**
 * @title payouts conserve the denominator
 * @description The converted vector sums to the result denominator for multi-outcome events, and to the mapped denomination for single-outcome ones.
 * @link_property OO-PAYOUT-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d662747b72a2401cbb42d0c19f44dec8?anonymousKey=3b31f7ba908696ded3c4ce271d9553c7dec49be0
 */
rule payoutsSumIsDenominator(int256 p, uint16 n) {
    require n >= 1 && to_mathint(n) <= PAYOUT_BOUND(), "bounded proof: n <= 3";
    require to_mathint(n) > 1 => (to_mathint(p) >= 0 && to_mathint(p) / YES_PRICE() < to_mathint(n)),
        "the library's n > 1 domain: non-negative price with an in-range winner index";

    mathint slot0 = to_mathint(priceToPayoutsAt(p, n, 0));
    mathint slot1 = 0;
    if (to_mathint(n) > 1) {
        slot1 = to_mathint(priceToPayoutsAt(p, n, 1));
    }
    mathint slot2 = 0;
    if (to_mathint(n) > 2) {
        slot2 = to_mathint(priceToPayoutsAt(p, n, 2));
    }
    mathint total = slot0 + slot1 + slot2;

    if (n == 1) {
        mathint expected = 0;
        if (to_mathint(p) == YES_PRICE()) {
            expected = RESULT_DENOMINATOR();
        } else if (to_mathint(p) == P3_PRICE()) {
            expected = RESULT_DENOMINATOR() / 2;
        }
        assert total == expected, "a single-outcome payout vector does not sum to its price denomination";
    } else {
        assert total == RESULT_DENOMINATOR(), "a multi-outcome payout vector does not sum to RESULT_DENOMINATOR";
    }
}

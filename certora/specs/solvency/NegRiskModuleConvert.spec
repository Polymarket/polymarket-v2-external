// Dedicated solvency rule for convert(address,EventId,uint256,uint256)

/*
 * MODULE
 * @module NegRiskModule Global Solvency
 * @contract NegRiskModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 *
 * PROPERTIES
 * @property NEGRISK-GLOB-SOLVENCY NegRiskModule preserves the collateral backing of every outstanding position it has minted, under every possible market resolution.
 */

import "NegRiskSolvencyBase.spec";

/**
 * @title solvency preserved, neg-risk convert
 * @description convert preserves the backing inequality against the per-event scaled liability.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/2c7ee7ce587042ab988b1ccf70a22902?anonymousKey=c1e5dcbb78da9aea85620e53e42012464a95ae94
 */
rule solvencyPreservedConvert(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";

    address to;
    NegRiskModule.EventId eventId;
    uint256 conditionIndex;
    uint256 amount;

    mathint assetsBefore = countedAssets();
    mathint pusdBefore = ghostPusdSupply;
    mathint liabBefore = liabilityScaled;
    require RESULT_DENOMINATOR() * assetsBefore >= RESULT_DENOMINATOR() * pusdBefore + liabBefore,
        "solvency holds before";

    NegRiskModule.convert(e, to, eventId, conditionIndex, amount);

    // (1) convert only mints/burns positions; no collateral moves.
    assert countedAssets() == assetsBefore,
        "convert must not move counted assets";
    // (2) convert never mints or burns pUSD.
    assert ghostPusdSupply == pusdBefore,
        "convert must not change the pUSD supply";
    // (3) The nonlinear kernel, isolated: burning `amount` NO on the source drops the
    //     D·ΣN baseline by D·amount, while raising every w_i by `amount` adds at most
    //     Σ_resolved r0_i·amount + (D − S)·amount <= D·amount — the event liability
    //     never increases.
    assert liabilityScaled <= liabBefore,
        "convert must not increase the scaled liability";
    // (4) Linear given (1)-(3) and the pre-state inequality.
    assert solvencyScaledHolds(),
        "convert broke D*(vault+reserve) >= D*pUSD totalSupply + scaled liability";
}

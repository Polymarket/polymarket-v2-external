// Direct (computational) CVL summaries for Solady FixedPointMathLib.mulDiv / mulDivUp.
// These replace the assembly full-width implementations with plain `x * y / d` arithmetic, so
// the Prover reasons about real (nonlinear) integer math rather than the assembly bodies. No
// uninterpreted ghost / axioms — the result is the exact floor/ceil value.
methods {
    function _.mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal => cvlMulDivDown(x, y, denominator) expect uint256;

    function _.mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal => cvlMulDivUp(x, y, denominator) expect uint256;
}

/*
 * @title `mulDiv` implementation in CVL (rounding down)
 * @notice Reverts only on a zero denominator; the require_uint256 prunes results that overflow
 *         uint256 (mirroring the real revert-on-overflow).
 */
function cvlMulDivDown(mathint x, mathint y, mathint denominator) returns uint256 {
    require denominator != 0;
    return require_uint256(x * y / denominator);
}

/*
 * @title `mulDivUp` implementation in CVL (rounding up)
 */
function cvlMulDivUp(mathint x, mathint y, mathint denominator) returns uint256 {
    require denominator != 0;
    return require_uint256((x * y + denominator - 1) / denominator);
}
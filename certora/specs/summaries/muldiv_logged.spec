// ============================================================
// muldiv_logged.spec — muldiv.spec plus a per-call operand/result log.
//
// The SAME direct (computational) CVL summaries for Solady FixedPointMathLib.mulDiv / mulDivUp
// as muldiv.spec — exact floor/ceil via plain x * y / d arithmetic — extended with a call log in
// ghost state.
//
// MUST stay semantically identical to muldiv.spec (same requires, same require_uint256 overflow
// pruning, same return values): CombinatorialPayoutEquivalence.spec certifies the payout
// summaries against THIS mulDiv model while the solvency scene uses muldiv.spec, so the two must
// model the same function for the certification to transfer. Only the logging — invisible to the
// summarized code — is added.
//
// The log gives equivalence rules a handle on the REAL code's intermediate mulDiv values, which
// CVL cannot otherwise observe: call i's operands are (gMdX[i], gMdY[i], gMdD[i]) and its result
// gMdOut[i], in call order; gMdCount is the number of calls so far (the gMdu* family likewise
// for mulDivUp). Rules reading the log MUST `require gMdCount == 0` (resp. gMduCount == 0) at
// entry — ghosts are otherwise havoc'd at rule start (the CombinatorialRefineCompress lesson).
//
// Do NOT import together with muldiv.spec — duplicate summaries for the same methods.
// ============================================================

methods {
    function _.mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal => cvlMulDivDownLogged(x, y, denominator) expect uint256;

    function _.mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal => cvlMulDivUpLogged(x, y, denominator) expect uint256;
}

// ---- mulDiv (floor) call log ----
ghost mathint gMdCount;
ghost mapping(mathint => mathint) gMdX;
ghost mapping(mathint => mathint) gMdY;
ghost mapping(mathint => mathint) gMdD;
ghost mapping(mathint => mathint) gMdOut;

// ---- mulDivUp (ceil) call log ----
ghost mathint gMduCount;
ghost mapping(mathint => mathint) gMduX;
ghost mapping(mathint => mathint) gMduY;
ghost mapping(mathint => mathint) gMduD;
ghost mapping(mathint => mathint) gMduOut;

/*
 * @title `mulDiv` implementation in CVL (rounding down), logged.
 * @notice Same semantics as muldiv.spec's cvlMulDivDown: reverts only on a zero denominator;
 *         the require_uint256 prunes results that overflow uint256 (mirroring the real
 *         revert-on-overflow). Logs (x, y, d, out) at index gMdCount, then increments it.
 */
function cvlMulDivDownLogged(mathint x, mathint y, mathint denominator) returns uint256 {
    require denominator != 0;
    uint256 out = require_uint256(x * y / denominator);
    gMdX[gMdCount] = x;
    gMdY[gMdCount] = y;
    gMdD[gMdCount] = denominator;
    gMdOut[gMdCount] = out;
    gMdCount = gMdCount + 1;
    return out;
}

/*
 * @title `mulDivUp` implementation in CVL (rounding up), logged.
 * @notice Same semantics as muldiv.spec's cvlMulDivUp. Logs at index gMduCount.
 */
function cvlMulDivUpLogged(mathint x, mathint y, mathint denominator) returns uint256 {
    require denominator != 0;
    uint256 out = require_uint256((x * y + denominator - 1) / denominator);
    gMduX[gMduCount] = x;
    gMduY[gMduCount] = y;
    gMduD[gMduCount] = denominator;
    gMduOut[gMduCount] = out;
    gMduCount = gMduCount + 1;
    return out;
}

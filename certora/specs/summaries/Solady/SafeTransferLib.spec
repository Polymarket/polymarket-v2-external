// Summarization of Solady's SafeTransferLib library functions.
// Based on Balancer's approach to SafeERC20, adapted for Polymarket V2.
//
// These internal library calls compile to inline assembly (raw `call`s to the
// token), which the Prover cannot resolve on its own. Each is replaced with a
// deterministic CVL body that tracks balances/allowances in ghost state.
//
// Usage in CollateralToken:
//   - wrap()   -> _asset.safeTransfer(VAULT, amount)              (sender = this contract)
//   - unwrap() -> _asset.safeTransferFrom(VAULT, to, amount)      (sender = explicit `from`)

methods {
    // For `safeTransfer`, the executing contract holds the tokens, so it is the
    // `from`. `calledContract` is that executing contract.
    function _.safeTransfer(address token, address to, uint256 amount) internal =>
        safeTransferCVL(token, calledContract, to, amount) expect void;

    // For `safeTransferFrom`, `from` is an explicit argument (e.g. the VAULT), so
    // it is used directly rather than `calledContract`.
    function _.safeTransferFrom(address token, address from, address to, uint256 amount) internal =>
        safeTransferFromCVL(token, from, to, amount) expect void;

    function _.safeApprove(address token, address spender, uint256 amount) internal =>
        safeApproveCVL(token, calledContract, spender, amount) expect void;
}

/// Ghost variables to track token state.
/// Persistent so AUTO-havoc'd external calls (unresolved callees in a parametric
/// contract / out-of-scene callee) cannot scramble it. Only the explicit CVL
/// bodies below (safeTransfer/safeTransferFrom/mergeCredit) move pUSD, and each
/// is reached only via a summarized call, so persistence conservatively removes
/// spurious havoc without losing real updates.
/// token => account => balance
persistent ghost mapping(address => mapping(address => uint256)) balanceByToken;

/// token => owner => spender => allowance
ghost mapping(address => mapping(address => mapping(address => uint256))) allowanceByToken;

/// CVL implementation of safeTransfer.
function safeTransferCVL(address token, address from, address to, uint256 amount) {
    if (balanceByToken[token][from] < amount) {
        revert();
    }

    balanceByToken[token][from] = assert_uint256(balanceByToken[token][from] - amount);
    balanceByToken[token][to] = require_uint256(balanceByToken[token][to] + amount);
}

/// CVL implementation of safeTransferFrom.
function safeTransferFromCVL(address token, address from, address to, uint256 amount) {
    if (balanceByToken[token][from] < amount) {
        revert();
    }

    balanceByToken[token][from] = assert_uint256(balanceByToken[token][from] - amount);
    balanceByToken[token][to] = require_uint256(balanceByToken[token][to] + amount);
}

/// CVL implementation of safeApprove.
function safeApproveCVL(address token, address owner, address spender, uint256 amount) {
    allowanceByToken[token][owner][spender] = amount;
}

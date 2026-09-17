// ============================================================
// ERC1155.spec — Solady ERC1155 ghost model + summaries
//
// Solady's ERC1155 stores per-user token balances and operator approvals
// behind keccak256 slots computed in inline assembly using the
// `_ERC1155_MASTER_SLOT_SEED` pattern. That computation breaks CVL's
// points-to / storage analysis, producing "Storage analysis / Storage
// splitting / Pointer analysis failed" alerts for every storage-touching
// ERC1155 function.
//
// Two slot layouts are used throughout:
//
//   Balance slot  : keccak256(0x00, 0x40)
//     memory layout: [id (32B)] [seed | shl(96, owner) (32B)]
//
//   Approval slot : keccak256(0x0c, 0x34)
//     memory layout: [operator (12B high)] [seed | shl(96, owner) (32B)]
//
// We replace both storage layouts with ghost mappings and intercept every
// function that reads or writes them.
//
//   Reads (view):
//     * isApprovedForAll -> isApprovedForAllCVL
//     * balanceOf / balanceOfBatch summaries are OPT-IN via ERC1155Reads.spec
//       (their CVL helpers balanceOfCVL / balanceOfBatchCVL are defined here).
//
//   Single-element writes:
//     * setApprovalForAll   -> setApprovalForAllCVL   (uses caller via env)
//     * _setApprovalForAll  -> setApprovalForAllByCVL (explicit `by`)
//     * _mint               -> mintCVL
//     * safeTransferFrom    -> erc1155SafeTransferFromCVL    (public path, not a wrapper)
//     * _safeTransfer (6-arg) -> safeTransferByCVL   (5-arg wrapper calls 6-arg)
//
//   Batch writes (loop-unrolled up to 3 — prover loop-iteration limit):
//     * safeBatchTransferFrom  -> safeBatchTransferFromCVL  (indices 0-2, uses env)
//     * _batchMint             -> batchMintCVL              (indices 0-2)
//     * _safeBatchTransfer (6-arg) -> safeBatchTransferByCVL (indices 0-2)
//
//   Burn summaries (_burn 4-arg -> burnByCVL, _batchBurn 4-arg -> batchBurnByCVL)
//   are OPT-IN via ERC1155Burn.spec — see the note in the methods block.
//   The burnByCVL / batchBurnByCVL helpers are defined here regardless.
// ============================================================

methods {
    // ---- Read functions ----
    // NOTE: the balanceOf / balanceOfBatch summaries are intentionally NOT declared
    // here. They live in the opt-in ERC1155Reads.spec, so that scenes can choose
    // whether balance reads answer from the ghost model (import it) or from real
    // storage via the native Solady assembly.
    function _.isApprovedForAll(address owner, address operator) internal =>
        isApprovedForAllCVL(owner, operator) expect bool;
    // ---- Single-element writes ----
    // setApprovalForAll uses caller() in assembly — recover the sender via `with (env e)`.
    function _.setApprovalForAll(address operator, bool isApproved) internal with (env e) =>
        setApprovalForAllCVL(e, operator, isApproved) expect void;
    // Internal variant takes explicit `by` (no msg.sender dependency).
    function _._setApprovalForAll(address by, address operator, bool isApproved) internal =>
        setApprovalForAllByCVL(by, operator, isApproved) expect void;
    // Mint: increases balance of `to`. `data` is memory (internal function).
    function _._mint(address to, uint256 id, uint256 amount, bytes memory data) internal =>
        mintCVL(to, id, amount) expect void;
    // NOTE: the _burn / _batchBurn summaries are intentionally NOT declared here.
    // They live in the opt-in ERC1155Burn.spec, so that scenes can choose whether
    // burn paths are ghost-modeled (import it) or run Solady's real assembly
    // (omit it — used by certora/specs/solvency/PositionManager.spec to prove
    // burn integrity on the real code).
    // safeTransferFrom is public — `data` is calldata.
    function _.safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data)
        internal with (env e) => erc1155SafeTransferFromCVL(e, from, to, id, amount) expect void;
    // 6-arg _safeTransfer is internal — `data` is memory.
    function _._safeTransfer(address by, address from, address to, uint256 id, uint256 amount, bytes memory data)
        internal => safeTransferByCVL(by, from, to, id, amount) expect void;

    // ---- Batch writes (unrolled up to 3 elements) ----
    // safeBatchTransferFrom is public — arrays and data are calldata.
    function _.safeBatchTransferFrom(
        address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data
    ) internal with (env e) => safeBatchTransferFromCVL(e, from, to, ids, amounts) expect void;
    // _batchMint is internal — arrays and data are memory.
    function _._batchMint(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data) internal =>
        batchMintCVL(to, ids, amounts) expect void;
    // 6-arg _safeBatchTransfer is internal — arrays and data are memory.
    function _._safeBatchTransfer(
        address by, address from, address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data
    ) internal => safeBatchTransferByCVL(by, from, to, ids, amounts) expect void;
}

// ------------------------------------------------------------
// Ghost model
// ------------------------------------------------------------

// ghostBalance[owner][id] — token balance (mathint avoids overflow in ghost arithmetic).
ghost mapping(address => mapping(uint256 => mathint)) ghostBalance;
// ghostApproved[owner][operator] — isApprovedForAll state.
ghost mapping(address => mapping(address => bool)) ghostApproved;
// ghostSupply[id] — net total supply per token id in the ghost model:
// increased only by mintCVL, decreased only by burnByCVL. All transfer helpers
// (erc1155SafeTransferFromCVL / safeTransferByCVL and their batch wrappers)
// conserve it by construction.
// NOTE: PositionManager's `external` assembly mutators are ghost-visible only at
// the EXTERNAL call boundary (exact external summaries declared in
// PositionManager_base_summaries.spec — internal-visibility summaries cannot
// attach to `external` functions). Direct CVL calls and parametric targets always
// execute the real bodies; their gating and integrity are proven on the real code
// in certora/specs/solvency/PositionManager.spec.
// init_state: a freshly deployed system has zero supply of every id. Needed by invariant
// base cases whose antecedent is live at the constructor state (e.g. ComboSolvency01's
// preResolutionSolvency len==0 clause); a strictly-true assumption for every other spec.
ghost mapping(uint256 => mathint) ghostSupply {
    init_state axiom forall uint256 id. ghostSupply[id] == 0;
}

// ------------------------------------------------------------
// Read helpers
// ------------------------------------------------------------

function balanceOfCVL(address owner, uint256 id) returns uint256 {
    return require_uint256(ghostBalance[owner][id]);
}

function isApprovedForAllCVL(address owner, address operator) returns bool {
    return ghostApproved[owner][operator];
}

// balanceOfBatch: unrolled read up to 3 elements.
// `result` is a fresh nondeterministic array; each element is constrained to the
// corresponding ghostBalance entry.  The prover treats each `require` as an axiom
// that pins result[i] to the ghost value — equivalent to constructing the array
// from ghost reads, but without needing CVL array-construction syntax.
function balanceOfBatchCVL(address[] owners, uint256[] ids) returns uint256[] {
    uint256[] result;
    require result.length == ids.length;
    if (ids.length > 0) {
        require result[0] == require_uint256(ghostBalance[owners[0]][ids[0]]);
    }
    if (ids.length > 1) {
        require result[1] == require_uint256(ghostBalance[owners[1]][ids[1]]);
    }
    if (ids.length > 2) {
        require result[2] == require_uint256(ghostBalance[owners[2]][ids[2]]);
    }
    return result;
}

// ------------------------------------------------------------
// Approval write helpers
// ------------------------------------------------------------

// setApprovalForAll (public): caller is the owner, recovered from the env.
function setApprovalForAllCVL(env e, address operator, bool isApproved) {
    ghostApproved[e.msg.sender][operator] = isApproved;
}

// _setApprovalForAll (internal): explicit owner `by`.
function setApprovalForAllByCVL(address by, address operator, bool isApproved) {
    ghostApproved[by][operator] = isApproved;
}

// ------------------------------------------------------------
// Mint / burn helpers
// ------------------------------------------------------------

// _mint: increase balance of `to` for token `id`.
function mintCVL(address to, uint256 id, uint256 amount) {
    if (to == 0) { revert(); }
    mathint newBal = ghostBalance[to][id] + to_mathint(amount);
    ghostBalance[to][id] = newBal;
    ghostSupply[id] = ghostSupply[id] + to_mathint(amount);
}

// _burn (4-arg): decrease balance of `from`, with optional `by` authorization check.
function burnByCVL(address by, address from, uint256 id, uint256 amount) {
    if (by != 0 && by != from) {
        if (!ghostApproved[from][by]) { revert(); }
    }
    mathint amt = to_mathint(amount);
    if (ghostBalance[from][id] < amt) { revert(); }
    mathint newBal = ghostBalance[from][id] - amt;
    ghostBalance[from][id] = newBal;
    ghostSupply[id] = ghostSupply[id] - amt;
}

// ------------------------------------------------------------
// Transfer helpers
// ------------------------------------------------------------

// safeTransferFrom (public): authorization via msg.sender.
function erc1155SafeTransferFromCVL(env e, address from, address to, uint256 id, uint256 amount) {
    if (to == 0) { revert(); }
    if (from != e.msg.sender && !ghostApproved[from][e.msg.sender]) { revert(); }
    mathint amt = to_mathint(amount);
    if (ghostBalance[from][id] < amt) { revert(); }
    // Self-transfer (from == to): balance is unchanged in Solidity; skip writes.
    if (from != to) {
        mathint fromBal = ghostBalance[from][id];
        mathint toBal = ghostBalance[to][id];
        ghostBalance[from][id] = fromBal - amt;
        ghostBalance[to][id] = toBal + amt;
    }
}

// _safeTransfer (6-arg internal): authorization via explicit `by`.
function safeTransferByCVL(address by, address from, address to, uint256 id, uint256 amount) {
    if (to == 0) { revert(); }
    if (by != 0 && by != from) {
        if (!ghostApproved[from][by]) { revert(); }
    }
    mathint amt = to_mathint(amount);
    if (ghostBalance[from][id] < amt) { revert(); }
    // Self-transfer (from == to): balance is unchanged in Solidity; skip writes.
    if (from != to) {
        mathint fromBal = ghostBalance[from][id];
        mathint toBal = ghostBalance[to][id];
        ghostBalance[from][id] = fromBal - amt;
        ghostBalance[to][id] = toBal + amt;
    }
}

// ------------------------------------------------------------
// Batch helpers (unrolled to 3 — prover loop-iteration limit)
// ------------------------------------------------------------

// safeBatchTransferFrom (public): auth + per-element transfer, indices 0-2.
function safeBatchTransferFromCVL(env e, address from, address to, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { erc1155SafeTransferFromCVL(e, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { erc1155SafeTransferFromCVL(e, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { erc1155SafeTransferFromCVL(e, from, to, ids[2], amounts[2]); }
}

// _batchMint: per-element mint, indices 0-2.
function batchMintCVL(address to, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { mintCVL(to, ids[0], amounts[0]); }
    if (ids.length > 1) { mintCVL(to, ids[1], amounts[1]); }
    if (ids.length > 2) { mintCVL(to, ids[2], amounts[2]); }
}

// _batchBurn (4-arg): per-element burn with optional by-auth, indices 0-2.
function batchBurnByCVL(address by, address from, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { burnByCVL(by, from, ids[0], amounts[0]); }
    if (ids.length > 1) { burnByCVL(by, from, ids[1], amounts[1]); }
    if (ids.length > 2) { burnByCVL(by, from, ids[2], amounts[2]); }
}

// _safeBatchTransfer (6-arg): per-element transfer with explicit by-auth, indices 0-2.
function safeBatchTransferByCVL(address by, address from, address to, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { safeTransferByCVL(by, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { safeTransferByCVL(by, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { safeTransferByCVL(by, from, to, ids[2], amounts[2]); }
}

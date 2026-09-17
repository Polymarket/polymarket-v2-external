// ============================================================
// PositionManager_full_summaries.spec — faithful (revert + effect) PositionManager
// token-layer summaries.
//
// This is the canonical home for the auth-aware PositionManager token summaries that
// were proven equivalent to the real assembly in
// certora/specs/eq/PositionManagerSummaryEquivalence.spec (rules mint/burn/transfer/
// batchMint/batchBurn/batchTransferSummaryEquivalence). It is self-contained:
//
//   * Ghost model + core CVL helpers — copied from Solady/ERC1155.spec, so this file
//     can be imported WITHOUT Solady/ERC1155.spec (importing both would double-define
//     the ghosts). The ONE deliberate omission is the `isApprovedForAll` read-summary
//     methods line: it is OPT-IN per consumer (mirroring the ERC1155.spec /
//     ERC1155Reads.spec split), because some scenes need approvals answered from the
//     ghost (solvency) while others must read REAL storage so a ghost<->real coupling
//     is not vacuous (the equivalence spec).
//
//   * Auth-aware wrappers (mintWithAuthCVL, burnWithAuthCVL, transferWithAuthCVL and
//     the batch variants) — model the COMPLETE revert set of PositionManager's external
//     assembly mutators: the non-payable msg.value check, the onlyModuleByPositionId(s)
//     authorization modifier, the to == 0 / uint256-overflow / per-element
//     insufficient-balance checks. These are what the equivalence rules certified.
//
// Module-id extraction uses DIVISION (positionId / 2^248), NOT a bit shift, so the
// wrappers stay inside the non-bitvector solver of the solvency scene
// (certora/confs/solvency/PositionManager.conf has no useBitVectorTheory). For uint256
// this equals the real shr(248, .) and the equivalence rules re-verify with it under
// the bitvector-enabled equivalence conf.
//
// Consumers:
//   * certora/specs/eq/PositionManagerSummaryEquivalence.spec — imports this, adds
//     `balanceOf`/`isApprovedForAll` as envfree REAL reads, runs the equivalence rules.
//   * certora/specs/solvency/BinarySolvencyBase.spec (shared by the solvency
//     PositionManager.spec / BinaryModule.spec children) — imports this INSTEAD of
//     Solady/ERC1155.spec, re-adds the `isApprovedForAll` read summary, and composes
//     the wrappers with liability bookkeeping (onSupplyChange).
// ============================================================

methods {
    // ---- PositionManager auth state (REAL reads, both consumers agree) ----
    function PositionManager.moduleById(uint256) external returns (address) envfree;
    function PositionManager.crossModuleAuth(address) external returns (bool) envfree;

    // ---- Solady ERC1155 write summaries (ghost-modeled) ----
    // NOTE: the `isApprovedForAll` read summary is intentionally NOT declared here — it
    // is opt-in per consumer (see header). The `balanceOf`/`balanceOfBatch` read
    // summaries are likewise omitted (opt-in, mirroring ERC1155Reads.spec).
    // setApprovalForAll uses caller() in assembly — recover the sender via `with (env e)`.
    function _.setApprovalForAll(address operator, bool isApproved) internal with (env e) =>
        setApprovalForAllCVL(e, operator, isApproved) expect void;
    // Internal variant takes explicit `by` (no msg.sender dependency).
    function _._setApprovalForAll(address by, address operator, bool isApproved) internal =>
        setApprovalForAllByCVL(by, operator, isApproved) expect void;
    // Mint: increases balance of `to`. `data` is memory (internal function).
    function _._mint(address to, uint256 id, uint256 amount, bytes memory data) internal =>
        mintCVL(to, id, amount) expect void;
    // _batchMint is internal — arrays and data are memory.
    function _._batchMint(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data) internal =>
        batchMintCVL(to, ids, amounts) expect void;

    // Single-element mint: reuses mintCVL from ERC1155.spec.
    function _.mint(address _to, uint256 _positionId, uint256 _amount) external =>
        mintCVL(_to, _positionId, _amount) expect void;

    // Batch mint: unrolled up to 3 elements; passes arrays to the CVL function.
    // External function — arrays are calldata.
    function _.batchMint(address _to, uint256[] _positionIds, uint256[] _amounts) external with (env e) =>
        batchMintWithAuthCVL(e, _to, _positionIds, _amounts) expect void;

    // Single burn: debits the CALLER (the module holds the tokens). by = 0 mirrors
    // Solady's 3-arg _burn wrapper (no operator-approval check).
    function _.burn(uint256 _positionId, uint256 _amount)
        external with (env e) => burnByCVL(0, e.msg.sender, _positionId, _amount) expect void;

    // Batch burn: unrolled up to 3 elements; burner is the caller (the module).
    function _.batchBurn(uint256[] _positionIds, uint256[] _amounts)
        external with (env e) => batchBurnWithAuthCVL(e, _positionIds, _amounts) expect void;

    // The real safeTransferFrom / safeBatchTransferFrom bodies call the ERC1155 receiver hook on
    // `to` whenever it has code. Left unresolved the prover havocs, which scrambles
    // PositionManager's own storage; NONDET frees the return value without side effects.
    function _.onERC1155Received(address, address, uint256, uint256, bytes) external => NONDET;
    function _.onERC1155BatchReceived(address, address, uint256[], uint256[], bytes) external => NONDET;

    // Unsafe single transfer: same balance semantics as safeTransferFrom (no callback).
    function _.unsafeTransferFrom(address from, address to, uint256 id, uint256 amount)
        external with (env e) => erc1155SafeTransferFromCVL(e, from, to, id, amount) expect void;

    // Unsafe batch transfer: unrolled up to 3 elements; passes arrays to the CVL function.
    function _.unsafeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] amounts)
        external with (env e) => unsafeBatchTransferFromCVL(e, from, to, ids, amounts) expect void;

}

/*--------------------------------------------------------------
                        ghost model
--------------------------------------------------------------*/

// ghostBalance[owner][id] — token balance (mathint avoids overflow in ghost arithmetic).
ghost mapping(address => mapping(uint256 => mathint)) ghostBalance;
// ghostApproved[owner][operator] — isApprovedForAll state.
ghost mapping(address => mapping(address => bool)) ghostApproved;
// ghostSupply[id] — net total supply per token id: increased only by mintCVL, decreased
// only by burnByCVL. All transfer helpers conserve it by construction.
ghost mapping(uint256 => mathint) ghostSupply;

/*--------------------------------------------------------------
                        read helpers
--------------------------------------------------------------*/

function balanceOfCVL(address owner, uint256 id) returns uint256 {
    return require_uint256(ghostBalance[owner][id]);
}

function isApprovedForAllCVL(address owner, address operator) returns bool {
    return ghostApproved[owner][operator];
}

// balanceOfBatch: unrolled read up to 3 elements.
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

/*--------------------------------------------------------------
                    approval write helpers
--------------------------------------------------------------*/

// setApprovalForAll (public): caller is the owner, recovered from the env.
function setApprovalForAllCVL(env e, address operator, bool isApproved) {
    ghostApproved[e.msg.sender][operator] = isApproved;
}

// _setApprovalForAll (internal): explicit owner `by`.
function setApprovalForAllByCVL(address by, address operator, bool isApproved) {
    ghostApproved[by][operator] = isApproved;
}

/*--------------------------------------------------------------
                    mint / burn helpers
--------------------------------------------------------------*/

// _mint: increase balance of `to` for token `id`.
function mintCVL(address to, uint256 id, uint256 amount) {
    if (to == 0) { revert(); }
    ghostBalance[to][id] = ghostBalance[to][id] + to_mathint(amount);
    ghostSupply[id] = ghostSupply[id] + to_mathint(amount);
}

// _burn (4-arg): decrease balance of `from`, with optional `by` authorization check.
function burnByCVL(address by, address from, uint256 id, uint256 amount) {
    if (by != 0 && by != from) {
        if (!ghostApproved[from][by]) { revert(); }
    }
    mathint amt = to_mathint(amount);
    if (ghostBalance[from][id] < amt) { revert(); }
    ghostBalance[from][id] = ghostBalance[from][id] - amt;
    ghostSupply[id] = ghostSupply[id] - amt;
}

/*--------------------------------------------------------------
                    transfer helpers
--------------------------------------------------------------*/

// safeTransferFrom (public): authorization via msg.sender.
function erc1155SafeTransferFromCVL(env e, address from, address to, uint256 id, uint256 amount) {
    if (to == 0) { revert(); }
    if (from != e.msg.sender && !ghostApproved[from][e.msg.sender]) { revert(); }
    mathint amt = to_mathint(amount);
    if (ghostBalance[from][id] < amt) { revert(); }
    if (from != to) {
        ghostBalance[from][id] = ghostBalance[from][id] - amt;
        ghostBalance[to][id] = ghostBalance[to][id] + amt;
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
    if (from != to) {
        ghostBalance[from][id] = ghostBalance[from][id] - amt;
        ghostBalance[to][id] = ghostBalance[to][id] + amt;
    }
}

/*--------------------------------------------------------------
            core batch helpers (unrolled to 3)
--------------------------------------------------------------*/

function safeBatchTransferFromCVL(env e, address from, address to, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { erc1155SafeTransferFromCVL(e, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { erc1155SafeTransferFromCVL(e, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { erc1155SafeTransferFromCVL(e, from, to, ids[2], amounts[2]); }
}

function batchMintCVL(address to, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { mintCVL(to, ids[0], amounts[0]); }
    if (ids.length > 1) { mintCVL(to, ids[1], amounts[1]); }
    if (ids.length > 2) { mintCVL(to, ids[2], amounts[2]); }
}

function batchBurnByCVL(address by, address from, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { burnByCVL(by, from, ids[0], amounts[0]); }
    if (ids.length > 1) { burnByCVL(by, from, ids[1], amounts[1]); }
    if (ids.length > 2) { burnByCVL(by, from, ids[2], amounts[2]); }
}

function safeBatchTransferByCVL(address by, address from, address to, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { safeTransferByCVL(by, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { safeTransferByCVL(by, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { safeTransferByCVL(by, from, to, ids[2], amounts[2]); }
}

/*--------------------------------------------------------------
        module-id / authorization helpers (division-based)

    moduleId = top 8 bits of the position id (Ids.sol layout). Division instead of
    `>>` keeps the prover out of bitvector theory (required by the solvency scene).
--------------------------------------------------------------*/

definition moduleIdOf(uint256 positionId) returns mathint = positionId / 2 ^ 248;

// Registered module for a position id (envfree read of PositionManager storage).
function moduleFor(uint256 positionId) returns address {
    return PositionManager.moduleById(require_uint256(moduleIdOf(positionId)));
}

// onlyModuleByPositionIds semantics, unrolled to loop_iter = 3: the caller must be the
// registered module for EVERY id, otherwise crossModuleAuth is required. An empty batch
// performs no check (the modifier loop body never runs).
function allIdsOwnedBy(address sender, uint256[] positionIds) returns bool {
    bool own0 = positionIds.length > 0 ? moduleFor(positionIds[0]) == sender : true;
    bool own1 = positionIds.length > 1 ? moduleFor(positionIds[1]) == sender : true;
    bool own2 = positionIds.length > 2 ? moduleFor(positionIds[2]) == sender : true;
    return own0 && own1 && own2;
}

// onlyModuleByPositionIds: caller is cross-authorized, or the registered module for EVERY id.
function batchAuthOK(address sender, uint256[] ids) returns bool {
    if (PositionManager.crossModuleAuth(sender)) { return true; }
    return allIdsOwnedBy(sender, ids);
}

/*--------------------------------------------------------------
        auth-aware summaries (revert inside)

    Each wraps the core CVL summary with the reverts it omits — the non-payable value
    check, the PositionManager authorization modifier, and (where the base summary uses
    unbounded mathint) the uint256 overflow check — so the wrapper reverts on EXACTLY
    the real revert set. Balance checks read the GHOST (the pre-state).
--------------------------------------------------------------*/

// mintCVL guarded by: value, onlyModuleByPositionId, uint256 overflow. (mintCVL adds to == 0.)
function mintWithAuthCVL(env e, address to, uint256 posId, uint256 amount) {
    if (e.msg.value != 0) { revert(); }
    if (!(moduleFor(posId) == e.msg.sender || PositionManager.crossModuleAuth(e.msg.sender))) { revert(); }
    if (ghostBalance[to][posId] + to_mathint(amount) > max_uint256) { revert(); }
    mintCVL(to, posId, amount);
}

// burnByCVL(by = 0) guarded by: value, onlyModuleByPositionId. (burnByCVL adds the balance check.)
function burnWithAuthCVL(env e, uint256 posId, uint256 amount) {
    if (e.msg.value != 0) { revert(); }
    if (!(moduleFor(posId) == e.msg.sender || PositionManager.crossModuleAuth(e.msg.sender))) { revert(); }
    burnByCVL(0, e.msg.sender, posId, amount);
}

// erc1155SafeTransferFromCVL guarded by: value, uint256 overflow. (the base summary adds
// to == 0, the caller-or-approved auth, and the from-balance check.)
function transferWithAuthCVL(env e, address from, address to, uint256 id, uint256 amount) {
    if (e.msg.value != 0) { revert(); }
    if (from != to && ghostBalance[to][id] + to_mathint(amount) > max_uint256) { revert(); }
    erc1155SafeTransferFromCVL(e, from, to, id, amount);
}

// mintCVL guarded by the uint256 overflow check on the (running) ghost balance.
function mintOverflowCVL(address to, uint256 id, uint256 amount) {
    if (ghostBalance[to][id] + to_mathint(amount) > max_uint256) { revert(); }
    mintCVL(to, id, amount);
}

// erc1155SafeTransferFromCVL guarded by the (running) to-side overflow check (only when from != to).
function transferOverflowCVL(env e, address from, address to, uint256 id, uint256 amount) {
    if (from != to && ghostBalance[to][id] + to_mathint(amount) > max_uint256) { revert(); }
    erc1155SafeTransferFromCVL(e, from, to, id, amount);
}

// batchMint: value, onlyModuleByPositionIds, ArrayLengthsMismatch, to == 0 (unconditional, before the
// loop), per-element running overflow.
function batchMintWithAuthCVL(env e, address to, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (to == 0) { revert(); }
    if (ids.length > 0) { mintOverflowCVL(to, ids[0], amounts[0]); }
    if (ids.length > 1) { mintOverflowCVL(to, ids[1], amounts[1]); }
    if (ids.length > 2) { mintOverflowCVL(to, ids[2], amounts[2]); }
}

// batchBurn: value, onlyModuleByPositionIds, ArrayLengthsMismatch. batchBurnByCVL(by = 0) enforces the
// per-element running sufficient-balance check (burns from the caller; no to == 0, no overflow).
function batchBurnWithAuthCVL(env e, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (!batchAuthOK(e.msg.sender, ids)) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    batchBurnByCVL(0, e.msg.sender, ids, amounts);
}

// unsafeBatchTransferFrom: value, ArrayLengthsMismatch, to == 0 and caller-or-approved (both
// unconditional, before the loop), per-element running insufficient(from) + overflow(to).
function batchTransferWithAuthCVL(env e, address from, address to, uint256[] ids, uint256[] amounts) {
    if (e.msg.value != 0) { revert(); }
    if (ids.length != amounts.length) { revert(); }
    if (to == 0) { revert(); }
    if (from != e.msg.sender && !ghostApproved[from][e.msg.sender]) { revert(); }
    if (ids.length > 0) { transferOverflowCVL(e, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { transferOverflowCVL(e, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { transferOverflowCVL(e, from, to, ids[2], amounts[2]); }
}

// unsafeBatchTransferFrom: auth check once, then unrolled transfer for each element.
// erc1155SafeTransferFromCVL handles the zero-address check and per-element balance updates.
function unsafeBatchTransferFromCVL(env e, address from, address to, uint256[] ids, uint256[] amounts) {
    if (from != e.msg.sender && !ghostApproved[from][e.msg.sender]) { revert(); }
    if (ids.length > 0) { erc1155SafeTransferFromCVL(e, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { erc1155SafeTransferFromCVL(e, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { erc1155SafeTransferFromCVL(e, from, to, ids[2], amounts[2]); }
}
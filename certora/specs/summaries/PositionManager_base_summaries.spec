// ============================================================
// PositionManager_base_summaries.spec — PositionManager-specific summaries
//
// PositionManager defines its own external assembly mutators (mint, batchMint,
// burn, batchBurn, unsafeTransferFrom, unsafeBatchTransferFrom) that compute
// ERC1155 balance/approval storage slots via the _ERC1155_MASTER_SLOT_SEED
// pattern. They are summarized as EXTERNAL summaries: internal-visibility
// summaries cannot attach to `external` functions (the assembly bodies contain
// no internal calls), so interception happens at the external call boundary.
//
// Consequently the summaries fire for contract-to-contract calls (modules /
// exchange / routers -> PositionManager) but never for the verification target
// itself: PositionManager-parametric rules and direct CVL calls execute the
// REAL bodies. Gating and integrity of the real bodies are proven in
// certora/specs/solvency/PositionManager.spec.
//
// Authorization (onlyModuleByPositionId(s)) is intentionally NOT modeled by the
// mint/burn summaries: they over-approximate by accepting any caller, which is
// sound for safety properties. The unsafe-transfer summaries keep the
// caller-or-approved check, matching the real code.
//
// burn/batchBurn also route through Solady's internal _burn/_batchBurn: scenes
// where PositionManager itself is parametric and burn paths should stay
// ghost-modeled must additionally import Solady/ERC1155Burn.spec.
//
// Batch helpers are loop-unrolled up to the prover's loop-iteration limit of 3.
// Requires ERC1155.spec to be imported first (defines ghostBalance, ghostApproved,
// mintCVL, burnByCVL, erc1155SafeTransferFromCVL).
// ============================================================

import "Solady/ERC1155.spec";


methods {
    // Single-element mint: reuses mintCVL from ERC1155.spec.
    function _.mint(address _to, uint256 _positionId, uint256 _amount) external =>
        mintCVL(_to, _positionId, _amount) expect void;

    // Batch mint: unrolled up to 3 elements; passes arrays to the CVL function.
    // External function — arrays are calldata.
    function _.batchMint(address _to, uint256[] _positionIds, uint256[] _amounts) external =>
        batchMintPositionCVL(_to, _positionIds, _amounts) expect void;

    // Single burn: debits the CALLER (the module holds the tokens). by = 0 mirrors
    // Solady's 3-arg _burn wrapper (no operator-approval check).
    function _.burn(uint256 _positionId, uint256 _amount)
        external with (env e) => burnByCVL(0, e.msg.sender, _positionId, _amount) expect void;

    // Batch burn: unrolled up to 3 elements; burner is the caller (the module).
    function _.batchBurn(uint256[] _positionIds, uint256[] _amounts)
        external with (env e) => batchBurnPositionCVL(e, _positionIds, _amounts) expect void;

    // Unsafe single transfer: same balance semantics as safeTransferFrom (no callback).
    function _.unsafeTransferFrom(address from, address to, uint256 id, uint256 amount)
        external with (env e) => erc1155SafeTransferFromCVL(e, from, to, id, amount) expect void;

    // Unsafe batch transfer: unrolled up to 3 elements; passes arrays to the CVL function.
    function _.unsafeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] amounts)
        external with (env e) => unsafeBatchTransferFromCVL(e, from, to, ids, amounts) expect void;

    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);
}

// ------------------------------------------------------------
// Batch CVL helpers (single-element helpers live in ERC1155.spec)
// ------------------------------------------------------------

// batchMint: unrolled loop — calls mintCVL for each of the (up to 3) elements.
function batchMintPositionCVL(address to, uint256[] positionIds, uint256[] amounts) {
    if (positionIds.length > 0) { mintCVL(to, positionIds[0], amounts[0]); }
    if (positionIds.length > 1) { mintCVL(to, positionIds[1], amounts[1]); }
    if (positionIds.length > 2) { mintCVL(to, positionIds[2], amounts[2]); }
}

// batchBurn: unrolled loop — burns from the caller (the module holds the tokens).
// by = 0 mirrors Solady's 3-arg _batchBurn(from, ...) wrapper, which delegates to the
// 4-arg variant with by = address(0) (no operator-approval check).
// burnByCVL enforces the sufficient-balance revert per element.
// Unrolled to 5 elements: the extra guarded branches are inert for arrays of length <= 3,
// so importers that bound shorter batches are unaffected; BRIDGE-02 burnFromBridge uses
// up to 5.
function batchBurnPositionCVL(env e, uint256[] positionIds, uint256[] amounts) {
    if (positionIds.length > 0) { burnByCVL(0, e.msg.sender, positionIds[0], amounts[0]); }
    if (positionIds.length > 1) { burnByCVL(0, e.msg.sender, positionIds[1], amounts[1]); }
    if (positionIds.length > 2) { burnByCVL(0, e.msg.sender, positionIds[2], amounts[2]); }
    if (positionIds.length > 3) { burnByCVL(0, e.msg.sender, positionIds[3], amounts[3]); }
    if (positionIds.length > 4) { burnByCVL(0, e.msg.sender, positionIds[4], amounts[4]); }
}

// unsafeBatchTransferFrom: auth check once, then unrolled transfer for each element.
// erc1155SafeTransferFromCVL handles the zero-address check and per-element balance updates.
function unsafeBatchTransferFromCVL(env e, address from, address to, uint256[] ids, uint256[] amounts) {
    if (from != e.msg.sender && !ghostApproved[from][e.msg.sender]) { revert(); }
    if (ids.length > 0) { erc1155SafeTransferFromCVL(e, from, to, ids[0], amounts[0]); }
    if (ids.length > 1) { erc1155SafeTransferFromCVL(e, from, to, ids[1], amounts[1]); }
    if (ids.length > 2) { erc1155SafeTransferFromCVL(e, from, to, ids[2], amounts[2]); }
}

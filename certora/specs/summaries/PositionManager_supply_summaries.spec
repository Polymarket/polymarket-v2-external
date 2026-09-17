// ============================================================
// PositionManager_supply_summaries.spec — aggregate (total-supply) scene
//
// Module-verification scene only: when a *module* (BinaryModule / NegRiskModule)
// is the verified contract, it calls PositionManager.mint/burn/batchMint/batchBurn
// as EXTERNAL cross-contract calls. These summaries intercept those calls and
// maintain the per-id `ghostSupply` aggregate (and `migrationBacking` on the
// migrate batchMint path) that supply/solvency properties reason about.
//
// Self-contained: declares its own `ghostSupply` so it does NOT import
// Solady/ERC1155.spec (whose per-account `ghostBalance` model is unused here and
// would otherwise also re-declare a supply ghost). Transfers preserve total
// supply, so they are NONDET no-ops (which also strips their ERC1155 slot
// assembly from analysis).
//
// This is the former PositionManager_total_supply_summaries.spec, kept separate
// so module-solvency specs that need migration backing can import it INSTEAD of
// the per-account PositionManager_base_summaries.spec (the two cannot coexist:
// both summarize the same external mint/burn/batchMint/batchBurn sighashes).
// ============================================================

methods {
    function _.mint(address to, uint256 id, uint256 amount) external => totalMintCVL(id, amount) expect void;
    function _.burn(uint256 id, uint256 amount) external => totalBurnCVL(id, amount) expect void;
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external =>
        totalBatchMintCVL(ids, amounts) expect void;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external =>
        totalBatchBurnCVL(ids, amounts) expect void;

    // Transfers preserve total supply — summarized as no-ops (also removes assembly).
    function _.unsafeTransferFrom(address from, address to, uint256 id, uint256 amount) external => NONDET;
    function _.unsafeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] amounts) external => NONDET;
    function _.safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data) external => NONDET;
    function _.safeBatchTransferFrom(address from, address to, uint256[] ids, uint256[] amounts, bytes data) external =>
        NONDET;

    function _.moduleId() external => DISPATCHER(true);
    function _.getResult(PositionManager.ConditionId) external => DISPATCHER(true);
}

// ------------------------------------------------------------
// Aggregate (ghostSupply) state + helpers — external scene
// ------------------------------------------------------------

// ghostSupply[id] — net total supply per token id: +mint, -burn; transfers conserve.
ghost mapping(uint256 => mathint) ghostSupply {
    init_state axiom forall uint256 i. ghostSupply[i] == 0;
}

// Migration-origin backing, keyed by minted position id. Credited only on the
// batchMint path (the BinaryModule/NegRiskModule migratePositions flow); single
// mint (split, bridge) does NOT touch it. Module solvency specs add this to the
// `committed` collateral when bounding redeemable value, modeling the legacy CTF
// collateral that backs migrated positions 1:1. Other specs may ignore it.
ghost mapping(uint256 => uint256) migrationBacking {
    init_state axiom forall uint256 i. migrationBacking[i] == 0;
}

function totalMintCVL(uint256 id, uint256 amount) {
    ghostSupply[id] = ghostSupply[id] + to_mathint(amount);
}

// A module can only burn tokens that exist, so a successful burn implies
// amount <= ghostSupply[id]. Model the underflow as a revert.
function totalBurnCVL(uint256 id, uint256 amount) {
    if (ghostSupply[id] < to_mathint(amount)) { revert(); }
    ghostSupply[id] = ghostSupply[id] - to_mathint(amount);
}

// batchMint is the migratePositions mint path: alongside ghostSupply, credit
// migrationBacking by the same amount (legacy CTF collateral backing the migrated
// position), keyed by the minted id == pidOf(condition, outcome).
//
// ASSUMPTION (soundness boundary): migrationBacking is credited here 1:1 with the
// minted supply and is NEVER debited on redeem/merge/burn — a high-water-mark. The
// real legacy redemption + vault settlement (CT.redeemPositions / mergePositions /
// _settleLegacyCollateralToVault) are NONDET in the module specs, so "migrated supply
// is 1:1 vault-backed" is ASSUMED, not proven here. It is sound as a conservative
// over-approximation: migrated legs are proportionally self-backed because
// _resolveMigrationCondition derives the V2 result from the legacy payout (real code),
// so the full-amount credit is unconsumable slack, not exploitable backing.
function totalBatchMintCVL(uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) {
        totalMintCVL(ids[0], amounts[0]);
        migrationBacking[ids[0]] = require_uint256(migrationBacking[ids[0]] + amounts[0]);
    }
    if (ids.length > 1) {
        totalMintCVL(ids[1], amounts[1]);
        migrationBacking[ids[1]] = require_uint256(migrationBacking[ids[1]] + amounts[1]);
    }
    if (ids.length > 2) {
        totalMintCVL(ids[2], amounts[2]);
        migrationBacking[ids[2]] = require_uint256(migrationBacking[ids[2]] + amounts[2]);
    }
}

function totalBatchBurnCVL(uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { totalBurnCVL(ids[0], amounts[0]); }
    if (ids.length > 1) { totalBurnCVL(ids[1], amounts[1]); }
    if (ids.length > 2) { totalBurnCVL(ids[2], amounts[2]); }
}

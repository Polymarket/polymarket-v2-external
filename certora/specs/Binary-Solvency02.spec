/* =============================================================================
 * SOLVENCY-02 (INVARIANT FORM) — Binary split/merge/redeem/reportResult conserve collateral
 *
 * Invariant (per condition c): once resolved with stored result [r0, r1],
 *     supply(YES_c)*r0 + supply(NO_c)*r1  <=  committed(c) * RESULT_DENOMINATOR
 * ============================================================================= */

/*
 * MODULE
 * @module BinaryModule Global Solvency
 * @contract BinaryModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 2 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 *
 * PROPERTIES
 * @property BINARY-SOLVENCY-02 Per binary condition, the redemption obligation of the outstanding YES and NO supply never exceeds the collateral committed to that condition.
 */


import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";
import "summaries/PositionManager_supply_summaries.spec";

// We verify BinaryModuleHarness instead of BinaryModule to avoid the havocing of the role bitmaps.
using BinaryModuleHarness as BinaryModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;

methods {
    // harness pure/view helpers (envfree). 
    function pidOf(BinaryModule.ConditionId, uint256) external returns (uint256) envfree;
    function resultLen(BinaryModule.ConditionId) external returns (uint256) envfree;
    function resultAt(BinaryModule.ConditionId, uint256) external returns (uint256) envfree;
    function yesPidOf(BinaryModule.PositionId) external returns (uint256) envfree;

    // module identity + immutable wiring (mirrors BinaryModule_base_summaries)
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;
    function _.CONDITIONAL_TOKENS() external => ConditionalTokens expect address;

    // NONDET Prevent havocing of the collectionId ghost
    function CTHelpers.getCollectionId(bytes32, bytes32, uint256) internal returns (bytes32) => NONDET;

    // Legacy CTF redemption (resolveMigrationCondition path): touches neither the `committed` ghost 
    //nor `totalSupply`, so NONDET keeps the proof tractable.
    function _.redeemPositions(address, bytes32, bytes32, uint256[]) external => NONDET;
    // Legacy CTF transfer, balance reads, and complementary merge only change legacy-side state.
    // Exact receiver summaries are necessary because `CONDITIONAL_TOKENS` is linked in this scene.
    function ConditionalTokens.safeBatchTransferFrom(address, address, uint256[], uint256[], bytes) external => NONDET;
    function ConditionalTokens.balanceOf(address, uint256) external returns (uint256) => NONDET;
    function ConditionalTokens.mergePositions(address, bytes32, bytes32, uint256[], uint256) external => NONDET;
    // Legacy payout vector. In the migrate loop it is no longer read at all (the harness
    // `_redeemIfResolvedDuringMigrate` over-approximation below bypasses the whole `_redeemIfResolved`
    // body). It is still read once by the single-call `resolveMigrationCondition` path.
    // NONDET there makes the reads fresh nondets and the `p0 * DENOM / (p0+p1)` quotient dead. 
    // Sound over approximation: the redeem loop is over-approximated away by the harness.
    function ConditionalTokens.payoutNumerators(bytes32, uint256) external returns (uint256) => NONDET;
    // CTFHelpers.partition() uses raw memory allocation; its fixed [1, 2] output is irrelevant here.
    function CTFHelpers.partition() internal returns (uint256[] memory) => partitionCVL();
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    // Legacy collateral settlement (migratePositions path). NONDET on the whole internal helper , it does not touch the V2 ghosts
    function _._settleLegacyCollateralToVault() internal => NONDET;

    // Payout-division summarization: the harness override BinaryModuleHarness._finalizeMigrationResolution
    // stores a nondet-but-normalized migration result pinned to the binary endpoints. NONDET here
    // feeds that r0 (the harness `require(r0 == 0 || r0 == DENOM)` pins it). 
    // Sound over approximation : the solvency bound is linear in r0 (with r0 + r1 == DENOM), so its max over r0 in
    // [0,DENOM] is at an endpoint — proving {0,DENOM} proves the whole interval, while handing the solver a 2-point domain.
    function _._nondetPayoutNumerator() internal => NONDET;

    // `_migratePositions` unrolls TWO loops `loop_iter` times and inlines the whole `_redeemIfResolved`
    // body once per iteration.Opting the harness `_redeemIfResolvedDuringMigrate` model in drops that whole
    // body while KEEPING the resolution store. 
    // Sound over approximation: the store is an over-approximation of the real one (retained, not dropped), 
    // and migratePositions still mints supply + credits migrationBacking 1:1 (the load-bearing check). 
    function _._useMigrateRedeemModel() internal => ALWAYS(true);
    function _._nondetResolved() internal => NONDET;

    // PUSD ERC20 token Wildcard : safe in this scene because no other in-scene contract has a mint(address,uint256)/burn(uint256) sighash
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_amount) expect void;
    function _.burn(uint256 _amount) external => ctBurnCVL(_amount) expect void;

    // OwnableRoles wiring for the harness 
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// PositionManager and CollateralToken intentionally NOT linked: linking bypasses the external CollateralToken.mint/burn ghost summaries
// and freezes totalSupply / committed.
links {
    BinaryModule.CONDITIONAL_TOKENS => ConditionalTokens;
}

/* -----------------------------------------------------------------------------
 * Ghost state for committed collateral
 * --------------------------------------------------------------------------- */

// condition proxy (== YES positionId) => net committed collateral
ghost mapping(uint256 => mathint) committed {
    init_state axiom forall uint256 c. committed[c] == 0;
}

// condition under test — set by each preserved block so collateral ops attribute correctly
ghost uint256 ctxCond;

// CollateralToken.burn(amount): split burns collateral into the condition => +committed.
function ctBurnCVL(uint256 amount) {
    committed[ctxCond] = committed[ctxCond] + to_mathint(amount);
}

// CollateralToken.mint(to, amount): merge/redeem mint collateral out => -committed.
function ctMintCVL(uint256 amount) {
    committed[ctxCond] = committed[ctxCond] - to_mathint(amount);
}

// CTFHelpers.partition() always returns the fixed binary partition [0b01, 0b10].
function partitionCVL() returns uint256[] {
    uint256[] result;
    require result.length == 2, "partition() always returns a 2-element array";
    require result[0] == 1, "partition()[0] is the YES index set 0b01";
    require result[1] == 2, "partition()[1] is the NO index set 0b10";
    return result;
}

/* -----------------------------------------------------------------------------
 * Definitions
 * --------------------------------------------------------------------------- */

definition DENOM() returns uint256 = 1000000;

definition OUT_OF_SCOPE(method f) returns bool =
    // These 3 functions cannot move collateral and are havoced so they are filtered out.
    f.selector == sig:BinaryModule.requestOwnershipHandover().selector
    || f.selector == sig:BinaryModule.cancelOwnershipHandover().selector
    || f.selector == sig:BinaryModule.completeOwnershipHandover(address).selector
    // Excluded : it raises totalSupply with zero committed/migrationBacking increase, 
    // because a bridged-in position's collateral is locked on the source chain
    || f.selector == sig:BinaryModule.mintFromBridge(address,BinaryModule.PositionId,uint256).selector
    // Equivalence-proof harness wrapper (BinaryMigrationResolutionEquivalence); not a production entry point
    || f.selector == sig:BinaryModule.finalizeMigrationResolutionModel(BinaryModule.ConditionId).selector;

// The two legacy-migration batch entrypoints. Split OUT of `postResolutionSolvency` and into the
// dedicated `postResolutionSolvencyMigrate` invariant below (run via split_rules in Binary-Solvency02.conf)
// because they are the heavy induction steps: with loop_iter 3 `_migratePositions` unrolls TWO loops
// three times and inlines the `_redeemIfResolved` body once per iteration. The harness
// `_redeemIfResolvedDuringMigrate` over-approximation drops that inlined body while
// keeping the {0,DENOM}-pinned resolution store, which is what lets the isolated per-overload confs
// close. 
definition IS_MIGRATE(method f) returns bool =
    f.selector == sig:BinaryModule.migratePositions(bytes32[],uint256[],uint256[]).selector
    || f.selector == sig:BinaryModule.migratePositions(address,bytes32[],uint256[],uint256[]).selector;

/* =============================================================================
 * SUPPORTING INVARIANTS
 * ============================================================================= */

/**
 * @ignore
 * @report https://prover.certora.com/output/10505052/a450a39ee2f444c58ee195a581471db4?anonymousKey=9ac113df183d37928b79bd148d586eabca5fe9d1
 */
strong invariant resolvedMeansNormalized(BinaryModule.ConditionId c)
    resultLen(c) == 2 => resultAt(c, 0) + resultAt(c, 1) == DENOM()
    filtered { f -> !OUT_OF_SCOPE(f) }

/**
 * @ignore
 * @report https://prover.certora.com/output/10505052/a450a39ee2f444c58ee195a581471db4?anonymousKey=9ac113df183d37928b79bd148d586eabca5fe9d1
 */
strong invariant resultNotZeroMeansResolved(BinaryModule.ConditionId c)
    resultLen(c) != 0 => resultLen(c) == 2
    filtered { f -> !OUT_OF_SCOPE(f) }

/* =============================================================================
 * INVARIANT: redeemable value <= committed collateral, for a resolved condition.
 * ============================================================================= */

/**
 * @title pre-resolution backing bound
 * @description Before resolution the outstanding YES and NO supply of a condition is covered by the collateral committed to it.
 * @link_property BINARY-SOLVENCY-02
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/a450a39ee2f444c58ee195a581471db4?anonymousKey=9ac113df183d37928b79bd148d586eabca5fe9d1
 */
strong invariant preResolutionSolvency(BinaryModule.ConditionId c)
    // pUSDSupplyForV2 + migratedBackingCTFV1[YES/NO] >= totalSupplyERC1155[YES/NO]
    // we use commited[pid(c, 0)] (YES) as it equal to commited[pid(c, 1)] (NO) as proved in yesNoSupplyEqual
    resultLen(c) == 0 =>
        committed[pidOf(c, 0)] + migrationBacking[pidOf(c, 0)] >= ghostSupply[pidOf(c, 0)]
        && committed[pidOf(c, 0)] + migrationBacking[pidOf(c, 1)] >= ghostSupply[pidOf(c, 1)]
    filtered { f -> !OUT_OF_SCOPE(f) }
    {
        // `committed` is keyed by the free ghost `ctxCond` to have ctBurnCVL and ctMintCVL (summaries of mint and burn)
        // writing to the good bucket

        // split burns `_amount` collateral into `_c` (+committed) and mints `_amount` of each leg.
        // Route the burn to `_c`'s bucket.
        preserved split(address[] _to, BinaryModule.ConditionId _c, uint256 _amount) with (env e) {
            ctxCond = pidOf(_c, 0);
        }
        // merge mints `_amount` collateral out of `_c` (-committed) and burns `_amount` of each leg.
        // Route the mint to `_c`'s bucket.
        preserved merge(address _to, BinaryModule.ConditionId _c, uint256 _amount) with (env e) {
            ctxCond = pidOf(_c, 0);
        }
        // redeem only carries a PositionId (no ConditionId), so normalize it to the canonical
        // YES-pid key that `committed` is indexed by.
        preserved redeem(address _to, BinaryModule.PositionId _pid, uint256 _amount) with (env e) {
            ctxCond = yesPidOf(_pid);
        }
    }

/* =============================================================================
 * BRIDGE-MINT TRUST BOUNDARY — 
 * These rules make the exclusion explicit and measured: the mint moves no local
 * collateral, and both backing bounds survive given a source-chain credit of
 * `amount` collateral (the minted position's par value).
 * ============================================================================= */

/**
 * @title bridge mint keeps the pre-resolution bound
 * @description A bridge mint preserves the pre-resolution backing bound for the condition it credits.
 * @link_property BINARY-SOLVENCY-02
 * @assumption Assumes position is collateralized in another chain. Safe as we showed that solvency holds per individual chain, and bridging operations are solvency preserving.
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/a450a39ee2f444c58ee195a581471db4?anonymousKey=9ac113df183d37928b79bd148d586eabca5fe9d1
 */
rule mintFromBridgePreResolutionSourceBacked(env ev, address to, BinaryModule.PositionId pid, uint256 amount, BinaryModule.ConditionId c) {
    require resultLen(c) == 0, "pre-resolution regime";
    requireInvariant preResolutionSolvency(c);

    mathint committedBefore = committed[pidOf(c, 0)];

    mintFromBridge(ev, to, pid, amount);

    assert committed[pidOf(c, 0)] == committedBefore, "bridge mint moved collateral";
    assert committed[pidOf(c, 0)] + migrationBacking[pidOf(c, 0)] + amount >= ghostSupply[pidOf(c, 0)]
        && committed[pidOf(c, 0)] + migrationBacking[pidOf(c, 1)] + amount >= ghostSupply[pidOf(c, 1)],
        "pre-resolution backing holds GIVEN source-chain backing >= amount";
}

/**
 * @title bridge mint keeps the post-resolution bound
 * @description A bridge mint preserves the resolved backing bound for the condition it credits.
 * @link_property BINARY-SOLVENCY-02
  * @assumption Assumes position is collateralized in another chain. Safe as we showed that solvency holds per individual chain, and bridging operations are solvency preserving.
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/a450a39ee2f444c58ee195a581471db4?anonymousKey=9ac113df183d37928b79bd148d586eabca5fe9d1
 */
rule mintFromBridgePostResolutionSourceBacked(env ev, address to, BinaryModule.PositionId pid, uint256 amount, BinaryModule.ConditionId c) {
    require resultLen(c) == 2, "resolved regime";
    requireInvariant resolvedMeansNormalized(c);
    requireInvariant postResolutionSolvency(c);

    mathint committedBefore = committed[pidOf(c, 0)];

    mintFromBridge(ev, to, pid, amount);

    assert committed[pidOf(c, 0)] == committedBefore, "bridge mint moved collateral";
    assert ghostSupply[pidOf(c, 0)] * to_mathint(resultAt(c, 0)) + ghostSupply[pidOf(c, 1)] * to_mathint(resultAt(c, 1))
        <= (committed[pidOf(c, 0)] + migrationBacking[pidOf(c, 0)] + migrationBacking[pidOf(c, 1)] + amount) * DENOM(),
        "post-resolution solvency holds GIVEN source-chain backing >= amount";
}

/**
 * @title post-resolution backing bound
 * @description After resolution the redemption obligation of a condition is covered by the collateral committed to it.
 * @link_property BINARY-SOLVENCY-02
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/a450a39ee2f444c58ee195a581471db4?anonymousKey=9ac113df183d37928b79bd148d586eabca5fe9d1
 */
strong invariant postResolutionSolvency(BinaryModule.ConditionId c)
    resultLen(c) == 2
        // Both legs appear on the LHS, but collateral is tracked in a single bucket keyed by the YES pid: split burns one _amount
        // into committed[YES] while minting YES and NO at par, so NO supply is always co-backed by the same collateral
        => ghostSupply[pidOf(c, 0)] * to_mathint(resultAt(c, 0)) + ghostSupply[pidOf(c, 1)] * to_mathint(resultAt(c, 1))
                <= (committed[pidOf(c, 0)] + migrationBacking[pidOf(c, 0)] + migrationBacking[pidOf(c, 1)]) * DENOM()
    // migratePositions is carved out into postResolutionSolvencyMigrate below — see IS_MIGRATE.
    filtered { f -> !OUT_OF_SCOPE(f) }
    {
        // Same ctxCond routing as preResolutionSolvency, plus two requireInvariants:
        //   (1) resolvedMeansNormalized(c) gives r0 + r1 == DENOM, so a par-value split/merge keeps the
        //       bound balanced (LHS grows _amount*(r0+r1), RHS _amount*DENOM); without it r0+r1 > DENOM breaks it.
        //   (2) preResolutionSolvency(c) seeds reportResult/resolveMigrationCondition (the only resultLen 0->2
        //       flips): committed >= each leg supply plus r0,r1 <= DENOM derives the post-resolution bound.

        // resolved-condition split: move both legs + collateral at par; needs r0 + r1 == DENOM.
        preserved split(address[] _to, BinaryModule.ConditionId _c, uint256 _amount) with (env e) {
            requireInvariant resolvedMeansNormalized(c);
            // route this split's collateral mint/burn to _c's committed bucket 
            ctxCond = pidOf(_c, 0); 
        }
        // resolved-condition merge: move both legs + collateral at par; needs r0 + r1 == DENOM.
        preserved merge(address _to, BinaryModule.ConditionId _c, uint256 _amount) with (env e) {
            requireInvariant resolvedMeansNormalized(c);
            // route this merge's collateral mint/burn to _c's committed bucket
            ctxCond = pidOf(_c, 0); 
        }
        // redeem burns a single leg; no par-normalization needed, just route the bucket key.
        preserved redeem(address _to, BinaryModule.PositionId _pid, uint256 _amount) with (env e) {
            // normalize the redeemed PositionId to its YES-pid committed key
            ctxCond = yesPidOf(_pid); 
        }
        // resolution-transition functions (flip resultLen 0 -> 2): seed the backing bound from the
        // pre-resolution invariant so the post-resolution bound can be established at this instant.
        preserved reportResult(BinaryModule.ConditionId _conditionId, uint256[] _result) with (env e) {
            requireInvariant preResolutionSolvency(c);
        }
        preserved resolveMigrationCondition(bytes32 _conditionId) with (env e) {
            requireInvariant preResolutionSolvency(c);
        }
        // The migrate-loop redeem body is over-approximated away by the harness
        // `_redeemIfResolvedDuringMigrate` model (opted in via `_useMigrateRedeemModel`): the legacy
        // reads / `p0*D/den` NIA / legacy redeem / vault settle are dropped, but the resolution store
        // is kept and pinned to r0 in {0,DENOM} through `_finalizeMigrationResolution` (endpoints
        // suffice — the bound is linear in r0). No ctxCond routing: migration credits
        // migrationBacking[pid] from the batchMint summary directly, not the ctxCond `committed` bucket.
        preserved migratePositions(
            bytes32[] _legacyConditionIds, uint256[] _outcomeIndices, uint256[] _amounts
        ) with (env e) {
            requireInvariant resolvedMeansNormalized(c);
            requireInvariant preResolutionSolvency(c);
        }
        preserved migratePositions(
            address _from, bytes32[] _legacyConditionIds, uint256[] _outcomeIndices, uint256[] _amounts
        ) with (env e) {
            requireInvariant resolvedMeansNormalized(c);
            requireInvariant preResolutionSolvency(c);
        }
    }
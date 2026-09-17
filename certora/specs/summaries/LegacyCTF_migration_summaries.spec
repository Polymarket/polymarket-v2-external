// Legacy Gnosis-CTF migration model, shared by the BinaryModule solvency scene
// (BinarySolvencyBase.spec) and the NegRiskModule solvency scene
// (NegRiskSolvencyBase.spec). Owns the ConditionalTokens summaries used by
// BaseMigrationMixin's migratePositions flow, plus the ghost-ledger ERC20 balance
// reads that make the emulated CT payouts visible to the settle sweep.
//
// Alias-free by convention: `ConditionalTokens`, `USDCe` and `CollateralToken` are
// declared by each scene's call-resolution/base spec, and `balanceByToken` by
// Solady/SafeTransferLib.spec (imported by both bases). Each importing base MUST also
// link the module's USDCE immutable and CollateralToken.USDCE to the scene's USDCe
// contract: without those links the emulated CT payout (keyed by the canonical
// CollateralToken.USDCE()) never round-trips to the vault through
// _settleLegacyCollateralToVault (keyed by the module's USDCE immutable), and the
// prover reports a spurious asset loss.

methods {
    // ---- Legacy CTF migration backing ----
    // migratePositions pulls the user's legacy CTF positions into the module via this
    // call; their 1:1 USDC.e backing already sits in ConditionalTokens. Recognize that
    // backing into the counted reserve (balanceByToken[usdce][ConditionalTokens]) so the
    // global inequality holds for migratePositions (the one op that mints liability
    // without burning pUSD). Credited by the pulled amounts (== the V2 amounts minted), so
    // an over-mint relative to the legacy backing still drops the margin and is caught.
    function ConditionalTokens.safeBatchTransferFrom(
        address from, address to, uint256[] ids, uint256[] values, bytes data
    ) external => migrationBackingPullCVL(values);

    // redeemPositions pays the module's legacy redemption USDCe CT->caller;
    // mergePositions pays exactly its `amount` argument CT->caller (parent == 0 path,
    // the only one the migration mixins use). The real bodies (nested index-set loops,
    // nonlinear payout fractions, burns over NONDET-hashed position ids) time out the
    // migratePositions cases, so both are emulated loop-free — see
    // ctfRedeemPositionsCVL / ctfMergePositionsCVL. Exact-contract form: the calls are
    // resolved via the module's CONDITIONAL_TOKENS link, so a wildcard
    // (unresolved-only) summary would not fire.
    function ConditionalTokens.redeemPositions(
        address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint256[] indexSets
    ) external with (env e) => ctfRedeemPositionsCVL(e.msg.sender);
    function ConditionalTokens.mergePositions(
        address collateralToken, bytes32 parentCollectionId, bytes32 conditionId, uint256[] partition, uint256 amount
    ) external with (env e) => ctfMergePositionsCVL(e.msg.sender, amount);

    // The legacy CTF's own state is never WRITTEN in-scene (its three mutators above are
    // CVL-emulated), so its payout numerators and ERC1155 balances are unconstrained
    // pre-state reads either way. NONDET them to strip the real Gnosis-CTF getters —
    // mapping keccaks, dynamic-array bounds, ERC1155 slot hashing — from the
    // migratePositions VC: the values only pick the redeem-vs-merge branch in
    // _redeemIfResolved (both branches modeled conservatively) and feed amountToMerge,
    // which ctfMergePositionsCVL's reserve revert-guard fences. Exact-contract form for
    // the same call-resolution reason as above. The 2-arg ERC1155 balanceOf does not
    // collide with the 1-arg ERC20 wildcard below.
    function ConditionalTokens.payoutNumerators(bytes32, uint256) external returns (uint256) => NONDET;
    function ConditionalTokens.balanceOf(address, uint256) external returns (uint256) => NONDET;

    // CTHelpers.getPositionId is a keccak over (collateral, collectionId), inlined in
    // _migratePositions/_redeemIfResolved (BaseMigrationMixin) per unrolled element. Its
    // results feed ONLY the summarized safeBatchTransferFrom above (which ignores ids)
    // and the NONDET CT balanceOf reads, so the hash constrains nothing real — NONDET it
    // to strip the keccak + abi.encodePacked memory traffic from the migrate VCs.
    // SOUND ONLY WHILE those sinks stay summarized — revisit if any is un-summarized.
    // (Internal wildcard: matches by underlying types, so it also covers the harness
    // ConditionalTokens' IERC20-typed overload — harmless there, its callers are the
    // CVL-emulated mutators whose bodies never inline in these scenes.)
    function _.getPositionId(address, bytes32) internal => NONDET;

    // ERC20 balance reads answer from the same balanceByToken ghost ledger the transfer
    // summaries write (caller in-scene: _settleLegacyCollateralToVault's
    // usdce.balanceOf(this)). Without this, the emulated redemption payout credit
    // (ctfRedeemPositionsCVL, ghost ledger) would be invisible to the settle sweep,
    // which would read the concrete USDCe mock instead — the CT debit would never
    // round-trip to the vault and the rule would see a spurious asset loss. BOTH forms
    // are needed: the USDCE links make the settle call RESOLVED, so only the exact
    // USDCe.balanceOf summary fires there (wildcards are unresolved-only); the wildcard
    // stays as the safety net for any unresolved ERC20 reads. PM's ERC1155
    // balanceOf(address,uint256) is a different signature and is unaffected.
    function USDCe.balanceOf(address account) external returns (uint256) =>
        erc20BalanceOfCVL(USDCe, account);
    function _.balanceOf(address account) external =>
        erc20BalanceOfCVL(calledContract, account) expect uint256;
}

// migratePositions pulls legacy CTF positions into the module; their 1:1 USDC.e backing
// already escrowed in ConditionalTokens is recognized into the counted reserve here
// (amounts == the V2 amounts minted, unrolled to loop_iter <= 3). This is where the
// legacy reserve enters the model; the unified USDCe ledger then carries it out again:
// pull credit (here) -> redemption/merge payout CT->module (ctfRedeemPositionsCVL /
// ctfMergePositionsCVL) -> settle sweep module->vault (_settleLegacyCollateralToVault
// via safeTransferCVL, reading the module's ghost balance through the USDCe.balanceOf
// summary, so the sweep amount always equals the ghost balance and never reverts).
// Every hop is inside balanceByToken, and the counted sum (vault + CT reserve) is
// conserved or grows at each hop.
function migrationBackingPullCVL(uint256[] amounts) {
    address usdce = CollateralToken.USDCE();
    mathint pulled = (amounts.length > 0 ? to_mathint(amounts[0]) : 0)
        + (amounts.length > 1 ? to_mathint(amounts[1]) : 0)
        + (amounts.length > 2 ? to_mathint(amounts[2]) : 0);
    balanceByToken[usdce][ConditionalTokens] =
        require_uint256(balanceByToken[usdce][ConditionalTokens] + pulled);
}

// Loop-free emulation of legacy-CTF redemption (ConditionalTokens.redeemPositions):
// pays a nondeterministic totalPayout USDCe CT -> caller in the ghost ledger, bounded by
// CT's counted reserve (every real payout is <= the escrow, so the bound only excludes
// unreal behaviors — this over-approximates the real index-set/payout-fraction loop).
// CT-internal ERC1155 burns are not modeled: they are invisible to the rule's ghosts,
// and dropping them only widens behavior (CT could "pay twice"), the safe direction for
// the >= rule. The parentCollectionId != 0 mint branch is dead in-scene (the migration
// mixins always pass parent == 0). Keyed by the canonical CollateralToken.USDCE(), like
// migrationBackingPullCVL.
function ctfRedeemPositionsCVL(address caller) {
    address usdce = CollateralToken.USDCE();
    uint256 totalPayout;
    require totalPayout <= balanceByToken[usdce][ConditionalTokens],
        "CT cannot pay out more than its escrowed reserve";
    balanceByToken[usdce][ConditionalTokens] =
        assert_uint256(balanceByToken[usdce][ConditionalTokens] - totalPayout);
    balanceByToken[usdce][caller] = require_uint256(balanceByToken[usdce][caller] + totalPayout);
}

// Loop-free emulation of legacy-CTF merge (ConditionalTokens.mergePositions): pays
// exactly `amount` USDCe CT -> caller in the ghost ledger — the real parent == 0 merge
// transfers precisely its amount argument. The revert-guard mirrors the real
// insufficient-balance revert of the CT's collateral transfer. As with the redemption
// emulation, the CT-internal partition burns are not modeled (invisible to the rule's
// ghosts; dropping them only widens behavior, the safe direction for the >= rule).
function ctfMergePositionsCVL(address caller, uint256 amount) {
    address usdce = CollateralToken.USDCE();
    if (balanceByToken[usdce][ConditionalTokens] < amount) {
        revert();
    }
    balanceByToken[usdce][ConditionalTokens] =
        assert_uint256(balanceByToken[usdce][ConditionalTokens] - amount);
    balanceByToken[usdce][caller] = require_uint256(balanceByToken[usdce][caller] + amount);
}

// ERC20 balanceOf reads answer from the shared ghost ledger (see the USDCe.balanceOf /
// _.balanceOf entries in the methods block).
function erc20BalanceOfCVL(address token, address account) returns uint256 {
    return balanceByToken[token][account];
}

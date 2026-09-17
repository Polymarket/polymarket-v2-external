using CcipBridge as CcipBridge;
using CollateralToken as CollateralToken;
using PositionManager as PositionManager;
using BinaryModule as BinaryModule;
using NegRiskModule as NegRiskModule;
using CombinatorialModule as CombinatorialModule;
using ConditionalTokens as ConditionalTokens;

links {
    CcipBridge.COLLATERAL_TOKEN => CollateralToken;
    CcipBridge.POSITION_MANAGER => PositionManager;

    BinaryModule.COLLATERAL_TOKEN => CollateralToken;
    BinaryModule.POSITION_MANAGER => PositionManager;
    BinaryModule.CONDITIONAL_TOKENS => ConditionalTokens;

    NegRiskModule.COLLATERAL_TOKEN => CollateralToken;
    NegRiskModule.POSITION_MANAGER => PositionManager;
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;

    PositionManager.moduleById[_] => [BinaryModule, CombinatorialModule, NegRiskModule];
}

methods {
    function _.CONDITIONAL_TOKENS() internal => ConditionalTokens expect address;
    function _._legacyConditionalTokens() internal => ConditionalTokens expect address;

    // burnFromBridge value semantics, keyed by the ACTUAL callee (calledContract). The
    // DISPATCHER(true) this replaces let the solver pick a dispatch branch inconsistent
    // with the module the bridge just credited (unsafeBatchTransferFrom credited
    // moduleById(mid) while the burn debited a DIFFERENT module — a spurious net-balance
    // CEX). calledContract is the same symbolic callee the transfer credited, so debit
    // and credit line up by construction. Module-side onlyBridge auth is not modeled
    // (the BRIDGE-01 rules assert value flow, not module access control); the inner
    // PM.batchBurn value/auth/length/balance semantics are replicated with the
    // ghost-model helpers from PositionManager_full_summaries.spec.
    function _.burnFromBridge(BinaryModule.PositionId[] _positionIds, uint256[] _amounts) external with (env e) =>
        burnFromBridgeCVL(calledContract, e, _positionIds, _amounts) expect void;
    // mintFromBridge, symmetric to burnFromBridge: mints to the recipient via the ghost
    // model, preserving the module's zero-amount no-op. Module identity does not affect
    // the value flow (the mint credits the recipient), so no calledContract keying needed.
    // A wildcard works here: the call's SIGHASH is resolved (post-munge) and only the
    // target contract is unresolved — but note it fell through the ccipReceive
    // DISPATCH block below, which only catches sighash-unresolved calls.
    function _.mintFromBridge(address _to, BinaryModule.PositionId _positionId, uint256 _amount)
        external with (env e) => mintFromBridgeCVL(e, _to, _positionId, _amount) expect void;
    // The bridge's own PM call is RESOLVED (POSITION_MANAGER is linked), so the wildcard
    // `_.unsafeBatchTransferFrom` ghost summary from PositionManager_full_summaries.spec
    // does NOT fire for it (wildcards match unresolved calls only) — without this EXACT
    // entry the transfer ran REAL Solady storage while burns ran on ghosts (mixed model,
    // spurious net-balance CEX). Mirrors solvency/NegRiskModule.spec.
    function PositionManager.unsafeBatchTransferFrom(
        address from,
        address to,
        PositionManager.PositionId[] ids,
        uint256[] amounts
    ) external with (env e) => batchTransferWithAuthCVL(e, from, to, ids, amounts);
    // getResult is summarized to the result ghosts by CombinatorialPayout_summaries.spec
    // (imported via CcipBridge_base_summaries.spec).
    function _.moduleId() external => DISPATCHER(true);
    function _.reportResult(BinaryModule.ConditionId, uint256[]) external => DISPATCHER(true);

    // NOTE: this scene requires patches to be applied because _processMessage's inline assembly
    // breaks call resolution
    unresolved external in CcipBridge.ccipReceive(Client.Any2EVMMessage) => DISPATCH(optimistic=true) [
        PositionManager.moduleById(uint256),
        BinaryModule.mintFromBridge(address, BinaryModule.PositionId, uint256),
        NegRiskModule.mintFromBridge(address, NegRiskModule.PositionId, uint256),
        CollateralToken.mint(address, uint256),
        BinaryModule.reportResult(BinaryModule.ConditionId, uint256[]),
        NegRiskModule.reportResult(NegRiskModule.ConditionId, uint256[])
    ];

    function PositionManager.mint(address _to, PositionManager.PositionId _positionId, uint256 _amount)
        external => mintCVL(_to, _positionId, _amount);

    unresolved external in BinaryModule.mintFromBridge(address, BinaryModule.PositionId, uint256)
        => DISPATCH(optimistic=true) [PositionManager.mint(address, PositionManager.PositionId, uint256)];
    unresolved external in NegRiskModule.mintFromBridge(address, NegRiskModule.PositionId, uint256)
        => DISPATCH(optimistic=true) [PositionManager.mint(address, PositionManager.PositionId, uint256)];

    unresolved external in NegRiskModule.reportResult(NegRiskModule.ConditionId, uint256[])
        => DISPATCH(optimistic=true) [ConditionalTokens.redeemPositions(address,bytes32,bytes32,uint[])];
    unresolved external in BinaryModule.reportResult(BinaryModule.ConditionId, uint256[])
        => DISPATCH(optimistic=true) [ConditionalTokens.redeemPositions(address,bytes32,bytes32,uint[])];
}

// burnFromBridge (BaseModule: BinaryModule / NegRiskModule): onlyBridge + POSITION_MANAGER.batchBurn
// with msg.sender == the module. `module` is calledContract — see the methods entry.
function burnFromBridgeCVL(address module, env e, uint256[] positionIds, uint256[] amounts) {
    if (e.msg.value != 0) {
        revert();
    }
    if (positionIds.length != amounts.length) {
        revert();
    }
    if (!batchAuthOK(module, positionIds)) {
        revert();
    }
    batchBurnByCVL(0, module, positionIds, amounts);
}

// mintFromBridge (BaseModule: BinaryModule / NegRiskModule): onlyBridge (auth not modeled — value
// flow only) + zero-amount no-op + POSITION_MANAGER.mint to the recipient.
function mintFromBridgeCVL(env e, address to, uint256 positionId, uint256 amount) {
    if (e.msg.value != 0) {
        revert();
    }
    if (amount > 0) {
        mintCVL(to, positionId, amount);
    }
}

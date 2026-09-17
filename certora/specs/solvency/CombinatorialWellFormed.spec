
/*
 * MODULE
 * @module CombinatorialModule Conjunction Store
 * @contract CombinatorialModule
 * @impact A condition id could bind to the wrong leg set, settling a position against a different market than it was sold as
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to at most 3 iterations
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption The combinatorial payout is summarized with an equivalent CVL model
 *
 * PROPERTIES
 * @property COMBO-STORE-01 Every stored combinatorial conjunction is well-formed and canonical.
 */

import "CombinatorialRefinementBase.spec";

// ============================================================
// storedConjunctionsWellFormed
//
// Every stored combinatorial conjunction hashes back to its own id:
//   legCount(condKey) > 0  =>  getConditionId(legs[cid]) == cid.
//
// Bounded at loop_iter = 3: the neg-risk event ops (splitOnEvent / mergeOnEvent /
// convertOnEvent) fan out over a whole event (>= 3 iterations for an arity-2 event), so this
// conf runs at loop_iter = 3.
// ============================================================

methods {
    // convertToYesBasket / mergeFromYesBasket / the event ops build position ids with inline
    // mstore assembly, which breaks the Prover's sighash resolution of the following
    // PM.mint/burn/batchBurn.
    unresolved external in CombinatorialModule.convertToYesBasket(address[], CombinatorialModule.PositionId, uint256)
        => DISPATCH [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.burn(PositionManager.PositionId, uint256)
        ] default NONDET;
    unresolved external in CombinatorialModule.mergeFromYesBasket(address, CombinatorialModule.PositionId, uint256)
        => DISPATCH [
            PositionManager.mint(address, PositionManager.PositionId, uint256),
            PositionManager.batchBurn(PositionManager.PositionId[], uint256[])
        ] default NONDET;
    unresolved external in CombinatorialModule.splitOnEvent(
        address[], CombinatorialModule.PositionId, CombinatorialModule.EventId, uint256
    ) => DISPATCH [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.burn(PositionManager.PositionId, uint256)
    ] default NONDET;
    unresolved external in CombinatorialModule.mergeOnEvent(
        address, CombinatorialModule.PositionId, CombinatorialModule.EventId, uint256
    ) => DISPATCH [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.batchBurn(PositionManager.PositionId[], uint256[])
    ] default NONDET;
    unresolved external in CombinatorialModule.convertOnEvent(
        address[], CombinatorialModule.PositionId, uint256, uint256
    ) => DISPATCH [
        PositionManager.mint(address, PositionManager.PositionId, uint256),
        PositionManager.burn(PositionManager.PositionId, uint256)
    ] default NONDET;
}

/**
 * @title stored conjunctions are well-formed
 * @description Every stored conjunction hashes back to its own condition id.
 * @link_property COMBO-STORE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/d3432a6c751f43b28605297853f0eb7d?anonymousKey=504876740648b319fc55b625de9865a1a88c37eb
 */
invariant storedConjunctionsWellFormed(uint256 condKey)
    CombinatorialModule.legCount(condKey) > 0 => CombinatorialModule.isWellFormed(condKey)
    filtered {
        f -> f.selector != sig:CombinatorialModule.requestOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.cancelOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.completeOwnershipHandover(address).selector
            // Harness-only mutator.
            && f.selector != sig:CombinatorialModule.storeLegsFromMemoryReal(CombinatorialModule.PositionId[]).selector
    }
    {
        // Event derived-store writers: the derived child legs hash to their own id GIVEN the
        // parent does (needs loop_iter = 3 + the memory-reset munge to be non-vacuous).
        preserved splitOnEvent(
            address[] _to, CombinatorialModule.PositionId _parentYesPositionId,
            CombinatorialModule.EventId _eventId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsWellFormed(assert_uint256(_parentYesPositionId));
        }
        preserved mergeOnEvent(
            address _to, CombinatorialModule.PositionId _parentYesPositionId,
            CombinatorialModule.EventId _eventId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsWellFormed(assert_uint256(_parentYesPositionId));
        }
        preserved convertOnEvent(
            address[] _to, CombinatorialModule.PositionId _parentYesPositionId,
            uint256 _conditionIndex, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsWellFormed(assert_uint256(_parentYesPositionId));
        }
    }

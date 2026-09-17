
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

methods {
    // convertToYesBasket / mergeFromYesBasket build position ids with inline mstore assembly,
    // which breaks the Prover's sighash resolution of the following PM.mint/burn/batchBurn.
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

// ============================================================
// storedConjunctionsCanonical
//
// Every stored conjunction is canonical: non-empty; every leg on a binary/negrisk module with
// outcome < 2; strictly ascending position ids; no two legs sharing a conditionId. 
// ============================================================

/**
 * @title stored conjunctions are canonical
 * @description Every stored conjunction is non-empty, sits on binary or neg-risk legs with a valid outcome, and is strictly ascending with distinct condition ids.
 * @link_property COMBO-STORE-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/7a6074923dae4cf5947877400de55a76?anonymousKey=a0a5f070dd4b195ff1dcbe9b8b66885667494379
 */
invariant storedConjunctionsCanonical(uint256 condKey)
    CombinatorialModule.legCount(condKey) > 0 => CombinatorialModule.isCanonical(condKey)
    filtered {
        f -> f.selector != sig:CombinatorialModule.requestOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.cancelOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.completeOwnershipHandover(address).selector
            // Harness-only mutator
            && f.selector != sig:CombinatorialModule.storeLegsFromMemoryReal(CombinatorialModule.PositionId[]).selector
    }
    {
        // Derived-store writers: the derived legs are canonical given the input conjunction is.
        preserved splitOnCondition(
            address[] _to, CombinatorialModule.PositionId _parentYesPositionId,
            CombinatorialModule.ConditionId _conditionId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_parentYesPositionId));
        }
        preserved mergeOnCondition(
            address _to, CombinatorialModule.PositionId _parentYesPositionId,
            CombinatorialModule.ConditionId _conditionId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_parentYesPositionId));
        }
        preserved extract(
            address[] _to, CombinatorialModule.PositionId _fullNoPositionId, uint256 _conditionIndex, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_fullNoPositionId));
        }
        preserved inject(
            address _to, CombinatorialModule.PositionId _fullNoPositionId, uint256 _conditionIndex, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_fullNoPositionId));
        }
        preserved convertToYesBasket(
            address[] _to, CombinatorialModule.PositionId _fullNoPositionId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_fullNoPositionId));
        }
        preserved mergeFromYesBasket(
            address _to, CombinatorialModule.PositionId _fullNoPositionId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_fullNoPositionId));
        }
        preserved compress(
            address _to, CombinatorialModule.PositionId _positionId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_positionId));
        }
        preserved splitOnEvent(
            address[] _to, CombinatorialModule.PositionId _parentYesPositionId,
            CombinatorialModule.EventId _eventId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_parentYesPositionId));
        }
        preserved mergeOnEvent(
            address _to, CombinatorialModule.PositionId _parentYesPositionId,
            CombinatorialModule.EventId _eventId, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_parentYesPositionId));
        }
        preserved convertOnEvent(
            address[] _to, CombinatorialModule.PositionId _parentYesPositionId,
            uint256 _conditionIndex, uint256 _amount
        ) with (env e) {
            requireInvariant storedConjunctionsCanonical(assert_uint256(_parentYesPositionId));
        }
    }
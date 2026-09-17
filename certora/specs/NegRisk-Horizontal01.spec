/* =============================================================================
 * [NEGRISK-HORIZONTAL-01] horizontalSplit / horizontalMerge cover exactly the
 * arity+1 YES positions with equal amounts and are exact inverses.
 * ============================================================================= */

/*
 * MODULE
 * @module NegRiskModule Position Lifecycle
 * @contract NegRiskModule
 * @impact A neg-risk operation could mint or burn the wrong outcome conditions, so an event would owe its holders more collateral than was ever paid into it
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 *
 * PROPERTIES
 * @property NEGRISK-HORIZONTAL-01 horizontal split and merge cover exactly the YES legs of an event with equal amounts, and are exact inverses.
 */


import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";
import "summaries/Solady/ERC1155.spec";
import "summaries/CTFHelpers_summaries.spec";
import "summaries/Solady/SafeTransferLib.spec";

using NegRiskModuleHarness as NegRiskModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;
using DummyERC20Impl as Wcol;

methods {
    /* ---- harness pure helpers (envfree) ---- */
    function pidOf(NegRiskModule.ConditionId, uint256) external returns (uint256) envfree;
    function condAt(NegRiskModule.EventId, uint256) external returns (NegRiskModule.ConditionId) envfree;
    function arityOf(NegRiskModule.EventId) external returns (uint256) envfree;

    /* ---- legacy id derivation -> NONDET (feeds only legacy lookups, never the horizontal path) ---- */
    function CTHelpers.getConditionId(address, bytes32, uint256) internal returns (bytes32) => NONDET;
    function CTHelpers.getPositionId(address, bytes32) internal returns (uint256) => NONDET;
    function NegRiskIdLib.getQuestionId(bytes32, uint8) internal returns (bytes32) => NONDET;

    /* ---- PositionManager position-token mint/burn ----
     * batchMint is the split path, batchBurn is the merge path -> per-account ghost (5-unrolled).
     * single mint/burn are off the horizontal path but tracked per-account so the
     * isolation rules have teeth against a mutant that reroutes to a single mint/burn.  */
    function _.batchMint(address to, uint256[] ids, uint256[] amounts) external => hsBatchMintCVL(to, ids, amounts) expect void;
    function _.batchBurn(uint256[] ids, uint256[] amounts) external with (env e) => hsBatchBurnFromSenderCVL(e, ids, amounts) expect void;
    function _.mint(address to, uint256 id, uint256 amount) external => mintCVL(to, id, amount) expect void;
    function _.burn(uint256 id, uint256 amount) external with (env e) => pmBurnFromSenderCVL(e, id, amount) expect void;

    /* ---- CollateralToken (pUSD) mint/burn -> per-account ctBalance ghost ----
     * split burns from the module; merge mints to the recipient. Both tracked per-account. */
    function _.burn(uint256 _amount) external with (env e) => ctBurnFromSenderCVL(e, _amount) expect void;
    function _.mint(address _to, uint256 _amount) external => ctMintCVL(_to, _amount) expect void;

    // wrap/unwrap are unreachable from the horizontal path; NONDET removes their storage-split failures.
    function _.wrap(address _asset, address _to, uint256 _amount) external => NONDET;
    function _.unwrap(address _asset, address _to, uint256 _amount) external => NONDET;

    /* ---- OwnableRoles read + write wiring -> boolean ghosts ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// PositionManager and CollateralToken intentionally not linked (so the per-account mint/burn
// ghost summaries fire). CONDITIONAL_TOKENS + WRAPPED_COLLATERAL_TOKEN linked so the harness
// constructor's immutable wiring resolves.
links {
    NegRiskModule.CONDITIONAL_TOKENS => ConditionalTokens;
    NegRiskModule.WRAPPED_COLLATERAL_TOKEN => Wcol;
}

/* -----------------------------------------------------------------------------
 * Collateral-balance ghost — pUSD per account.
 * --------------------------------------------------------------------------- */
ghost mapping(address => mathint) ctBalance;

function ctMintCVL(address to, uint256 amount) {
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

function ctBurnFromSenderCVL(env e, uint256 amount) {
    if (ctBalance[e.msg.sender] < to_mathint(amount)) { revert(); }
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
}

/* -----------------------------------------------------------------------------
 * PositionManager batch/single burn — burns from msg.sender (the module).
 * Batch helpers unrolled to 5 (matches loop_iter 5 -> arity+1 <= 5).
 * --------------------------------------------------------------------------- */
function pmBurnFromSenderCVL(env e, uint256 id, uint256 amount) {
    burnByCVL(e.msg.sender, e.msg.sender, id, amount);
}

function hsBatchMintCVL(address to, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { mintCVL(to, ids[0], amounts[0]); }
    if (ids.length > 1) { mintCVL(to, ids[1], amounts[1]); }
    if (ids.length > 2) { mintCVL(to, ids[2], amounts[2]); }
    if (ids.length > 3) { mintCVL(to, ids[3], amounts[3]); }
    if (ids.length > 4) { mintCVL(to, ids[4], amounts[4]); }
}

function hsBatchBurnFromSenderCVL(env e, uint256[] ids, uint256[] amounts) {
    if (ids.length > 0) { burnByCVL(e.msg.sender, e.msg.sender, ids[0], amounts[0]); }
    if (ids.length > 1) { burnByCVL(e.msg.sender, e.msg.sender, ids[1], amounts[1]); }
    if (ids.length > 2) { burnByCVL(e.msg.sender, e.msg.sender, ids[2], amounts[2]); }
    if (ids.length > 3) { burnByCVL(e.msg.sender, e.msg.sender, ids[3], amounts[3]); }
    if (ids.length > 4) { burnByCVL(e.msg.sender, e.msg.sender, ids[4], amounts[4]); }
}

/* =============================================================================
 * horizontalSplit — mints each of the arity+1 YES legs exactly, burns collateral
 * ============================================================================= */

/**
 * @title horizontal split mints each YES exactly
 * @description Every covered leg of the event, including the synthetic Other, is credited exactly the split amount to the recipient.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitMintsEachYesExactly(env e, address to, NegRiskModule.EventId ev, uint256 amount, uint256 k) {
    require k <= arityOf(ev),"k ranges over the arity+1 covered YES legs [0, arity]";
    uint256 yesK = pidOf(condAt(ev, k), 0);
    mathint before = ghostBalance[to][yesK];

    horizontalSplit(e, to, ev, amount);

    assert ghostBalance[to][yesK] == before + amount;
}

/**
 * @title horizontal split burns collateral exactly
 * @description A horizontal split burns exactly the requested amount of pUSD from the module's own balance.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitBurnsCollateralExactly(env e, address to, NegRiskModule.EventId ev, uint256 amount) {
    mathint before = ctBalance[currentContract];

    horizontalSplit(e, to, ev, amount);

    assert ctBalance[currentContract] == before - amount;
}

/**
 * @title horizontal split burns only module collateral
 * @description A horizontal split changes no collateral balance other than the module's.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitBurnsOnlyModuleCollateral(env e, address to, NegRiskModule.EventId ev, uint256 amount, address a) {
    require a != currentContract,"the module is the burner; this rule checks every OTHER account's collateral is untouched";

    mathint before = ctBalance[a];

    horizontalSplit(e, to, ev, amount);

    assert ctBalance[a] == before;
}

/**
 * @title horizontal split mints no NO leg
 * @description A horizontal split never mints a NO position; it touches YES legs only.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitDoesNotMintNo(env e, address to, NegRiskModule.EventId ev, uint256 amount, uint256 k) {
    uint256 noK = pidOf(condAt(ev, k), 1);
    mathint before = ghostBalance[to][noK];

    horizontalSplit(e, to, ev, amount);

    assert ghostBalance[to][noK] == before;
}

/**
 * @title horizontal split stops at the synthetic leg
 * @description Coverage stops at the synthetic Other condition; the YES leg one past it is untouched.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitDoesNotMintBeyondOther(env e, address to, NegRiskModule.EventId ev, uint256 amount) {
    uint256 beyond = pidOf(condAt(ev, require_uint256(arityOf(ev) + 1)), 0);
    mathint before = ghostBalance[to][beyond];

    horizontalSplit(e, to, ev, amount);

    assert ghostBalance[to][beyond] == before;
}

/**
 * @title horizontal split credits only the recipient
 * @description Only the named recipient is credited; any other account's covered YES balance is untouched.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitCreditsOnlyRecipient(env e, address to, NegRiskModule.EventId ev, uint256 amount, uint256 k, address acc) {
    require acc != to,"Checks every OTHER account's YES leg is untouched";

    uint256 yesK = pidOf(condAt(ev, k), 0);
    mathint before = ghostBalance[acc][yesK];

    horizontalSplit(e, to, ev, amount);

    assert ghostBalance[acc][yesK] == before;
}

/**
 * @title horizontal split touches only covered legs
 * @description Any position id outside the covered YES legs is untouched for every account.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitTouchesOnlyCoveredYes(env e, address to, NegRiskModule.EventId ev, uint256 amount, address acc, uint256 p) {
    // Split mints only indices [0, arity]⊆ [0,4]; excluding all five candidate YES legs places p
    // strictly outside the touched set, so this cell must be a pure frame.
    require p != pidOf(condAt(ev, 0), 0) && p != pidOf(condAt(ev, 1), 0) && p != pidOf(condAt(ev, 2), 0)
        && p != pidOf(condAt(ev, 3), 0) && p != pidOf(condAt(ev, 4), 0),"p is outside the arity+1 covered YES legs";

    mathint before = ghostBalance[acc][p];

    horizontalSplit(e, to, ev, amount);

    assert ghostBalance[acc][p] == before;
}

/* =============================================================================
 * horizontalMerge — burns each of the arity+1 YES legs exactly, mints collateral
 * ============================================================================= */

/**
 * @title horizontal merge burns each YES exactly
 * @description Every covered leg of the event is burned by exactly the merge amount from the module.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalMergeBurnsEachYesExactly(env e, address to, NegRiskModule.EventId ev, uint256 amount, uint256 k) {
    require k <= arityOf(ev),"k ranges over the arity+1 covered YES legs [0, arity]";

    uint256 yesK = pidOf(condAt(ev, k), 0);
    mathint before = ghostBalance[currentContract][yesK];

    horizontalMerge(e, to, ev, amount);

    assert ghostBalance[currentContract][yesK] == before - amount;
}

/**
 * @title horizontal merge mints collateral exactly
 * @description A horizontal merge mints exactly the requested amount of pUSD to the recipient.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalMergeMintsCollateralExactly(env e, address to, NegRiskModule.EventId ev, uint256 amount) {
    mathint before = ctBalance[to];

    horizontalMerge(e, to, ev, amount);

    assert ctBalance[to] == before + amount;
}

/**
 * @title horizontal merge mints only recipient collateral
 * @description A horizontal merge changes no collateral balance other than the recipient's.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalMergeMintsOnlyRecipientCollateral(env e, address to, NegRiskModule.EventId ev, uint256 amount, address a) {
    require a != to,"checks every OTHER account's collateral is untouched";

    mathint before = ctBalance[a];

    horizontalMerge(e, to, ev, amount);

    assert ctBalance[a] == before;
}

/**
 * @title horizontal merge burns no NO leg
 * @description A horizontal merge never burns a NO position; it touches YES legs only.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalMergeDoesNotBurnNo(env e, address to, NegRiskModule.EventId ev, uint256 amount, uint256 k) {
    uint256 noK = pidOf(condAt(ev, k), 1);
    mathint before = ghostBalance[currentContract][noK];

    horizontalMerge(e, to, ev, amount);

    assert ghostBalance[currentContract][noK] == before;
}

/**
 * @title horizontal merge stops at the synthetic leg
 * @description A horizontal merge does not burn the YES leg past the synthetic Other condition.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalMergeDoesNotBurnBeyondOther(env e, address to, NegRiskModule.EventId ev, uint256 amount) {
    uint256 beyond = pidOf(condAt(ev, require_uint256(arityOf(ev) + 1)), 0);
    mathint before = ghostBalance[currentContract][beyond];

    horizontalMerge(e, to, ev, amount);

    assert ghostBalance[currentContract][beyond] == before;
}

/**
 * @title horizontal merge burns only module legs
 * @description A horizontal merge burns the covered legs from the module only; any other account's covered YES leg is untouched.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalMergeBurnsOnlyModuleYes(env e, address to, NegRiskModule.EventId ev, uint256 amount, uint256 k, address acc) {
    require acc != currentContract,"checks every OTHER account's covered YES leg is untouched";

    uint256 yesK = pidOf(condAt(ev, k), 0);
    mathint before = ghostBalance[acc][yesK];

    horizontalMerge(e, to, ev, amount);

    assert ghostBalance[acc][yesK] == before;
}

/**
 * @title horizontal merge touches only covered legs
 * @description Any position id outside the covered YES legs is untouched for every account.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalMergeTouchesOnlyCoveredYes(env e, address to, NegRiskModule.EventId ev, uint256 amount, address acc, uint256 p) {
    require p != pidOf(condAt(ev, 0), 0) && p != pidOf(condAt(ev, 1), 0) && p != pidOf(condAt(ev, 2), 0)
        && p != pidOf(condAt(ev, 3), 0) && p != pidOf(condAt(ev, 4), 0),"p is outside the arity+1 covered YES legs";

    mathint before = ghostBalance[acc][p];

    horizontalMerge(e, to, ev, amount);

    assert ghostBalance[acc][p] == before;
}

/* =============================================================================
 * [splitMergeInverse] split then merge (both to the module) is the identity
 * ============================================================================= */
/**
 * @title horizontal split and merge are inverses
 * @description A horizontal split followed by a horizontal merge restores the position supplies and the collateral balances.
 * @link_property NEGRISK-HORIZONTAL-01
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/e6723dec07374e8c8650b196d7ff7619?anonymousKey=c9aab6ceb1a679dd9f84db8796ac420fb42a298b
 */
rule horizontalSplitMergeInverse(env e1, env e2, NegRiskModule.EventId ev, uint256 amount, uint256 k) {
    uint256 yesK = pidOf(condAt(ev, k), 0);
    mathint yBefore = ghostBalance[currentContract][yesK];
    mathint cBefore = ctBalance[currentContract];

    horizontalSplit(e1, currentContract, ev, amount); // mint YES legs to the module, burn collateral
    horizontalMerge(e2, currentContract, ev, amount); // burn them back, mint collateral to the module

    assert ghostBalance[currentContract][yesK] == yBefore, "each YES leg returns to its pre-split balance";
    assert ctBalance[currentContract] == cBefore, "collateral returns to its pre-split balance";
}

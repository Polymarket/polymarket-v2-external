/* =============================================================================
 * [MODULE-ESCROW-01] — modules are pure conduits (SHARED RULES)
 *
 * Stated property: between operations the module holds zero pUSD and zero
 * position balance for every position id.
 *
 * Out of scope (documented, not proven here):
 *   - donations via direct CollateralToken / PositionManager transfers to the
 *     module (parametric_contracts = the module harness only).
 *   - legacy CTF / USDC.e custody during migration (different asset contracts;
 *     the property concerns pUSD and PositionManager balances only).
 * ============================================================================= */

import "summaries/Solady/OwnableRoles.spec";
import "summaries/Solady/UUPSUpgradeable.spec";
import "summaries/Solady/ERC1155.spec";

using PositionManager as PositionManager;
using CollateralToken as CollateralToken;

methods {
    /* ---- module immutable wiring (NOT linked, so the ghost summaries fire) ---- */
    function _.POSITION_MANAGER() external => PositionManager expect address;
    function _.COLLATERAL_TOKEN() external => CollateralToken expect address;

    /* ---- PositionManager position-token mutators -> ERC1155 ghost model.
     * mint / batchMint additionally accumulate the per-id self-mint amount when
     * the module itself is the recipient (exact bound for caller self-donation). ---- */
    function _.mint(address _to, uint256 _positionId, uint256 _amount) external => pmMintTrackedCVL(_to, _positionId, _amount) expect void;
    function _.burn(uint256 _positionId, uint256 _amount) external with (env e) => burnByCVL(0, e.msg.sender, _positionId, _amount) expect void;
    function _.batchMint(address _to, uint256[] _positionIds, uint256[] _amounts) external => pmBatchMintTrackedCVL(_to, _positionIds, _amounts) expect void;
    function _.batchBurn(uint256[] _positionIds, uint256[] _amounts) external with (env e) => pmBatchBurnFromSenderCVL(e, _positionIds, _amounts) expect void;

    /* ---- CollateralToken (pUSD) mint/burn -> per-account ctBalance ghost.
     * burn debits msg.sender (the module on split); mint credits `_to` and
     * accumulates the self-mint amount when `_to` is the module. ---- */
    function _.mint(address _to, uint256 _amount) external => ctMintTrackedCVL(_to, _amount) expect void;
    function _.burn(uint256 _amount) external with (env e) => ctBurnFromSenderCVL(e, _amount) expect void;

    /* ---- OwnableRoles read + write wiring -> boolean ghosts ---- */
    function _.hasAnyRole(address user, uint256 roles) internal => hasAnyRoleCVL(currentContract, user, roles) expect bool;
    function _.hasAllRoles(address user, uint256 roles) internal => hasAllRolesCVL(currentContract, user, roles) expect bool;
    function _.rolesOf(address user) internal => rolesOfCVL(currentContract, user) expect uint256;
    function _._checkRoles(uint256 roles) internal with (env e) => checkRolesCVL(e, currentContract, roles) expect void;
    function _._setRoles(address user, uint256 roles) internal => setRolesCVL(currentContract, user, roles) expect void;
    function _._updateRoles(address user, uint256 roles, bool on) internal => updateRolesCVL(currentContract, user, roles, on) expect void;
    function _.ownershipHandoverExpiresAt(address pendingOwner) internal => ownershipHandoverExpiresAtCVL(currentContract, pendingOwner) expect uint256;
}

// Collateral-balance ghost — pUSD per account (positions live in ghostBalance from ERC1155.spec).
ghost mapping(address => mathint) ctBalance;

// Exact amount module code explicitly minted to the module itself during the call
// (only possible when the caller passed the module as `_to` — self-donation).
ghost mathint gSelfMintedCollateral;
ghost mapping(uint256 => mathint) gSelfMintedPosition;

function ctMintTrackedCVL(address to, uint256 amount) {
    if (to == currentContract) {
        gSelfMintedCollateral = gSelfMintedCollateral + to_mathint(amount);
    }
    ctBalance[to] = ctBalance[to] + to_mathint(amount);
}

// CollateralToken.burn(amount) burns from msg.sender
function ctBurnFromSenderCVL(env e, uint256 amount) {
    if (ctBalance[e.msg.sender] < to_mathint(amount)) { revert();}
    ctBalance[e.msg.sender] = ctBalance[e.msg.sender] - to_mathint(amount);
}

function pmMintTrackedCVL(address to, uint256 id, uint256 amount) {
    if (to == currentContract) {
        gSelfMintedPosition[id] = gSelfMintedPosition[id] + to_mathint(amount);
    }
    mintCVL(to, id, amount);
}

// Batch helpers unrolled locally to 5 elements. 
function pmBatchMintTrackedCVL(address to, uint256[] ids, uint256[] amounts) {
    if (ids.length != amounts.length) {
        revert();
    }
    if (ids.length > 0) { pmMintTrackedCVL(to, ids[0], amounts[0]); }
    if (ids.length > 1) { pmMintTrackedCVL(to, ids[1], amounts[1]); }
    if (ids.length > 2) { pmMintTrackedCVL(to, ids[2], amounts[2]); }
    if (ids.length > 3) { pmMintTrackedCVL(to, ids[3], amounts[3]); }
    if (ids.length > 4) { pmMintTrackedCVL(to, ids[4], amounts[4]); }
}

// batchBurn burns from the caller (the module holds the positions being burned).
function pmBatchBurnFromSenderCVL(env e, uint256[] positionIds, uint256[] amounts) {
    if (positionIds.length != amounts.length) {
        revert();
    }
    if (positionIds.length > 0) { burnByCVL(0, e.msg.sender, positionIds[0], amounts[0]); }
    if (positionIds.length > 1) { burnByCVL(0, e.msg.sender, positionIds[1], amounts[1]); }
    if (positionIds.length > 2) { burnByCVL(0, e.msg.sender, positionIds[2], amounts[2]); }
    if (positionIds.length > 3) { burnByCVL(0, e.msg.sender, positionIds[3], amounts[3]); }
    if (positionIds.length > 4) { burnByCVL(0, e.msg.sender, positionIds[4], amounts[4]); }
}

/* =============================================================================
 * RULES — verified only in scenes that `use` them
 * ============================================================================= */

// The module's own pUSD balance grows by at most the amount the caller explicitly
// directed to the module (`_to = module` self-donation).
rule moduleNeverAccumulatesCollateral(method f) {
    env e;
    calldataarg args;

    // No module calls its own external entry points
    require e.msg.sender != currentContract;
    require gSelfMintedCollateral == 0;

    mathint before = ctBalance[currentContract];

    f(e, args);

    assert ctBalance[currentContract] <= before + gSelfMintedCollateral;
}

// The module's own balance of EVERY position id grows by at most the amount the
// caller explicitly minted to the module For that id — per-id exact bound, so a
// self-donation of one id never waives the check for any other id.
rule moduleNeverAccumulatesPositions(method f, uint256 id) {
    env e;
    calldataarg args;

    require e.msg.sender != currentContract;
    require gSelfMintedPosition[id] == 0;

    mathint before = ghostBalance[currentContract][id];

    f(e, args);

    assert ghostBalance[currentContract][id] <= before + gSelfMintedPosition[id];
}

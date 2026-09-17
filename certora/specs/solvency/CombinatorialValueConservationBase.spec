// ============================================================
// Shared base for the CombinatorialModule call-based VALUE-CONSERVATION specs.
//
// Owns the mint/burn recording layer they share: the (positionId, amount) log ghosts, the
// recordMintCVL / recordBurnCVL helpers, the `PositionManager.mint` / `burn` => record wiring, the bare
// `getPayout` declaration and the child-condKey derivation views, plus the storedConjunctionsWellFormed
// invariant they consume via `requireInvariant`.
// ============================================================

// ------------------------------------------------------------
// Mint / burn log: records the (positionId, amount) of each PositionManager.mint / burn the op does.
// ------------------------------------------------------------
ghost uint256 gMintCount;
ghost mapping(uint256 => uint256) gMintId;
ghost mapping(uint256 => uint256) gMintAmt;
ghost uint256 gBurnCount;
ghost mapping(uint256 => uint256) gBurnId;
ghost mapping(uint256 => uint256) gBurnAmt;

function recordMintCVL(uint256 id, uint256 amt) {
    gMintId[gMintCount] = id;
    gMintAmt[gMintCount] = amt;
    gMintCount = require_uint256(gMintCount + 1);
}

function recordBurnCVL(uint256 id, uint256 amt) {
    gBurnId[gBurnCount] = id;
    gBurnAmt[gBurnCount] = amt;
    gBurnCount = require_uint256(gBurnCount + 1);
}

methods {
    function CombinatorialModule.getPayout(CombinatorialModule.PositionId, uint256) external returns (uint256);

    // Child-condKey derivations used by Forward/Inverse (harmless-unused for Wrap/Compress).
    function CombinatorialModule.splitChildCondKeys(uint256, CombinatorialModule.ConditionId)
        external returns (uint256, uint256) envfree;
    function CombinatorialModule.extractChildCondKeys(uint256, uint256)
        external returns (uint256, uint256) envfree;
    function CombinatorialModule.basketCondKeys(uint256)
        external returns (uint256, uint256) envfree;

    // PositionManager.mint / burn RECORD (batchBurn differs per spec -> local).
    function PositionManager.mint(address _to, PositionManager.PositionId _positionId, uint256 _amount)
        external => recordMintCVL(_positionId, _amount);
    function PositionManager.burn(PositionManager.PositionId _positionId, uint256 _amount)
        external => recordBurnCVL(_positionId, _amount);
}

// Well-formedness invariant consumed by the value-conservation rules via `requireInvariant`.
// ownership-handover filtered. Proved in its dedicated spec. 
invariant storedConjunctionsWellFormed(uint256 condKey)
    CombinatorialModule.legCount(condKey) > 0 => CombinatorialModule.isWellFormed(condKey)
    filtered {
        f -> f.selector != sig:CombinatorialModule.requestOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.cancelOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.completeOwnershipHandover(address).selector
    }

// Canonicality invariant consumed by the value-conservation rules via `requireInvariant`.
// Statement only: the proof (with its seven preserved blocks, loop_iter 3) is CombinatorialCanonical.conf.
// Proved in its dedicated spec. 
invariant storedConjunctionsCanonical(uint256 condKey)
    CombinatorialModule.legCount(condKey) > 0 => CombinatorialModule.isCanonical(condKey)
    filtered {
        f -> f.selector != sig:CombinatorialModule.requestOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.cancelOwnershipHandover().selector
            && f.selector != sig:CombinatorialModule.completeOwnershipHandover(address).selector
    }
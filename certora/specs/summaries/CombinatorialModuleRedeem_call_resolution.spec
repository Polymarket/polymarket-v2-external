// Scene file for the CombinatorialModule REDEEM solvency scene
// (certora/confs/solvency/CombinatorialModuleRedeem.conf).
//
// Owns the `using` alias declarations for that scene. This mirrors
// CombinatorialModule_solvency_call_resolution.spec (the base/Phase-1 scene): the redeem scene now
// links the PRODUCTION CollateralToken directly (the conf includes src/collateral/CollateralToken.sol),
// so there is a single contract named CollateralToken in the scene — no alias clash. The token's
// mint/burn are summarized in the spec (to the ghostPusdSupply model), so its Solady slot-seed
// storage is never read directly; COLLATERAL_TOKEN (declared type CollateralToken) links to it and
// the module's COLLATERAL_TOKEN.mint/burn calls resolve to the summarized production contract.
using PositionManager as PositionManager;
using CombinatorialModule as CombinatorialModule;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;

links {
    PositionManager.moduleById[_] => [CombinatorialModule];
    PositionManager.COLLATERAL_TOKEN => CollateralToken;

    CombinatorialModule.POSITION_MANAGER => PositionManager;
    CombinatorialModule.COLLATERAL_TOKEN => CollateralToken;
}
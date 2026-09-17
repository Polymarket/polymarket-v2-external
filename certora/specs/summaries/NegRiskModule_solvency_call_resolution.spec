// Scene file for the NegRiskModule SOLVENCY verification scene
// (certora/confs/solvency/NegRiskModule.conf).
//
// Owns the `using` alias declarations for every contract in that scene's `files`
// list. Convention: aliases are declared EXACTLY ONCE per scene, here; shared summary
// files (PositionManager_full_summaries, NegRiskModule_base_summaries, ...) only
// reference them. This is a SEPARATE scene from the BinaryModule solvency scene
// (certora/confs/solvency/PositionManager.conf and certora/confs/solvency/
// BinaryModule.conf, whose call resolution is owned by
// PositionManager_call_resolution.spec) — keeping them apart means the proven binary
// solvency setup is untouched by the NegRisk work.
//
// The NegRiskModule.* links (COLLATERAL_TOKEN / POSITION_MANAGER / CONDITIONAL_TOKENS /
// WRAPPED_COLLATERAL_TOKEN) are owned by NegRiskModule_base_summaries.spec, not here.
using PositionManager as PositionManager;
using BinaryModule as BinaryModule;
using NegRiskModule as NegRiskModule;
using CombinatorialModule as CombinatorialModule;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;
using USDCe as USDCe;
using DummyERC20Impl as Wcol;

links {
    PositionManager.moduleById[_] => [BinaryModule, CombinatorialModule, NegRiskModule];
    PositionManager.COLLATERAL_TOKEN => CollateralToken;

    CombinatorialModule.POSITION_MANAGER => PositionManager;
}
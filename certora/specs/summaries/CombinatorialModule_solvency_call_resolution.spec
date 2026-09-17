// Scene file for the CombinatorialModule SOLVENCY verification scene
// (certora/confs/solvency/CombinatorialModule.conf).
//
// Owns the `using` alias declarations for every contract in that scene's `files`
// list. Convention: aliases are declared EXACTLY ONCE per scene, here; shared summary
// files (PositionManager_full_summaries, NegRiskModule_base_summaries, ...) only
// reference them. This is a SEPARATE scene from the Binary/NegRisk solvency scenes, so
// the proven binary/negrisk setups are untouched by the combinatorial work.
//
// CombinatorialModule is the harnessed verification participant here (it carries the
// liability), so both of its immutables are linked. BinaryModule and NegRiskModule are
// plain scene participants: legs reference their conditions and the moduleById dispatcher
// must resolve to them; their own immutables are left havoc'd (their bodies are never
// exercised by the in-scope combinatorial ops — cross-module getResult reads are
// summarized to the result ghost in the spec).
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

// Scene file for the NegRiskModule verification scene (certora/confs/NegRiskModule.conf).
// Owns the `using` alias declarations for every contract in the scene's `files` list.
// Convention: aliases are declared EXACTLY ONCE per scene, here; shared summary files
// (PositionManager_base_summaries, NegRiskModule_base_summaries, ...) only reference them.
using NegRiskModule as NegRiskModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;
using USDCe as USDCe;
using DummyERC20Impl as Wcol;

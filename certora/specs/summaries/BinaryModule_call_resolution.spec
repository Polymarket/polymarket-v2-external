// Scene file for the BinaryModule verification scene (certora/confs/BinaryModule.conf).
// Owns the `using` alias declarations for every contract in the scene's `files` list.
// Convention: aliases are declared EXACTLY ONCE per scene, here; shared summary files
// (PositionManager_base_summaries, BinaryModule_base_summaries, ...) only reference them.
using BinaryModule as BinaryModule;
using PositionManager as PositionManager;
using CollateralToken as CollateralToken;
using ConditionalTokens as ConditionalTokens;
using USDCe as USDCe;
